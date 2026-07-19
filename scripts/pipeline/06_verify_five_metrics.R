#!/usr/bin/env Rscript

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), mustWork = TRUE)
script_dir <- dirname(script_path)
source(file.path(script_dir, "_common.R"))
source(file.path(script_dir, "_metrics_common.R"))

usage <- function() {
  cat(paste0(
    "Usage:\n",
    "  Rscript 06_verify_five_metrics.R \\\n",
    "    --input analysis_20second.parquet --sensors synthetic_sensors.csv \\\n",
    "    --fixture-manifest manifest.json --output-dir output [options]\n\n",
    "Options are the same declared thresholds accepted by ",
    "05_build_five_metrics.R.\n"
  ))
}

raw_args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% raw_args) {
  usage()
  quit(status = 0L)
}
options <- parse_pipeline_args(raw_args, defaults = METRIC_PARAMETER_DEFAULTS)
reject_unknown_options(
  options, c(
    "input", "sensors", "fixture_manifest", "output_dir",
    names(METRIC_PARAMETER_DEFAULTS)
  )
)
require_pipeline_args(
  options, c("input", "sensors", "fixture_manifest", "output_dir")
)
require_pipeline_packages(c("data.table", "arrow"))
parameters <- parse_metric_parameters(options)
input <- read_metric_input(options$input)
sensors <- read_metric_sensors(options$sensors)
contract <- read_fixture_contract(options$fixture_manifest)
expected <- build_five_metrics(input, sensors, parameters)
actual <- read_metric_outputs(options$output_dir)
for (name in names(expected)) {
  assert_metric_tables_equal(expected[[name]], actual[[name]], name)
}

# Contract checks that do not merely replay the builder.
if (any(!grepl("Z$", actual$location$timestamp_utc)) ||
    any(!grepl("Z$", actual$track_trajectories$start_utc)) ||
    any(!grepl("Z$", actual$track_trajectories$end_utc)) ||
    any(!grepl("Z$", actual$activities$start_utc)) ||
    any(!grepl("Z$", actual$activities$end_utc))) {
  stop_pipeline("metric timestamps must remain explicit UTC strings ending in Z")
}
if (anyDuplicated(actual$location[, .(source_address, timestamp_utc)])) {
  stop_pipeline("Location is not unique by retained identifier and UTC window")
}
if (sum(actual$count$n_retained_identifiers) != nrow(actual$location)) {
  stop_pipeline("Count does not count each localized identifier-window exactly once")
}
if (any(actual$track_trajectories$is_od == 1L &
        (actual$track_trajectories$n_windows < 2L |
         actual$track_trajectories$origin == actual$track_trajectories$destination))) {
  stop_pipeline("Track has an invalid OD-qualified trajectory")
}

# Boundary tests supplement the checked fixture, whose dates do not straddle
# Korean midnight and whose overlap does not contain an exact strength tie.
test_identifier <- "0123456789abcdef0123456789abcdef"
test_time <- as.POSIXct(0, origin = "1970-01-01", tz = "UTC")
tie_input <- data.table::data.table(
  timestamp = rep(test_time, 2L),
  source_address = rep(test_identifier, 2L),
  sensor_name = c("A02", "A01"),
  strength_sum = c(50, 50),
  detections = c(1L, 1L)
)
tie_result <- localize_metric(tie_input, sensors)
if (nrow(tie_result) != 1L || tie_result$sensor_name != "A01") {
  stop_pipeline("Location tie-breaking is not sensor_name ascending")
}
gap_input <- data.table::data.table(
  timestamp = as.POSIXct(c(0, 1800, 3601), origin = "1970-01-01", tz = "UTC"),
  source_address = rep(test_identifier, 3L),
  sensor_name = rep("A01", 3L),
  x = 0, y = 0, strength_sum = 50, detections = 1L
)
gap_result <- split_metric_trajectories(gap_input, 1800L)
if (!identical(gap_result$trajectory_id, c(1L, 1L, 2L))) {
  stop_pipeline("trajectory gap boundary must split only when gap > threshold")
}
midnight_rows <- data.table::data.table(
  timestamp = as.POSIXct(
    c("2024-01-14 16:00:00", "2024-01-14 16:00:20"), tz = "UTC"
  ),
  source_address = rep(test_identifier, 2L),
  trajectory_id = rep(1L, 2L)
)
midnight_track <- data.table::data.table(
  source_address = test_identifier, trajectory_id = 1L, n_windows = 2L
)
midnight_revisit <- build_revisit_metric(
  midnight_rows, midnight_track, 2L, PIPELINE_LOCAL_TIMEZONE
)
if (midnight_revisit$observed_local_dates != "2024-01-15") {
  stop_pipeline("Revisits did not convert UTC across Asia/Seoul midnight")
}

