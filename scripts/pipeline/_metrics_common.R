# Shared implementation for the maintained, fully offline five-metric smoke
# workflow. The workflow demonstrates calculation contracts on synthetic data;
# it does not reproduce either historical deployment result.

METRIC_LOCATION_COLUMNS <- c(
  "timestamp_utc", "source_address", "sensor_name", "x", "y",
  "strength_sum", "detections"
)
METRIC_COUNT_COLUMNS <- c(
  "timestamp_utc", "sensor_name", "n_retained_identifiers"
)
METRIC_TRACK_COLUMNS <- c(
  "source_address", "trajectory_id", "start_utc", "end_utc",
  "duration_seconds", "n_windows", "origin", "destination", "is_od"
)
METRIC_OD_COLUMNS <- c(
  "origin", "destination", "n_trajectories", "n_retained_identifiers"
)
METRIC_REVISIT_COLUMNS <- c(
  "source_address", "n_qualifying_trajectories", "n_observed_local_dates",
  "observed_local_dates", "first_local_date", "last_local_date",
  "revisit_class"
)
METRIC_ACTIVITY_COLUMNS <- c(
  "source_address", "trajectory_id", "cluster_id", "episode_id",
  "start_utc", "end_utc", "duration_seconds", "n_windows",
  "primary_sensor", "n_sensors", "is_stay", "activity_type"
)
METRIC_NUMERIC_COLUMNS <- c(
  "x", "y", "strength_sum", "detections", "n_retained_identifiers",
  "trajectory_id", "duration_seconds", "n_windows", "is_od",
  "n_trajectories", "n_qualifying_trajectories",
  "n_observed_local_dates", "cluster_id", "episode_id", "n_sensors",
  "is_stay"
)
METRIC_PARAMETER_DEFAULTS <- list(
  track_gap_seconds = "1800",
  visit_gap_seconds = "7200",
  revisit_min_windows = "2",
  activity_min_windows = "3",
  activity_max_duration_seconds = "7200",
  activity_distance_metres = "75",
  activity_continuity_gap_seconds = "600",
  activity_min_duration_seconds = "300"
)

parse_metric_parameters <- function(options) {
  positive_integer <- function(value, label) {
    parsed <- parse_positive_number(value, label)
    if (parsed != floor(parsed) || parsed > .Machine$integer.max) {
      stop_pipeline(label, " must be a positive integer")
    }
    as.integer(parsed)
  }
  parameters <- list(
    track_gap_seconds = positive_integer(
      options$track_gap_seconds, "--track-gap-seconds"
    ),
    visit_gap_seconds = positive_integer(
      options$visit_gap_seconds, "--visit-gap-seconds"
    ),
    revisit_min_windows = positive_integer(
      options$revisit_min_windows, "--revisit-min-windows"
    ),
    activity_min_windows = positive_integer(
      options$activity_min_windows, "--activity-min-windows"
    ),
    activity_max_duration_seconds = positive_integer(
      options$activity_max_duration_seconds, "--activity-max-duration-seconds"
    ),
    activity_distance_metres = parse_positive_number(
      options$activity_distance_metres, "--activity-distance-metres"
    ),
    activity_continuity_gap_seconds = positive_integer(
      options$activity_continuity_gap_seconds,
      "--activity-continuity-gap-seconds"
    ),
    activity_min_duration_seconds = positive_integer(
      options$activity_min_duration_seconds, "--activity-min-duration-seconds"
    ),
    local_timezone = PIPELINE_LOCAL_TIMEZONE
  )
  if (parameters$activity_max_duration_seconds <
      parameters$activity_min_duration_seconds) {
    stop_pipeline("activity maximum duration cannot be below the stay minimum")
  }
  parameters
}

metric_parameters_are_defaults <- function(parameters) {
  defaults <- parse_metric_parameters(METRIC_PARAMETER_DEFAULTS)
  identical(parameters, defaults)
}

