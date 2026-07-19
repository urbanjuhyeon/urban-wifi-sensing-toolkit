# Verify and quantify the isolated historical v4 candidate. The current release
# is normalized by shifting its mislabeled wall-clock values nine hours before
# row and Location comparisons.

suppressPackageStartupMessages({
  library(DBI)
  library(arrow)
  library(duckdb)
})

CANDIDATE_VERSION <- "historical-v4-candidate-1"
HASH_HEX_LENGTH <- 16L
UTC_OFFSET_HOURS <- 9L

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript")
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), winslash = "/")
base_dir <- normalizePath(file.path(dirname(script_path), "../.."), winslash = "/")
audit_root <- normalizePath(
  file.path(base_dir, "tmp/historical-v4-audit"),
  winslash = "/",
  mustWork = FALSE
)

output_argument <- grep("^--output=", commandArgs(TRUE), value = TRUE)
output_dir <- if (length(output_argument)) {
  normalizePath(
    sub("^--output=", "", output_argument[[1L]]),
    winslash = "/",
    mustWork = FALSE
  )
} else {
  file.path(audit_root, CANDIDATE_VERSION)
}

is_within <- function(path, parent) {
  path <- tolower(chartr("\\", "/", normalizePath(path, winslash = "/", mustWork = FALSE)))
  parent <- tolower(chartr("\\", "/", normalizePath(parent, winslash = "/", mustWork = FALSE)))
  identical(path, parent) || startsWith(path, paste0(parent, "/"))
}
if (!is_within(output_dir, audit_root)) {
  stop("Output must remain under tmp/historical-v4-audit")
}

paths <- list(
  campus_current = file.path(
    base_dir, "workflow/unist19_main/data/wifi_unist19_20sec.parquet"
  ),
  district_current = file.path(
    base_dir, "workflow/uou20/data/wifi_uou20_20sec.parquet"
  ),
  district_source = file.path(
    base_dir, "workflow/uou20/data/wifi_uou20_1sec.csv"
  ),
  district_sensors = file.path(
    base_dir, "workflow/uou20/output/sensors_coords.csv"
  ),
  campus_candidate = file.path(
    output_dir, "wifi_unist19_20sec_v4-candidate.parquet"
  ),
  district_candidate = file.path(
    output_dir, "wifi_uou20_20sec_v4-candidate.parquet"
  ),
  source_audit = file.path(output_dir, "source_audit.csv"),
  row_impact = file.path(output_dir, "row_impact.csv"),
  location_impact = file.path(output_dir, "location_impact.csv"),
  daily = file.path(output_dir, "daily_aggregate_comparison.csv"),
  hourly = file.path(output_dir, "hourly_aggregate_comparison.csv"),
  aggregate_summary = file.path(output_dir, "aggregate_impact_summary.csv"),
  checks = file.path(output_dir, "verification_checks.csv"),
  report = file.path(output_dir, "audit_report.md")
)

required <- paths[c(
  "campus_current", "district_current", "district_source", "district_sensors",
  "campus_candidate", "district_candidate", "source_audit"
)]
missing <- names(required)[!file.exists(unlist(required))]
if (length(missing)) stop("Missing input(s): ", paste(missing, collapse = ", "))

sql_path <- function(path) {
  gsub("'", "''", normalizePath(path, winslash = "/", mustWork = FALSE))
}
con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "SET threads=1")
dbExecute(con, sprintf(
  "SET temp_directory='%s'", sql_path(file.path(output_dir, "duckdb-temp-verify"))
))

register_site <- function(prefix, current, candidate) {
  dbExecute(con, sprintf(
    "CREATE TEMP VIEW %s_current AS
     SELECT
       make_timestamp(epoch_us(timestamp)) - INTERVAL '%d hours' AS timestamp,
       CAST(source_address AS VARCHAR) AS source_address,
       CAST(sensor_name AS VARCHAR) AS sensor_name,
       CAST(rssi_median AS DOUBLE) AS rssi_median,
       CAST(rssi_sum AS DOUBLE) AS rssi_sum,
       CAST(detections AS BIGINT) AS detections,
       CAST(strength_sum AS DOUBLE) AS strength_sum
     FROM read_parquet('%s')",
    prefix, UTC_OFFSET_HOURS, sql_path(current)
  ))
  dbExecute(con, sprintf(
    "CREATE TEMP VIEW %s_candidate AS
     SELECT
       make_timestamp(epoch_us(timestamp)) AS timestamp,
       CAST(source_address AS VARCHAR) AS source_address,
       CAST(sensor_name AS VARCHAR) AS sensor_name,
       CAST(rssi_median AS DOUBLE) AS rssi_median,
       CAST(rssi_sum AS DOUBLE) AS rssi_sum,
       CAST(detections AS BIGINT) AS detections,
       CAST(strength_sum AS DOUBLE) AS strength_sum
     FROM read_parquet('%s')",
    prefix, sql_path(candidate)
  ))
}
register_site("campus", paths$campus_current, paths$campus_candidate)
register_site("district", paths$district_current, paths$district_candidate)