expected_dates <- paste(contract$moving_local_dates, collapse = ";")
activity_stay <- actual$activities[
  source_address == contract$activity_identifier & is_stay == 1L
]
if (metric_parameters_are_defaults(parameters)) {
  expected_rows <- c(
    location = 32L,
    count = 32L,
    track_trajectories = 3L,
    track_od = 1L,
    revisits = 2L,
    activities = 2L
  )
  actual_rows <- vapply(actual[names(expected_rows)], nrow, integer(1))
  if (!identical(actual_rows, expected_rows)) {
    stop_pipeline(
      "default five-metric fixture row counts changed; expected ",
      paste(names(expected_rows), expected_rows, sep = "=", collapse = ", "),
      "; found ",
      paste(names(actual_rows), actual_rows, sep = "=", collapse = ", ")
    )
  }
  moving_revisit <- actual$revisits[source_address == contract$moving_identifier]
  if (nrow(moving_revisit) != 1L ||
      moving_revisit$revisit_class != "Multi-day observed" ||
      moving_revisit$observed_local_dates != expected_dates ||
      moving_revisit$n_observed_local_dates != length(contract$moving_local_dates)) {
    stop_pipeline("Revisits does not preserve the fixture's Asia/Seoul dates")
  }
  moving_od <- actual$track_trajectories[
    source_address == contract$moving_identifier & is_od == 1L
  ]
  if (nrow(moving_od) != 2L || any(moving_od$origin != "A01") ||
      any(moving_od$destination != "A02")) {
    stop_pipeline("Track does not recover both synthetic A01-to-A02 trajectories")
  }
  if (nrow(actual$track_od) != 1L || actual$track_od$origin != "A01" ||
      actual$track_od$destination != "A02" ||
      actual$track_od$n_trajectories != 2L ||
      actual$track_od$n_retained_identifiers != 1L) {
    stop_pipeline("Track OD summary changed from the frozen synthetic contract")
  }
  if (nrow(activity_stay) != 1L ||
      activity_stay$duration_seconds != 420 ||
      activity_stay$primary_sensor != "A02" ||
      activity_stay$activity_type != "Short stay") {
    stop_pipeline("Activities does not recover the synthetic retained stay")
  }
}

manifest_path <- metric_output_paths(options$output_dir)$manifest
manifest_text <- paste(
  readLines(assert_input_file(manifest_path, "metric manifest"), warn = FALSE),
  collapse = "\n"
)
manifest_required <- c(
  '"purpose": "calculation-contract verification; not historical-result reproduction"',
  '"stored_timestamps": "UTC with explicit Z"',
  '"revisit_calendar": "Asia/Seoul"',
  '"scheme": "synthetic-role-hmac-sha256-128-v1"',
  '"scope": "deployment"',
  '"lowercase_hex_characters": 32',
  '"key_status": "public, fixed, test-only; not for field collection"',
  '"input_kind": "fully synthetic scenario role labels; not MAC addresses"',
  '"original_address_mapping_exists": false',
  paste0('"track_gap_seconds": ', parameters$track_gap_seconds),
  paste0('"visit_gap_seconds": ', parameters$visit_gap_seconds),
  paste0('"activity_distance_metres": ',
         format(parameters$activity_distance_metres, scientific = FALSE)),
  paste0('"activity_min_duration_seconds": ',
         parameters$activity_min_duration_seconds),
  '"Revisits": "distinct Asia/Seoul calendar dates among qualifying trajectories; observed identifier frequency, not people"'
)
if (any(!vapply(manifest_required, grepl, logical(1), x = manifest_text, fixed = TRUE))) {
  stop_pipeline("metric manifest omits a required definition or parameter")
}
if (!grepl(
      paste0('"moving_identifier": "', contract$moving_identifier, '"'),
      manifest_text, fixed = TRUE
    ) || !grepl(
      paste0('"activity_identifier": "', contract$activity_identifier, '"'),
      manifest_text, fixed = TRUE
    )) {
  stop_pipeline("metric manifest fixture identifiers do not match its input contract")
}
manifest_rows <- c(
  "01_location.csv" = nrow(actual$location),
  "02_count.csv" = nrow(actual$count),
  "03_track_trajectories.csv" = nrow(actual$track_trajectories),
  "03_track_od.csv" = nrow(actual$track_od),
  "04_revisits.csv" = nrow(actual$revisits),
  "05_activities.csv" = nrow(actual$activities)
)
for (file_name in names(manifest_rows)) {
  manifest_lines <- strsplit(manifest_text, "\n", fixed = TRUE)[[1L]]
  line <- manifest_lines[vapply(
    manifest_lines, grepl, logical(1), pattern = paste0('"', file_name, '"'),
    fixed = TRUE
  )]
  value <- if (length(line) == 1L) suppressWarnings(as.integer(sub(
    '^.*:\\s*([0-9]+),?\\s*$', '\\1', line, perl = TRUE
  ))) else NA_integer_
  if (is.na(value) || value != manifest_rows[[file_name]]) {
    stop_pipeline("metric manifest row count differs for ", file_name)
  }
}

stay_message <- if (nrow(activity_stay)) {
  paste0(activity_stay$duration_seconds[[1L]], " s")
} else {
  "none under the selected thresholds"
}
cat(
  "PASS: maintained five-metric smoke workflow verified\n",
  "  Location:   ", nrow(actual$location), " localized identifier-windows\n",
  "  Count:      ", nrow(actual$count), " sensor-window counts\n",
  "  Track:      ", nrow(actual$track_trajectories), " trajectories; ",
  sum(actual$track_trajectories$is_od), " OD-qualified\n",
  "  Revisits:   local calendar = Asia/Seoul",
  if (metric_parameters_are_defaults(parameters)) paste0("; moving fixture = ", expected_dates) else "",
  "\n",
  "  Activities: retained fixture stay = ", stay_message,
  " (packet-level scenario span ", contract$activity_packet_span_seconds, " s)\n",
  "  Time rule:  UTC storage; Asia/Seoul local calendar only for Revisits\n",
  sep = ""
)