metric_output_paths <- function(output_dir) {
  list(
    location = file.path(output_dir, "01_location.csv"),
    count = file.path(output_dir, "02_count.csv"),
    track_trajectories = file.path(output_dir, "03_track_trajectories.csv"),
    track_od = file.path(output_dir, "03_track_od.csv"),
    revisits = file.path(output_dir, "04_revisits.csv"),
    activities = file.path(output_dir, "05_activities.csv"),
    manifest = file.path(output_dir, "manifest.json")
  )
}

read_metric_input <- function(path) {
  require_pipeline_packages(c("data.table", "arrow"))
  data <- read_pipeline_table(
    path, PIPELINE_TWENTY_SECOND_COLUMNS, "maintained 20-second input"
  )
  data[, timestamp := parse_utc_z(
    timestamp, "maintained 20-second timestamp", require_whole_second = TRUE
  )]
  data[, source_address := validate_identifier(
    source_address, "maintained 20-second source_address"
  )]
  if (anyNA(data$sensor_name) ||
      any(!grepl("^[A-Za-z0-9_-]{1,32}$", data$sensor_name))) {
    stop_pipeline("maintained 20-second sensor_name is invalid")
  }
  data[, sensor_name := as.character(sensor_name)]
  data[, rssi_median := normalize_finite_double(
    rssi_median, "maintained 20-second rssi_median", -127, 0
  )]
  data[, rssi_sum := normalize_finite_double(
    rssi_sum, "maintained 20-second rssi_sum"
  )]
  detections <- suppressWarnings(as.numeric(data$detections))
  if (anyNA(detections) || any(!is.finite(detections)) ||
      any(detections != floor(detections)) ||
      any(detections < 1 | detections > PIPELINE_WINDOW_SECONDS)) {
    stop_pipeline("maintained 20-second detections must be integers in [1, 20]")
  }
  data[, detections := as.integer(detections)]
  data[, strength_sum := normalize_finite_double(
    strength_sum, "maintained 20-second strength_sum"
  )]
  if (any(abs(data$strength_sum -
              (100 * data$detections + data$rssi_sum)) > 1e-9)) {
    stop_pipeline("strength_sum must equal 100 * detections + rssi_sum")
  }
  if (any(abs(as.numeric(data$timestamp) %% PIPELINE_WINDOW_SECONDS) > 1e-6)) {
    stop_pipeline("maintained timestamps must align to UTC 20-second boundaries")
  }
  assert_unique_key(
    data, c("source_address", "sensor_name", "timestamp"),
    "maintained 20-second input"
  )
  data.table::setorder(data, timestamp, source_address, sensor_name)
  data
}

read_metric_sensors <- function(path) {
  require_pipeline_packages("data.table")
  path <- assert_input_file(path, "synthetic sensor metadata")
  sensors <- data.table::fread(path, na.strings = c("", "NA"))
  expected <- c("sensor_name", "x", "y", "coordinate_system", "is_synthetic")
  assert_exact_columns(sensors, expected, "synthetic sensor metadata")
  if (anyNA(sensors$sensor_name) ||
      any(!grepl("^[A-Za-z0-9_-]{1,32}$", sensors$sensor_name)) ||
      data.table::uniqueN(sensors$sensor_name) != nrow(sensors)) {
    stop_pipeline("synthetic sensor names must be valid and unique")
  }
  sensors[, `:=`(
    sensor_name = as.character(sensor_name),
    x = normalize_finite_double(x, "synthetic sensor x"),
    y = normalize_finite_double(y, "synthetic sensor y")
  )]
  if (anyNA(sensors$coordinate_system) ||
      any(sensors$coordinate_system != "local_cartesian_metres")) {
    stop_pipeline("sensor coordinates must use local_cartesian_metres")
  }
  synthetic <- suppressWarnings(as.numeric(sensors$is_synthetic))
  if (anyNA(synthetic) || any(synthetic != 1)) {
    stop_pipeline("every sensor row must be explicitly synthetic")
  }
  sensors[, is_synthetic := as.integer(synthetic)]
  data.table::setorder(sensors, sensor_name)
  sensors
}