measure_changed <- paste(
  "abs(c.rssi_median - v.rssi_median) > 1e-9",
  "abs(c.rssi_sum - v.rssi_sum) > 1e-9",
  "c.detections IS DISTINCT FROM v.detections",
  "abs(c.strength_sum - v.strength_sum) > 1e-9",
  sep = " OR "
)

row_impact_for <- function(site, prefix) {
  query <- sprintf(
    "WITH paired AS (
       SELECT
         c.source_address AS current_source,
         v.source_address AS candidate_source,
         CASE WHEN c.source_address IS NOT NULL AND v.source_address IS NOT NULL
              THEN (%s) ELSE NULL END AS measure_changed,
         CASE WHEN c.source_address IS NOT NULL AND v.source_address IS NOT NULL
              THEN abs(c.rssi_median - v.rssi_median) > 1e-9 ELSE NULL END
           AS rssi_median_changed,
         CASE WHEN c.source_address IS NOT NULL AND v.source_address IS NOT NULL
              THEN abs(c.rssi_sum - v.rssi_sum) > 1e-9 ELSE NULL END
           AS rssi_sum_changed,
         CASE WHEN c.source_address IS NOT NULL AND v.source_address IS NOT NULL
              THEN c.detections IS DISTINCT FROM v.detections ELSE NULL END
           AS detections_changed,
         CASE WHEN c.source_address IS NOT NULL AND v.source_address IS NOT NULL
              THEN abs(c.strength_sum - v.strength_sum) > 1e-9 ELSE NULL END
           AS strength_sum_changed
       FROM %s_current c
       FULL OUTER JOIN %s_candidate v
         USING (timestamp, source_address, sensor_name)
     )
     SELECT
       '%s' AS site,
       count(*) FILTER (WHERE current_source IS NOT NULL) AS current_rows,
       count(*) FILTER (WHERE candidate_source IS NOT NULL) AS candidate_rows,
       count(*) FILTER (WHERE current_source IS NOT NULL AND candidate_source IS NOT NULL)
         AS matched_keys,
       count(*) FILTER (WHERE current_source IS NULL) AS candidate_only_keys,
       count(*) FILTER (WHERE candidate_source IS NULL) AS current_only_keys,
       count(*) FILTER (WHERE measure_changed) AS matched_rows_with_changed_values,
       count(*) FILTER (WHERE rssi_median_changed) AS rows_changed_rssi_median,
       count(*) FILTER (WHERE rssi_sum_changed) AS rows_changed_rssi_sum,
       count(*) FILTER (WHERE detections_changed) AS rows_changed_detections,
       count(*) FILTER (WHERE strength_sum_changed) AS rows_changed_strength_sum,
       count(*) FILTER (WHERE measure_changed = false) AS fully_unchanged_rows,
       count(*) FILTER (WHERE current_source IS NULL OR candidate_source IS NULL
                             OR measure_changed) AS changed_union_rows
     FROM paired",
    measure_changed, prefix, prefix, site
  )
  dbGetQuery(con, query)
}
row_impact <- rbind(
  row_impact_for("UNIST campus", "campus"),
  row_impact_for("Commercial district", "district")
)
write.csv(row_impact, paths$row_impact, row.names = FALSE, na = "")

overview_for <- function(site, prefix, version) {
  table <- paste0(prefix, "_", version)
  dbGetQuery(con, sprintf(
    "SELECT '%s' AS site, '%s' AS version,
            count(*) AS records,
            count(DISTINCT source_address) AS devices,
            count(DISTINCT sensor_name) AS sensors,
            count(DISTINCT (source_address, timestamp)) AS device_windows,
            sum(detections) AS total_detections,
            min(detections) AS minimum_detections,
            max(detections) AS maximum_detections,
            count(*) FILTER (WHERE detections < 1 OR detections > 20)
              AS rows_outside_one_to_twenty
     FROM %s",
    site, version, table
  ))
}
overview <- do.call(rbind, list(
  overview_for("UNIST campus", "campus", "current"),
  overview_for("UNIST campus", "campus", "candidate"),
  overview_for("Commercial district", "district", "current"),
  overview_for("Commercial district", "district", "candidate")
))
write.csv(overview, file.path(output_dir, "dataset_overview.csv"), row.names = FALSE, na = "")

