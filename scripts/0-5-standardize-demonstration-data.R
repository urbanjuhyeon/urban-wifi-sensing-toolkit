# =============================================================================
# Build the restricted historical 20-second intermediate (legacy provenance)
# =============================================================================
#
# This is not the public handoff. After verification, pass it through the
# release-specific keyed re-pseudonymization in scripts/release/.
#
# Internal format (one row per pseudonym x sensor x 20-second window):
#   timestamp, source_address, sensor_name, rssi_median, rssi_sum,
#   detections, strength_sum
#
# The commercial-district 1-second file remains the internal source of truth.
# It is filtered and aggregated here before release. Multiple sensor rows in the
# same device-window are deliberately retained so that Location assignment can
# be reproduced downstream.
#
# Inputs:
#   workflow/unist19_source/wifi_clean.parquet
#   workflow/uou20/data/wifi_uou20_1sec.csv
#   workflow/uou20/output/sensors_coords.csv
#
# Outputs:
#   workflow/unist19_main/data/wifi_unist19_20sec.parquet
#   workflow/uou20/data/wifi_uou20_20sec.parquet
#   workflow/data_release_20sec_manifest.csv
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(digest)
})

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")
source(file.path(base_dir, "scripts/_legacy_identifier_hash.R"))
source(file.path(base_dir, "scripts/_parquet_time.R"))

paths <- list(
  campus_source = file.path(base_dir, "workflow/unist19_source/wifi_clean.parquet"),
  campus_public = file.path(base_dir, "workflow/unist19_main/data/wifi_unist19_20sec.parquet"),
  district_source = file.path(base_dir, "workflow/uou20/data/wifi_uou20_1sec.csv"),
  district_sensors = file.path(base_dir, "workflow/uou20/output/sensors_coords.csv"),
  district_public = file.path(base_dir, "workflow/uou20/data/wifi_uou20_20sec.parquet"),
  manifest = file.path(base_dir, "workflow/data_release_20sec_manifest.csv")
)

missing_inputs <- names(paths)[names(paths) %in% c(
  "campus_source", "district_source", "district_sensors"
) & !file.exists(unlist(paths))]
if (length(missing_inputs)) {
  stop("Missing input(s): ", paste(missing_inputs, collapse = ", "))
}

sql_path <- function(path) gsub("'", "''", normalizePath(path, winslash = "/", mustWork = FALSE))

for (output in paths[c("campus_public", "district_public", "manifest")]) {
  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  if (file.exists(output)) unlink(output)
}

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

cat("Writing standardized campus Parquet...\n")
dbExecute(con, sprintf(
  "COPY (
     SELECT
       date_trunc('minute', CAST(timestamp AS TIMESTAMP))
         + CAST(floor(date_part('second', CAST(timestamp AS TIMESTAMP)) / 20) AS BIGINT)
           * INTERVAL '20 seconds' AS timestamp,
       source_address,
       sensor_name,
       CAST(median(rssi) AS DOUBLE) AS rssi_median,
       CAST(sum(rssi) AS BIGINT) AS rssi_sum,
       CAST(count(*) AS BIGINT) AS detections,
       CAST(sum(100 + rssi) AS BIGINT) AS strength_sum
     FROM read_parquet('%s')
     GROUP BY 1, 2, 3
     ORDER BY 1, 2, 3
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  sql_path(paths$campus_source), sql_path(paths$campus_public)
))
attach_utc_timestamp_metadata(paths$campus_public)

cat("Writing standardized commercial-district Parquet...\n")
dbExecute(con, sprintf(
  "COPY (
     WITH sensor_map AS (
       SELECT id_last, id_sensor
       FROM read_csv_auto('%s', header = true)
     ),
     valid AS (
       SELECT
         CAST(w.timestamp_wifi AS TIMESTAMP) AS timestamp_1sec,
         w.source_address,
         s.id_sensor AS sensor_name,
         CAST(w.RSSI AS BIGINT) AS rssi
       FROM read_csv_auto('%s', header = true) AS w
       INNER JOIN sensor_map AS s ON w.sensor_name = s.id_last
       WHERE CAST(w.RSSI AS BIGINT) > -100
         AND CAST(w.RSSI AS BIGINT) < 0
     ),
     windowed AS (
       SELECT
         date_trunc('minute', timestamp_1sec)
           + CAST(floor(date_part('second', timestamp_1sec) / 20) AS BIGINT)
             * INTERVAL '20 seconds' AS timestamp,
         source_address,
         sensor_name,
         rssi
       FROM valid
     )
     SELECT
       timestamp,
       substr(sha256(lower(trim(source_address))), 1, %d) AS source_address,
       sensor_name,
       CAST(median(rssi) AS DOUBLE) AS rssi_median,
       CAST(sum(rssi) AS BIGINT) AS rssi_sum,
       CAST(count(*) AS BIGINT) AS detections,
       CAST(sum(100 + rssi) AS BIGINT) AS strength_sum
     FROM windowed
     GROUP BY timestamp, source_address, sensor_name
     ORDER BY timestamp, source_address, sensor_name
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  sql_path(paths$district_sensors),
  sql_path(paths$district_source),
  LEGACY_IDENTIFIER_HASH_HEX_LENGTH,
  sql_path(paths$district_public)
))
attach_utc_timestamp_metadata(paths$district_public)

summarize_parquet <- function(site, path) {
  query <- sprintf(
    "SELECT
       count(*) AS n_records,
       count(DISTINCT source_address) AS n_devices,
       count(DISTINCT sensor_name) AS n_sensors,
       min(timestamp) AS start_time,
       max(timestamp) AS end_time,
       sum(CASE WHEN strength_sum != 100 * detections + rssi_sum THEN 1 ELSE 0 END)
         AS invalid_strength_rows
     FROM read_parquet('%s')",
    sql_path(path)
  )
  result <- dbGetQuery(con, query)
  data.frame(
    site = site,
    file = basename(path),
    size_bytes = file.info(path)$size,
    sha256 = digest(path, algo = "sha256", file = TRUE),
    result,
    check.names = FALSE
  )
}

manifest <- rbind(
  summarize_parquet("UNIST campus", paths$campus_public),
  summarize_parquet("Commercial district", paths$district_public)
)
write.csv(manifest, paths$manifest, row.names = FALSE, na = "")

cat("\nStandardized release manifest:\n")
print(manifest, row.names = FALSE)
if (any(manifest$invalid_strength_rows != 0)) {
  stop("strength_sum invariant failed")
}
cat("\nWrote:\n", paste(unlist(paths[c("campus_public", "district_public", "manifest")]),
                         collapse = "\n"), "\n")