read_fixture_contract <- function(path) {
  path <- assert_input_file(path, "synthetic fixture manifest")
  text <- paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  required <- c(
    '"fully_synthetic": true',
    '"raw_mac_addresses_stored": false',
    '"mac_addresses_used_as_identifier_inputs": false',
    '"original_address_mapping_exists": false',
    '"key_is_public": true',
    '"key_is_secret": false',
    '"key_is_test_only": true',
    '"key_must_not_be_used_for_field_collection": true',
    '"security_notice": "PUBLIC TEST KEY; never use this value for field collection"',
    '"minimal_packets_fixture": true',
    '"no_hardware_capture_occurred": true',
    '"operational_loss_counters_fabricated": false',
    '"capture_interface_summary": "omitted because no hardware capture occurred"',
    '"capture_metadata": "omitted because no hardware capture occurred"',
    '"lowercase_hex_characters": 32',
    '"scheme": "synthetic-role-hmac-sha256-128-v1"',
    '"scope": "deployment"',
    '"Location": "moving_retained sensor overlap"',
    '"Revisits": "moving_retained local_calendar_dates"',
    '"Activities": "activity_stay_retained"',
    '"Asia/Seoul (UTC+09:00; no DST)"'
  )
  absent <- required[!vapply(required, grepl, logical(1), x = text, fixed = TRUE)]
  if (length(absent)) {
    stop_pipeline("fixture manifest is missing required synthetic/privacy roles")
  }

  scenario_block <- function(name) {
    pattern <- paste0('(?s)"', name, '"\\s*:\\s*\\{(.*?)\\n\\s*\\}')
    match <- regexec(pattern, text, perl = TRUE)
    value <- regmatches(text, match)[[1L]]
    if (length(value) != 2L) stop_pipeline("fixture manifest lacks scenario: ", name)
    value[[2L]]
  }
  extract_identifier <- function(block, name) {
    pattern <- paste0(
      '"identifier"\\s*:\\s*"([0-9a-f]{',
      PIPELINE_IDENTIFIER_HEX_LENGTH,
      '})"'
    )
    match <- regexec(pattern, block, perl = TRUE)
    value <- regmatches(block, match)[[1L]]
    if (length(value) != 2L) stop_pipeline("scenario lacks identifier: ", name)
    value[[2L]]
  }
  moving_block <- scenario_block("moving_retained")
  activity_block <- scenario_block("activity_stay_retained")
  date_match <- regexec(
    '(?s)"local_calendar_dates"\\s*:\\s*\\[(.*?)\\]',
    moving_block, perl = TRUE
  )
  date_value <- regmatches(moving_block, date_match)[[1L]]
  if (length(date_value) != 2L) {
    stop_pipeline("moving_retained lacks local_calendar_dates")
  }
  dates <- regmatches(date_value[[2L]], gregexpr(
    '[0-9]{4}-[0-9]{2}-[0-9]{2}', date_value[[2L]], perl = TRUE
  ))[[1L]]
  span_match <- regexec(
    '"span_seconds"\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)',
    activity_block, perl = TRUE
  )
  span_value <- regmatches(activity_block, span_match)[[1L]]
  if (length(span_value) != 2L) {
    stop_pipeline("activity_stay_retained lacks span_seconds")
  }

  list(
    path = path,
    moving_identifier = extract_identifier(moving_block, "moving_retained"),
    activity_identifier = extract_identifier(
      activity_block, "activity_stay_retained"
    ),
    moving_local_dates = sort(unique(dates)),
    activity_packet_span_seconds = as.numeric(span_value[[2L]])
  )
}

