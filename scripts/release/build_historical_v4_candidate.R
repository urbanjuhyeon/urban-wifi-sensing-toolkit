# Build an isolated, versioned correction candidate for the two historical
# 20-second datasets. Source and current-release files are read-only.

suppressPackageStartupMessages({
  library(DBI)
  library(arrow)
  library(digest)
  library(duckdb)
})

CANDIDATE_VERSION <- "historical-v4-candidate-1"
HASH_HEX_LENGTH <- 16L
LOCAL_TIMEZONE <- "Asia/Seoul"
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
  manifest = file.path(output_dir, "candidate_manifest.csv"),
  source_audit = file.path(output_dir, "source_audit.csv")
)

required <- paths[c(
  "campus_current", "district_current", "district_source", "district_sensors"
)]
missing <- names(required)[!file.exists(unlist(required))]
if (length(missing)) stop("Missing input(s): ", paste(missing, collapse = ", "))
for (candidate in paths[c("campus_candidate", "district_candidate")]) {
  if (candidate %in% required || !is_within(candidate, audit_root)) {
    stop("Unsafe candidate output path: ", candidate)
  }
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
sql_path <- function(path) {
  gsub("'", "''", normalizePath(path, winslash = "/", mustWork = FALSE))
}

attach_utc_metadata <- function(path, column = "timestamp") {
  table <- arrow::read_parquet(path, as_data_frame = FALSE)
  index <- match(column, names(table)) - 1L
  if (is.na(index)) stop("Timestamp column not found: ", column)
  utc_type <- arrow::timestamp("us", timezone = "UTC")
  utc_column <- table$GetColumnByName(column)$cast(utc_type)
  table <- table$SetColumn(index, arrow::field(column, utc_type), utc_column)
  temporary <- paste0(path, ".utc.tmp.parquet")
  if (file.exists(temporary)) unlink(temporary)
  arrow::write_parquet(table, temporary, compression = "zstd")
  check <- arrow::read_parquet(temporary, col_select = tidyselect::all_of(column))
  if (!identical(attr(check[[column]], "tzone"), "UTC")) {
    unlink(temporary)
    stop("Failed to attach UTC metadata: ", path)
  }
  if (file.exists(path)) unlink(path)
  if (!file.rename(temporary, path)) stop("Failed to install UTC Parquet: ", path)
}

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "SET threads=1")
dbExecute(con, sprintf(
  "SET temp_directory='%s'", sql_path(file.path(output_dir, "duckdb-temp"))
))

for (output in paths[c("campus_candidate", "district_candidate", "manifest", "source_audit")]) {
  if (file.exists(output)) unlink(output)
}

cat("Building campus candidate (wall clock -> true UTC)...\n")
dbExecute(con, sprintf(
  "COPY (
     SELECT
       make_timestamp(epoch_us(timestamp)) - INTERVAL '%d hours' AS timestamp,
       CAST(source_address AS VARCHAR) AS source_address,
       CAST(sensor_name AS VARCHAR) AS sensor_name,
       CAST(rssi_median AS DOUBLE) AS rssi_median,
       CAST(rssi_sum AS DOUBLE) AS rssi_sum,
       CAST(detections AS BIGINT) AS detections,
       CAST(strength_sum AS DOUBLE) AS strength_sum
     FROM read_parquet('%s')
     ORDER BY 1, 2, 3
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  UTC_OFFSET_HOURS,
  sql_path(paths$campus_current),
  sql_path(paths$campus_candidate)
))
attach_utc_metadata(paths$campus_candidate)

cat("Auditing commercial-district one-second source...\n")
source_audit <- dbGetQuery(con, sprintf(
  "WITH sensor_map AS (
     SELECT CAST(id_last AS VARCHAR) AS id_last
     FROM read_csv_auto('%s', header = true)
   ), mapped AS (
     SELECT
       CAST(w.timestamp_wifi AS TIMESTAMP) AS timestamp_local,
       lower(trim(CAST(w.source_address AS VARCHAR))) AS source_address,
       CAST(w.sensor_name AS VARCHAR) AS sensor_name,
       CAST(w.RSSI AS DOUBLE) AS rssi
     FROM read_csv_auto('%s', header = true) AS w
     INNER JOIN sensor_map AS s ON CAST(w.sensor_name AS VARCHAR) = s.id_last
   ), accepted AS (
     SELECT * FROM mapped WHERE rssi > -100.0 AND rssi < 0.0
   ), accepted_old_rounded AS (
     SELECT * FROM mapped
     WHERE CAST(rssi AS BIGINT) > -100 AND CAST(rssi AS BIGINT) < 0
   ), key_counts AS (
     SELECT source_address, sensor_name, timestamp_local, count(*) AS n
     FROM accepted
     GROUP BY 1, 2, 3
   )
   SELECT
     (SELECT count(*) FROM mapped) AS mapped_rows,
     (SELECT count(*) FROM accepted) AS accepted_numeric_filter_rows,
     (SELECT count(*) FROM accepted_old_rounded) AS accepted_old_rounded_filter_rows,
     (SELECT count(*) FROM accepted)
       - (SELECT count(*) FROM accepted_old_rounded) AS filter_row_difference,
     (SELECT count(*) FROM key_counts) AS unique_one_second_keys,
     (SELECT count(*) FROM key_counts WHERE n > 1) AS duplicated_one_second_keys,
     (SELECT coalesce(sum(n - 1), 0) FROM key_counts) AS duplicate_excess_rows,
     (SELECT coalesce(max(n), 0) FROM key_counts) AS maximum_rows_per_one_second_key,
     (SELECT count(*) FROM accepted WHERE rssi != trunc(rssi)) AS fractional_rssi_rows",
  sql_path(paths$district_sensors),
  sql_path(paths$district_source)
))
write.csv(source_audit, paths$source_audit, row.names = FALSE, na = "")