create_locations <- function(prefix, version) {
  dbExecute(con, sprintf(
    "CREATE TEMP TABLE %s_%s_location AS
     SELECT source_address, timestamp, sensor_name, strength_sum, detections
     FROM %s_%s
     QUALIFY row_number() OVER (
       PARTITION BY source_address, timestamp
       ORDER BY strength_sum DESC, sensor_name ASC
     ) = 1",
    prefix, version, prefix, version
  ))
}
for (prefix in c("campus", "district")) {
  create_locations(prefix, "current")
  create_locations(prefix, "candidate")
}

location_impact_for <- function(site, prefix) {
  dbGetQuery(con, sprintf(
    "WITH paired AS (
       SELECT
         c.source_address AS current_source,
         v.source_address AS candidate_source,
         c.sensor_name AS current_sensor,
         v.sensor_name AS candidate_sensor
       FROM %s_current_location c
       FULL OUTER JOIN %s_candidate_location v
         USING (source_address, timestamp)
     )
     SELECT '%s' AS site,
            count(*) FILTER (WHERE current_source IS NOT NULL) AS current_device_windows,
            count(*) FILTER (WHERE candidate_source IS NOT NULL) AS candidate_device_windows,
            count(*) FILTER (WHERE current_source IS NULL) AS candidate_only_device_windows,
            count(*) FILTER (WHERE candidate_source IS NULL) AS current_only_device_windows,
            count(*) FILTER (WHERE current_source IS NOT NULL
                                   AND candidate_source IS NOT NULL
                                   AND current_sensor = candidate_sensor)
              AS same_location_assignments,
            count(*) FILTER (WHERE current_source IS NOT NULL
                                   AND candidate_source IS NOT NULL
                                   AND current_sensor != candidate_sensor)
              AS changed_location_assignments
     FROM paired",
    prefix, prefix, site
  ))
}
location_impact <- rbind(
  location_impact_for("UNIST campus", "campus"),
  location_impact_for("Commercial district", "district")
)
write.csv(location_impact, paths$location_impact, row.names = FALSE, na = "")

aggregate_query <- function(site, prefix, period) {
  period_expression <- switch(
    period,
    day = "CAST(timestamp + INTERVAL '9 hours' AS DATE)",
    hour = "date_trunc('hour', timestamp + INTERVAL '9 hours')",
    stop("Unknown period")
  )
  dbGetQuery(con, sprintf(
    "WITH current_agg AS (
       SELECT %s AS local_period,
              count(*) AS sensor_window_rows,
              count(DISTINCT (source_address, timestamp)) AS device_windows,
              count(DISTINCT source_address) AS devices,
              sum(detections) AS detections
       FROM %s_current GROUP BY 1
     ), candidate_agg AS (
       SELECT %s AS local_period,
              count(*) AS sensor_window_rows,
              count(DISTINCT (source_address, timestamp)) AS device_windows,
              count(DISTINCT source_address) AS devices,
              sum(detections) AS detections
       FROM %s_candidate GROUP BY 1
     )
     SELECT '%s' AS site,
            coalesce(c.local_period, v.local_period) AS local_period,
            c.sensor_window_rows AS current_sensor_window_rows,
            v.sensor_window_rows AS candidate_sensor_window_rows,
            v.sensor_window_rows - c.sensor_window_rows AS sensor_window_row_difference,
            c.device_windows AS current_device_windows,
            v.device_windows AS candidate_device_windows,
            v.device_windows - c.device_windows AS device_window_difference,
            c.devices AS current_devices,
            v.devices AS candidate_devices,
            v.devices - c.devices AS device_difference,
            c.detections AS current_detections,
            v.detections AS candidate_detections,
            v.detections - c.detections AS detection_difference
     FROM current_agg c FULL OUTER JOIN candidate_agg v USING (local_period)
     ORDER BY local_period",
    period_expression, prefix, period_expression, prefix, site
  ))
}