localize_metric <- function(input, sensors) {
  unknown <- setdiff(unique(input$sensor_name), sensors$sensor_name)
  if (length(unknown)) {
    stop_pipeline("20-second input contains unknown sensor(s): ",
                  paste(unknown, collapse = ", "))
  }
  located <- data.table::copy(input)
  data.table::setorder(
    located, source_address, timestamp, -strength_sum, sensor_name
  )
  located <- located[, .SD[1L], by = .(source_address, timestamp)]
  located <- sensors[
    located, on = "sensor_name", nomatch = 0L,
    .(timestamp, source_address, sensor_name, x, y, strength_sum, detections)
  ]
  data.table::setorder(located, timestamp, source_address, sensor_name)
  assert_unique_key(
    located, c("source_address", "timestamp"), "Location output"
  )
  located
}

split_metric_trajectories <- function(located, gap_seconds) {
  trajectories <- data.table::copy(located)
  data.table::setorder(trajectories, source_address, timestamp, sensor_name)
  trajectories[, gap_from_previous_seconds := c(
    NA_real_, diff(as.numeric(timestamp))
  ), by = source_address]
  trajectories[, trajectory_id := cumsum(
    is.na(gap_from_previous_seconds) | gap_from_previous_seconds > gap_seconds
  ), by = source_address]
  trajectories
}

summarize_track_metric <- function(trajectory_rows) {
  track <- trajectory_rows[, .(
    start_time = min(timestamp),
    end_time = max(timestamp),
    duration_seconds = as.numeric(max(timestamp) - min(timestamp)),
    n_windows = .N,
    origin = sensor_name[[1L]],
    destination = sensor_name[[.N]]
  ), by = .(source_address, trajectory_id)]
  track[, is_od := as.integer(n_windows >= 2L & origin != destination)]
  data.table::setorder(track, source_address, trajectory_id)

  od <- track[is_od == 1L, .(
    n_trajectories = .N,
    n_retained_identifiers = data.table::uniqueN(source_address)
  ), by = .(origin, destination)]
  data.table::setorder(od, origin, destination)
  list(trajectories = track, od = od)
}

build_revisit_metric <- function(trajectory_rows, track, min_windows, timezone) {
  qualifying <- track[n_windows >= min_windows,
                      .(source_address, trajectory_id)]
  observations <- trajectory_rows[
    qualifying, on = .(source_address, trajectory_id), nomatch = 0L
  ]
  observations[, local_date := format(
    timestamp, "%Y-%m-%d", tz = timezone, usetz = FALSE
  )]
  revisits <- observations[, {
    dates <- sort(unique(local_date))
    list(
      n_qualifying_trajectories = data.table::uniqueN(trajectory_id),
      n_observed_local_dates = length(dates),
      observed_local_dates = paste(dates, collapse = ";"),
      first_local_date = dates[[1L]],
      last_local_date = dates[[length(dates)]]
    )
  }, by = source_address]
  revisits[, revisit_class := ifelse(
    n_observed_local_dates == 1L, "Single-day observed", "Multi-day observed"
  )]
  data.table::setorder(revisits, source_address)
  revisits
}