cat("Building commercial-district candidate (deduplicate -> 20 seconds -> UTC)...\n")
dbExecute(con, sprintf(
  "COPY (
     WITH sensor_map AS (
       SELECT CAST(id_last AS VARCHAR) AS id_last,
              CAST(id_sensor AS VARCHAR) AS id_sensor
       FROM read_csv_auto('%s', header = true)
     ), valid AS (
       SELECT
         CAST(w.timestamp_wifi AS TIMESTAMP) AS timestamp_local,
         lower(trim(CAST(w.source_address AS VARCHAR))) AS source_address_raw,
         s.id_sensor AS sensor_name,
         CAST(w.RSSI AS DOUBLE) AS rssi
       FROM read_csv_auto('%s', header = true) AS w
       INNER JOIN sensor_map AS s
         ON CAST(w.sensor_name AS VARCHAR) = s.id_last
       WHERE CAST(w.RSSI AS DOUBLE) > -100.0
         AND CAST(w.RSSI AS DOUBLE) < 0.0
     ), unique_seconds AS (
       SELECT timestamp_local, source_address_raw, sensor_name,
              CAST(median(rssi) AS DOUBLE) AS rssi
       FROM valid
       GROUP BY 1, 2, 3
     ), windowed AS (
       SELECT
         date_trunc('minute', timestamp_local)
           + CAST(floor(date_part('second', timestamp_local) / 20) AS BIGINT)
             * INTERVAL '20 seconds' AS window_local,
         source_address_raw,
         sensor_name,
         rssi
       FROM unique_seconds
     )
     SELECT
       window_local - INTERVAL '%d hours' AS timestamp,
       substr(sha256(source_address_raw), 1, %d) AS source_address,
       sensor_name,
       CAST(median(rssi) AS DOUBLE) AS rssi_median,
       CAST(sum(rssi) AS DOUBLE) AS rssi_sum,
       CAST(count(*) AS BIGINT) AS detections,
       CAST(sum(100.0 + rssi) AS DOUBLE) AS strength_sum
     FROM windowed
     GROUP BY 1, source_address_raw, sensor_name
     HAVING count(*) BETWEEN 1 AND 20
     ORDER BY 1, 2, 3
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  sql_path(paths$district_sensors),
  sql_path(paths$district_source),
  UTC_OFFSET_HOURS,
  HASH_HEX_LENGTH,
  sql_path(paths$district_candidate)
))
attach_utc_metadata(paths$district_candidate)

summarize_candidate <- function(site, path) {
  result <- dbGetQuery(con, sprintf(
    "SELECT
       count(*) AS n_records,
       count(DISTINCT source_address) AS n_devices,
       count(DISTINCT sensor_name) AS n_sensors,
       min(make_timestamp(epoch_us(timestamp))) AS start_utc,
       max(make_timestamp(epoch_us(timestamp))) AS end_utc,
       min(make_timestamp(epoch_us(timestamp)) + INTERVAL '%d hours') AS start_local,
       max(make_timestamp(epoch_us(timestamp)) + INTERVAL '%d hours') AS end_local,
       sum(detections) AS total_detections,
       sum(CASE WHEN detections < 1 OR detections > 20 THEN 1 ELSE 0 END)
         AS invalid_detections,
       sum(CASE WHEN abs(strength_sum - (100.0 * detections + rssi_sum)) > 1e-9
                THEN 1 ELSE 0 END) AS invalid_strength
     FROM read_parquet('%s')",
    UTC_OFFSET_HOURS, UTC_OFFSET_HOURS, sql_path(path)
  ))
  data.frame(
    candidate_version = CANDIDATE_VERSION,
    site = site,
    file = basename(path),
    size_bytes = file.info(path)$size,
    sha256 = digest(path, algo = "sha256", file = TRUE),
    timezone = "UTC",
    local_timezone = LOCAL_TIMEZONE,
    result,
    check.names = FALSE
  )
}

manifest <- rbind(
  summarize_candidate("UNIST campus", paths$campus_candidate),
  summarize_candidate("Commercial district", paths$district_candidate)
)
write.csv(manifest, paths$manifest, row.names = FALSE, na = "")

if (any(manifest$invalid_detections != 0) || any(manifest$invalid_strength != 0)) {
  stop("Candidate invariants failed; inspect ", paths$manifest)
}

cat("\nCandidate manifest:\n")
print(manifest, row.names = FALSE)
cat("\nDistrict source audit:\n")
print(source_audit, row.names = FALSE)
cat("\nWrote isolated candidate to:\n", output_dir, "\n")