daily <- rbind(
  aggregate_query("UNIST campus", "campus", "day"),
  aggregate_query("Commercial district", "district", "day")
)
hourly <- rbind(
  aggregate_query("UNIST campus", "campus", "hour"),
  aggregate_query("Commercial district", "district", "hour")
)
write.csv(daily, paths$daily, row.names = FALSE, na = "")
write.csv(hourly, paths$hourly, row.names = FALSE, na = "")

aggregate_summary_for <- function(data, grain) {
  do.call(rbind, lapply(split(data, data$site), function(part) {
    data.frame(
      site = part$site[[1L]],
      grain = grain,
      periods = nrow(part),
      periods_with_row_difference = sum(part$sensor_window_row_difference != 0, na.rm = TRUE),
      periods_with_device_window_difference = sum(part$device_window_difference != 0, na.rm = TRUE),
      periods_with_device_difference = sum(part$device_difference != 0, na.rm = TRUE),
      periods_with_detection_difference = sum(part$detection_difference != 0, na.rm = TRUE),
      max_abs_row_difference = max(abs(part$sensor_window_row_difference), na.rm = TRUE),
      max_abs_device_window_difference = max(abs(part$device_window_difference), na.rm = TRUE),
      max_abs_device_difference = max(abs(part$device_difference), na.rm = TRUE),
      max_abs_detection_difference = max(abs(part$detection_difference), na.rm = TRUE)
    )
  }))
}
aggregate_summary <- rbind(
  aggregate_summary_for(daily, "local day"),
  aggregate_summary_for(hourly, "local hour")
)
write.csv(aggregate_summary, paths$aggregate_summary, row.names = FALSE, na = "")

schema_checks <- function(site, path) {
  schema <- arrow::read_parquet(path, as_data_frame = FALSE)$schema
  expected <- c(
    "timestamp[us, tz=UTC]", "string", "string", "double", "double",
    "int64", "double"
  )
  actual <- vapply(schema$fields, function(field) field$type$ToString(), character(1))
  names(actual) <- vapply(schema$fields, function(field) field$name, character(1))
  expected_names <- c(
    "timestamp", "source_address", "sensor_name", "rssi_median", "rssi_sum",
    "detections", "strength_sum"
  )
  data.frame(
    site = site,
    check = "physical_schema",
    passed = identical(names(actual), expected_names) && identical(unname(actual), expected),
    detail = paste(paste(names(actual), actual, sep = "="), collapse = "; ")
  )
}

data_checks <- function(site, prefix) {
  result <- dbGetQuery(con, sprintf(
    "SELECT
       count(*) FILTER (WHERE source_address IS NULL OR sensor_name IS NULL
                             OR timestamp IS NULL OR rssi_median IS NULL
                             OR rssi_sum IS NULL OR detections IS NULL
                             OR strength_sum IS NULL) AS null_rows,
       count(*) FILTER (WHERE NOT regexp_full_match(
         lower(source_address), '[0-9a-f]{%d}'
       )) AS invalid_hash_rows,
       count(*) - count(DISTINCT (timestamp, source_address, sensor_name))
         AS duplicate_keys,
       count(*) FILTER (WHERE detections < 1 OR detections > 20)
         AS invalid_detection_rows,
       count(*) FILTER (WHERE abs(strength_sum - (100.0 * detections + rssi_sum)) > 1e-9)
         AS invalid_formula_rows,
       count(*) FILTER (WHERE epoch(timestamp) %% 20 != 0)
         AS misaligned_timestamp_rows
     FROM %s_candidate",
    HASH_HEX_LENGTH, prefix
  ))
  do.call(rbind, lapply(names(result), function(name) {
    data.frame(
      site = site,
      check = name,
      passed = result[[name]][[1L]] == 0,
      detail = as.character(result[[name]][[1L]])
    )
  }))
}

campus_row <- row_impact[row_impact$site == "UNIST campus", ]
row_count_check <- data.frame(
  site = "UNIST campus",
  check = "campus_values_preserved_after_time_alignment",
  passed = campus_row$candidate_only_keys == 0 &&
    campus_row$current_only_keys == 0 &&
    campus_row$matched_rows_with_changed_values == 0,
  detail = sprintf(
    "candidate_only=%s; current_only=%s; changed_values=%s",
    campus_row$candidate_only_keys,
    campus_row$current_only_keys,
    campus_row$matched_rows_with_changed_values
  )
)