build_activity_metric <- function(
  trajectory_rows, track, min_windows, max_duration_seconds,
  distance_metres, continuity_gap_seconds, min_duration_seconds
) {
  valid <- track[
    n_windows >= min_windows & duration_seconds <= max_duration_seconds,
    .(source_address, trajectory_id)
  ]
  rows <- trajectory_rows[
    valid, on = .(source_address, trajectory_id), nomatch = 0L
  ]
  data.table::setorder(rows, source_address, trajectory_id, timestamp, sensor_name)
  if (!nrow(rows)) stop_pipeline("no trajectory qualifies for Activities")

  cluster <- integer(nrow(rows))
  anchor_x <- NA_real_
  anchor_y <- NA_real_
  current_cluster <- 0L
  for (index in seq_len(nrow(rows))) {
    new_trajectory <- index == 1L ||
      rows$source_address[[index]] != rows$source_address[[index - 1L]] ||
      rows$trajectory_id[[index]] != rows$trajectory_id[[index - 1L]]
    if (new_trajectory) {
      current_cluster <- 1L
      anchor_x <- rows$x[[index]]
      anchor_y <- rows$y[[index]]
    } else {
      distance <- sqrt(
        (rows$x[[index]] - anchor_x)^2 + (rows$y[[index]] - anchor_y)^2
      )
      if (distance > distance_metres) {
        current_cluster <- current_cluster + 1L
        anchor_x <- rows$x[[index]]
        anchor_y <- rows$y[[index]]
      }
    }
    cluster[[index]] <- current_cluster
  }
  rows[, cluster_id := cluster]
  rows[, gap_within_cluster_seconds := c(
    NA_real_, diff(as.numeric(timestamp))
  ), by = .(source_address, trajectory_id, cluster_id)]
  rows[, episode_id := cumsum(
    is.na(gap_within_cluster_seconds) |
      gap_within_cluster_seconds >= continuity_gap_seconds
  ), by = .(source_address, trajectory_id, cluster_id)]

  group <- c("source_address", "trajectory_id", "cluster_id", "episode_id")
  episodes <- rows[, .(
    start_time = min(timestamp),
    end_time = max(timestamp),
    duration_seconds = as.numeric(max(timestamp) - min(timestamp)),
    n_windows = .N,
    n_sensors = data.table::uniqueN(sensor_name)
  ), by = group]
  primary <- rows[, .N, by = c(group, "sensor_name")]
  data.table::setorderv(
    primary, c(group, "N", "sensor_name"),
    c(rep(1L, length(group)), -1L, 1L)
  )
  primary <- primary[, .SD[1L], by = group][, c("N") := NULL]
  data.table::setnames(primary, "sensor_name", "primary_sensor")
  episodes <- primary[episodes, on = group]
  episodes[, is_stay := as.integer(duration_seconds >= min_duration_seconds)]
  episodes[, activity_type := ifelse(
    duration_seconds < min_duration_seconds, "Pass-through",
    ifelse(duration_seconds < 900, "Short stay",
           ifelse(duration_seconds < 3600, "Medium stay", "Long stay"))
  )]
  data.table::setorder(
    episodes, source_address, trajectory_id, cluster_id, episode_id
  )
  episodes
}

build_five_metrics <- function(input, sensors, parameters) {
  located <- localize_metric(input, sensors)
  counts <- located[, .(
    n_retained_identifiers = data.table::uniqueN(source_address)
  ), by = .(timestamp, sensor_name)]
  data.table::setorder(counts, timestamp, sensor_name)

  track_rows <- split_metric_trajectories(
    located, parameters$track_gap_seconds
  )
  track_parts <- summarize_track_metric(track_rows)
  visit_rows <- split_metric_trajectories(
    located, parameters$visit_gap_seconds
  )
  visit_parts <- summarize_track_metric(visit_rows)
  revisits <- build_revisit_metric(
    visit_rows, visit_parts$trajectories,
    parameters$revisit_min_windows, parameters$local_timezone
  )
  activities <- build_activity_metric(
    visit_rows, visit_parts$trajectories,
    parameters$activity_min_windows,
    parameters$activity_max_duration_seconds,
    parameters$activity_distance_metres,
    parameters$activity_continuity_gap_seconds,
    parameters$activity_min_duration_seconds
  )

  location_output <- data.table::copy(located)
  location_output[, timestamp_utc := format_utc_z(timestamp)]
  location_output[, timestamp := NULL]
  data.table::setcolorder(location_output, METRIC_LOCATION_COLUMNS)

  count_output <- data.table::copy(counts)
  count_output[, timestamp_utc := format_utc_z(timestamp)]
  count_output[, timestamp := NULL]
  data.table::setcolorder(count_output, METRIC_COUNT_COLUMNS)

  track_output <- data.table::copy(track_parts$trajectories)
  track_output[, `:=`(
    start_utc = format_utc_z(start_time),
    end_utc = format_utc_z(end_time)
  )]
  track_output[, c("start_time", "end_time") := NULL]
  data.table::setcolorder(track_output, METRIC_TRACK_COLUMNS)

  activity_output <- data.table::copy(activities)
  activity_output[, `:=`(
    start_utc = format_utc_z(start_time),
    end_utc = format_utc_z(end_time)
  )]
  activity_output[, c("start_time", "end_time") := NULL]
  data.table::setcolorder(activity_output, METRIC_ACTIVITY_COLUMNS)

  data.table::setcolorder(track_parts$od, METRIC_OD_COLUMNS)
  data.table::setcolorder(revisits, METRIC_REVISIT_COLUMNS)
  list(
    location = location_output,
    count = count_output,
    track_trajectories = track_output,
    track_od = track_parts$od,
    revisits = revisits,
    activities = activity_output
  )
}