district_collision <- dbGetQuery(con, sprintf(
  "WITH sensor_map AS (
     SELECT CAST(id_last AS VARCHAR) AS id_last
     FROM read_csv_auto('%s', header = true)
   ), raw AS (
     SELECT DISTINCT lower(trim(CAST(w.source_address AS VARCHAR))) AS raw_id
     FROM read_csv_auto('%s', header = true) w
     INNER JOIN sensor_map s ON CAST(w.sensor_name AS VARCHAR) = s.id_last
     WHERE CAST(w.RSSI AS DOUBLE) > -100.0 AND CAST(w.RSSI AS DOUBLE) < 0.0
   ), mapping AS (
     SELECT raw_id, substr(sha256(raw_id), 1, %d) AS hashed FROM raw
   )
   SELECT count(*) AS raw_devices,
          count(DISTINCT hashed) AS hashed_devices,
          count(*) - count(DISTINCT hashed) AS collisions
   FROM mapping",
  sql_path(paths$district_sensors), sql_path(paths$district_source), HASH_HEX_LENGTH
))
collision_check <- data.frame(
  site = "Commercial district",
  check = "identifier_hash_collisions",
  passed = district_collision$collisions == 0,
  detail = sprintf(
    "raw_devices=%s; hashed_devices=%s; collisions=%s",
    district_collision$raw_devices,
    district_collision$hashed_devices,
    district_collision$collisions
  )
)

checks <- rbind(
  schema_checks("UNIST campus", paths$campus_candidate),
  schema_checks("Commercial district", paths$district_candidate),
  data_checks("UNIST campus", "campus"),
  data_checks("Commercial district", "district"),
  row_count_check,
  collision_check
)
write.csv(checks, paths$checks, row.names = FALSE, na = "")

source_audit <- read.csv(paths$source_audit, check.names = FALSE)
district_row <- row_impact[row_impact$site == "Commercial district", ]
district_location <- location_impact[location_impact$site == "Commercial district", ]
district_overview <- overview[overview$site == "Commercial district", ]
district_aggregate <- aggregate_summary[
  aggregate_summary$site == "Commercial district", ]

needs_rerun <- district_row$changed_union_rows > 0 ||
  district_location$changed_location_assignments > 0 ||
  district_location$candidate_only_device_windows > 0 ||
  district_location$current_only_device_windows > 0

format_integer <- function(value) format(value, big.mark = ",", scientific = FALSE)
lines <- c(
  "# Historical v4 candidate audit report",
  "",
  paste0("Candidate: `", CANDIDATE_VERSION, "`"),
  "",
  "This report compares an isolated correction candidate with the current release. ",
  "The current timestamps are shifted by nine hours only for comparison, so timezone ",
  "metadata repair is not misclassified as a substantive data change.",
  "",
  "## Source audit",
  "",
  sprintf(
    "- District rows accepted by numeric `-100 < RSSI < 0`: %s.",
    format_integer(source_audit$accepted_numeric_filter_rows)
  ),
  sprintf(
    "- One-second keys with duplicates: %s; excess rows removed: %s; maximum multiplicity: %s.",
    format_integer(source_audit$duplicated_one_second_keys),
    format_integer(source_audit$duplicate_excess_rows),
    format_integer(source_audit$maximum_rows_per_one_second_key)
  ),
  sprintf(
    "- Fractional RSSI rows retained without integer rounding: %s.",
    format_integer(source_audit$fractional_rssi_rows)
  ),
  sprintf(
    "- Difference between the numeric filter and the old rounded filter: %s input rows.",
    format_integer(source_audit$filter_row_difference)
  ),
  "",
  "## Candidate impact after time alignment",
  "",
  sprintf(
    "- Campus: %s rows; %s changed keys or values. All non-time values are preserved: **%s**.",
    format_integer(campus_row$candidate_rows),
    format_integer(campus_row$changed_union_rows),
    ifelse(row_count_check$passed, "yes", "no")
  ),
  sprintf(
    "- District: current %s rows, candidate %s rows; %s candidate-only keys, %s current-only keys, and %s matched rows with changed values.",
    format_integer(district_row$current_rows),
    format_integer(district_row$candidate_rows),
    format_integer(district_row$candidate_only_keys),
    format_integer(district_row$current_only_keys),
    format_integer(district_row$matched_rows_with_changed_values)
  ),
  sprintf(
    "- Those district changes affect RSSI median in %s rows, RSSI sum in %s, detections in %s, and strength sum in %s.",
    format_integer(district_row$rows_changed_rssi_median),
    format_integer(district_row$rows_changed_rssi_sum),
    format_integer(district_row$rows_changed_detections),
    format_integer(district_row$rows_changed_strength_sum)
  ),
  sprintf(
    "- District total one-second detections: current %s, candidate %s (difference %s); rows outside 1--20: current %s, candidate %s.",
    format_integer(district_overview$total_detections[
      district_overview$version == "current"
    ]),
    format_integer(district_overview$total_detections[
      district_overview$version == "candidate"
    ]),
    format_integer(
      district_overview$total_detections[district_overview$version == "candidate"] -
        district_overview$total_detections[district_overview$version == "current"]
    ),
    format_integer(district_overview$rows_outside_one_to_twenty[
      district_overview$version == "current"
    ]),
    format_integer(district_overview$rows_outside_one_to_twenty[
      district_overview$version == "candidate"
    ])
  ),
  sprintf(
    "- District devices: current %s, candidate %s; sensors: current %s, candidate %s.",
    format_integer(district_overview$devices[district_overview$version == "current"]),
    format_integer(district_overview$devices[district_overview$version == "candidate"]),
    format_integer(district_overview$sensors[district_overview$version == "current"]),
    format_integer(district_overview$sensors[district_overview$version == "candidate"])
  ),
  sprintf(
    "- District deterministic strongest-sensor Location: %s changed assignments, %s candidate-only device-windows, and %s current-only device-windows.",
    format_integer(district_location$changed_location_assignments),
    format_integer(district_location$candidate_only_device_windows),
    format_integer(district_location$current_only_device_windows)
  ),
  "",
  "## Local calendar aggregates",
  "",
  paste0(
    "Candidate UTC timestamps were converted back to `Asia/Seoul` before daily and hourly ",
    "comparison. Full tables are in `daily_aggregate_comparison.csv` and ",
    "`hourly_aggregate_comparison.csv`."
  ),
  "",
  sprintf(
    "- District local days with a device-count difference: %s of %s; maximum absolute difference: %s devices.",
    format_integer(district_aggregate$periods_with_device_difference[
      district_aggregate$grain == "local day"
    ]),
    format_integer(district_aggregate$periods[district_aggregate$grain == "local day"]),
    format_integer(district_aggregate$max_abs_device_difference[
      district_aggregate$grain == "local day"
    ])
  ),
  sprintf(
    "- District local hours with a device-count difference: %s of %s; maximum absolute difference: %s devices.",
    format_integer(district_aggregate$periods_with_device_difference[
      district_aggregate$grain == "local hour"
    ]),
    format_integer(district_aggregate$periods[district_aggregate$grain == "local hour"]),
    format_integer(district_aggregate$max_abs_device_difference[
      district_aggregate$grain == "local hour"
    ])
  ),
  "",
  "## Verification and decision",
  "",
  sprintf(
    "- Verification checks passed: %s/%s.",
    sum(checks$passed), nrow(checks)
  ),
  sprintf(
    "- Manuscript headline outputs require a controlled rerun against this candidate: **%s**.",
    ifelse(needs_rerun, "yes", "no")
  ),
  "",
  if (needs_rerun) {
    paste0(
      "This does not establish that a published headline is wrong. It establishes that the ",
      "district analytical handoff changes after enforcing the stated one-second-slot ",
      "definition. The DOUBLE schema prevents future rounding, but the audited source has no ",
      "fractional RSSI rows, so the observed changes come from deduplication. District ",
      "Location-dependent Count, Track, ",
      "Revisits, and Activities outputs should therefore be rerun before approving a v4 ",
      "replacement. The current release remains untouched."
    )
  } else {
    paste0(
      "The audit found no key, Location, or calendar-count impact after timezone alignment. ",
      "A v4 release would still require provenance review, but the headline analytical ",
      "outputs do not require rerunning on account of this correction."
    )
  }
)
writeLines(lines, paths$report, useBytes = TRUE)

print(row_impact, row.names = FALSE)
print(location_impact, row.names = FALSE)
print(aggregate_summary, row.names = FALSE)
print(checks, row.names = FALSE)

if (any(!checks$passed)) {
  stop("One or more candidate verification checks failed; see ", paths$checks)
}
cat("\nAll candidate verification checks passed.\n")
cat("Impact report: ", paths$report, "\n", sep = "")