write_metric_csv <- function(data, path) {
  directory <- dirname(path)
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(directory)) stop_pipeline("cannot create output directory: ", directory)
  target <- file.path(
    normalizePath(directory, winslash = "/", mustWork = TRUE), basename(path)
  )
  link <- Sys.readlink(target)
  if (length(link) && !is.na(link) && nzchar(link)) {
    stop_pipeline("refusing symbolic-link metric output: ", target)
  }
  temporary <- tempfile("metric-", tmpdir = dirname(target), fileext = ".csv")
  on.exit(if (file.exists(temporary)) unlink(temporary), add = TRUE)
  data.table::fwrite(data, temporary, quote = TRUE, na = "")
  if (file.exists(target) && unlink(target) != 0L) {
    stop_pipeline("cannot replace metric output: ", target)
  }
  if (!file.rename(temporary, target)) {
    stop_pipeline("cannot move metric output into place: ", target)
  }
  invisible(target)
}

json_escape_metric <- function(value) {
  value <- gsub("\\\\", "\\\\\\\\", as.character(value))
  value <- gsub('"', '\\\\"', value, fixed = TRUE)
  value <- gsub("\n", "\\\\n", value, fixed = TRUE)
  value
}

write_metric_manifest <- function(
  path, input_path, sensor_path, fixture_path, parameters, outputs, contract
) {
  rows <- vapply(outputs, nrow, integer(1))
  lines <- c(
    "{",
    '  "workflow": "maintained five-metric synthetic smoke workflow",',
    '  "workflow_version": 2,',
    '  "purpose": "calculation-contract verification; not historical-result reproduction",',
    paste0('  "input_20second": "', json_escape_metric(input_path), '",'),
    paste0('  "sensor_metadata": "', json_escape_metric(sensor_path), '",'),
    paste0('  "fixture_manifest": "', json_escape_metric(fixture_path), '",'),
    '  "time": {',
    '    "stored_timestamps": "UTC with explicit Z",',
    paste0('    "revisit_calendar": "', parameters$local_timezone, '"'),
    '  },',
    '  "identifier_contract": {',
    '    "scheme": "synthetic-role-hmac-sha256-128-v1",',
    '    "scope": "deployment",',
    '    "lowercase_hex_characters": 32,',
    '    "key_status": "public, fixed, test-only; not for field collection",',
    '    "input_kind": "fully synthetic scenario role labels; not MAC addresses",',
    '    "original_address_mapping_exists": false',
    '  },',
    '  "parameters": {',
    paste0('    "track_gap_seconds": ', parameters$track_gap_seconds, ','),
    paste0('    "visit_gap_seconds": ', parameters$visit_gap_seconds, ','),
    paste0('    "revisit_min_windows": ', parameters$revisit_min_windows, ','),
    paste0('    "activity_min_windows": ', parameters$activity_min_windows, ','),
    paste0('    "activity_max_duration_seconds": ',
           parameters$activity_max_duration_seconds, ','),
    paste0('    "activity_distance_metres": ',
           format(parameters$activity_distance_metres, scientific = FALSE), ','),
    paste0('    "activity_continuity_gap_seconds": ',
           parameters$activity_continuity_gap_seconds, ','),
    paste0('    "activity_min_duration_seconds": ',
           parameters$activity_min_duration_seconds),
    '  },',
    '  "definitions": {',
    '    "Location": "one strongest sensor per retained identifier and UTC window; ties use sensor_name ascending",',
    '    "Count": "distinct retained identifiers after Location assignment",',
    '    "Track": "ordered Location rows split by inactivity gap; OD requires at least two windows and different endpoints",',
    '    "Revisits": "distinct Asia/Seoul calendar dates among qualifying trajectories; observed identifier frequency, not people",',
    '    "Activities": "anchor-distance clusters split by continuity gap; stay requires minimum episode duration"',
    '  },',
    '  "fixture_expectations": {',
    paste0('    "moving_identifier": "', contract$moving_identifier, '",'),
    paste0('    "activity_identifier": "', contract$activity_identifier, '",'),
    paste0('    "activity_packet_span_seconds": ',
           format(contract$activity_packet_span_seconds, scientific = FALSE)),
    '  },',
    '  "output_rows": {',
    paste0('    "01_location.csv": ', rows[["location"]], ','),
    paste0('    "02_count.csv": ', rows[["count"]], ','),
    paste0('    "03_track_trajectories.csv": ',
           rows[["track_trajectories"]], ','),
    paste0('    "03_track_od.csv": ', rows[["track_od"]], ','),
    paste0('    "04_revisits.csv": ', rows[["revisits"]], ','),
    paste0('    "05_activities.csv": ', rows[["activities"]]),
    '  }',
    "}"
  )
  directory <- dirname(path)
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  target <- file.path(
    normalizePath(directory, winslash = "/", mustWork = TRUE), basename(path)
  )
  link <- Sys.readlink(target)
  if (length(link) && !is.na(link) && nzchar(link)) {
    stop_pipeline("refusing symbolic-link manifest output: ", target)
  }
  temporary <- tempfile("manifest-", tmpdir = dirname(target), fileext = ".json")
  on.exit(if (file.exists(temporary)) unlink(temporary), add = TRUE)
  writeLines(lines, temporary, useBytes = TRUE)
  if (file.exists(target) && unlink(target) != 0L) {
    stop_pipeline("cannot replace metric manifest: ", target)
  }
  if (!file.rename(temporary, target)) {
    stop_pipeline("cannot move metric manifest into place: ", target)
  }
  invisible(target)
}

read_metric_outputs <- function(output_dir) {
  paths <- metric_output_paths(output_dir)
  columns <- list(
    location = METRIC_LOCATION_COLUMNS,
    count = METRIC_COUNT_COLUMNS,
    track_trajectories = METRIC_TRACK_COLUMNS,
    track_od = METRIC_OD_COLUMNS,
    revisits = METRIC_REVISIT_COLUMNS,
    activities = METRIC_ACTIVITY_COLUMNS
  )
  result <- lapply(names(columns), function(name) {
    path <- assert_input_file(paths[[name]], paste0(name, " output"))
    text_columns <- setdiff(columns[[name]], METRIC_NUMERIC_COLUMNS)
    value <- data.table::fread(
      path, na.strings = c("", "NA"),
      colClasses = list(character = text_columns)
    )
    assert_exact_columns(value, columns[[name]], paste0(name, " output"))
    value
  })
  names(result) <- names(columns)
  result
}

assert_metric_tables_equal <- function(expected, actual, label) {
  if (!identical(names(expected), names(actual)) || nrow(expected) != nrow(actual)) {
    stop_pipeline(label, " output shape differs from an independent rebuild")
  }
  for (name in names(expected)) {
    left <- expected[[name]]
    right <- actual[[name]]
    if (is.numeric(left) || is.integer(left)) {
      left <- as.numeric(left)
      right <- suppressWarnings(as.numeric(right))
      if (anyNA(right) || any(abs(left - right) > 1e-9)) {
        stop_pipeline(label, " numeric column differs: ", name)
      }
    } else if (!identical(as.character(left), as.character(right))) {
      stop_pipeline(label, " text column differs: ", name)
    }
  }
  invisible(TRUE)
}
