# =============================================================================
# Verify the restricted historical 20-second intermediate
# =============================================================================
# Confirms that the internal Parquet files preserve the source sensor-window
# aggregates and that deterministic Location assignment is identical before and
# after standardization. This script does not verify the separately keyed public
# handoff. Exact strength ties use sensor_name as the final key.
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")
source(file.path(base_dir, "scripts/_legacy_identifier_hash.R"))
sql_path <- function(path) gsub("'", "''", normalizePath(path, winslash = "/"))

campus_source <- sql_path(file.path(base_dir, "workflow/unist19_source/wifi_clean.parquet"))
campus_public <- sql_path(file.path(base_dir, "workflow/unist19_main/data/wifi_unist19_20sec.parquet"))
district_source <- sql_path(file.path(base_dir, "workflow/uou20/data/wifi_uou20_1sec.csv"))
district_sensors <- sql_path(file.path(base_dir, "workflow/uou20/output/sensors_coords.csv"))
district_public <- sql_path(file.path(base_dir, "workflow/uou20/data/wifi_uou20_20sec.parquet"))

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

cat("Checking campus projection...\n")
campus_diff <- dbGetQuery(con, sprintf(
  "WITH expected AS (
     SELECT date_trunc('minute', CAST(timestamp AS TIMESTAMP))
              + CAST(floor(date_part('second', CAST(timestamp AS TIMESTAMP)) / 20) AS BIGINT)
                * INTERVAL '20 seconds' AS timestamp,
            source_address, sensor_name,
            CAST(median(rssi) AS DOUBLE) AS rssi_median,
            CAST(sum(rssi) AS BIGINT) AS rssi_sum,
            CAST(count(*) AS BIGINT) AS detections,
            CAST(sum(100 + rssi) AS BIGINT) AS strength_sum
     FROM read_parquet('%s')
     GROUP BY 1, 2, 3
   ), public AS (SELECT * FROM read_parquet('%s'))
   SELECT
     (SELECT count(*) FROM (SELECT * FROM expected EXCEPT ALL SELECT * FROM public))
       AS source_minus_public,
     (SELECT count(*) FROM (SELECT * FROM public EXCEPT ALL SELECT * FROM expected))
       AS public_minus_source",
  campus_source, campus_public
))

cat("Rebuilding commercial-district sensor windows from the internal 1-second source...\n")
dbExecute(con, sprintf(
  "CREATE TEMP TABLE district_expected AS
   WITH sensor_map AS (
     SELECT id_last, id_sensor
     FROM read_csv_auto('%s', header = true)
   ), valid AS (
     SELECT CAST(w.timestamp_wifi AS TIMESTAMP) AS timestamp_1sec,
            w.source_address, s.id_sensor AS sensor_name,
            CAST(w.RSSI AS BIGINT) AS rssi
     FROM read_csv_auto('%s', header = true) AS w
     INNER JOIN sensor_map AS s ON w.sensor_name = s.id_last
     WHERE CAST(w.RSSI AS BIGINT) > -100 AND CAST(w.RSSI AS BIGINT) < 0
   ), windowed AS (
     SELECT date_trunc('minute', timestamp_1sec)
              + CAST(floor(date_part('second', timestamp_1sec) / 20) AS BIGINT)
                * INTERVAL '20 seconds' AS timestamp,
            source_address, sensor_name, rssi
     FROM valid
   )
   SELECT timestamp,
          substr(sha256(lower(trim(source_address))), 1, %d) AS source_address,
          sensor_name,
          CAST(median(rssi) AS DOUBLE) AS rssi_median,
          CAST(sum(rssi) AS BIGINT) AS rssi_sum,
          CAST(count(*) AS BIGINT) AS detections,
          CAST(sum(100 + rssi) AS BIGINT) AS strength_sum
   FROM windowed
   GROUP BY timestamp, source_address, sensor_name",
  district_sensors, district_source, LEGACY_IDENTIFIER_HASH_HEX_LENGTH
))

district_diff <- dbGetQuery(con, sprintf(
  "WITH public AS (SELECT * FROM read_parquet('%s'))
   SELECT
     (SELECT count(*) FROM (
        SELECT * FROM district_expected EXCEPT ALL SELECT * FROM public
      )) AS source_minus_public,
     (SELECT count(*) FROM (
        SELECT * FROM public EXCEPT ALL SELECT * FROM district_expected
      )) AS public_minus_source",
  district_public
))

location_check <- dbGetQuery(con, sprintf(
  "WITH expected_ranked AS (
     SELECT source_address, timestamp, sensor_name, strength_sum,
            row_number() OVER (
              PARTITION BY source_address, timestamp
              ORDER BY strength_sum DESC, sensor_name ASC
            ) AS rn,
            count(*) FILTER (
              WHERE strength_sum = max_strength
            ) OVER (PARTITION BY source_address, timestamp) AS n_at_max
     FROM (
       SELECT *, max(strength_sum) OVER (
         PARTITION BY source_address, timestamp
       ) AS max_strength
       FROM district_expected
     )
   ), public_ranked AS (
     SELECT source_address, timestamp, sensor_name,
            row_number() OVER (
              PARTITION BY source_address, timestamp
              ORDER BY strength_sum DESC, sensor_name ASC
            ) AS rn
     FROM read_parquet('%s')
   ), expected_location AS (
     SELECT source_address, timestamp, sensor_name, n_at_max
     FROM expected_ranked WHERE rn = 1
   ), public_location AS (
     SELECT source_address, timestamp, sensor_name
     FROM public_ranked WHERE rn = 1
   )
   SELECT
     count(*) FILTER (
       WHERE e.source_address IS NULL OR p.source_address IS NULL
          OR e.sensor_name != p.sensor_name
     ) AS location_mismatches,
     count(*) FILTER (WHERE e.n_at_max > 1) AS tied_device_windows,
     count(*) AS total_device_windows
   FROM expected_location e
   FULL OUTER JOIN public_location p
     USING (source_address, timestamp)",
  district_public
))

identifier_check <- dbGetQuery(con, sprintf(
  "SELECT 'UNIST campus' AS site,
          count(*) FILTER (
            WHERE NOT regexp_full_match(
              lower(source_address), '[0-9a-f]{%d}'
            )
          ) AS nonhashed_rows
   FROM read_parquet('%s')
   UNION ALL
   SELECT 'Commercial district' AS site,
          count(*) FILTER (
            WHERE NOT regexp_full_match(
              lower(source_address), '[0-9a-f]{%d}'
            )
          ) AS nonhashed_rows
   FROM read_parquet('%s')",
  LEGACY_IDENTIFIER_HASH_HEX_LENGTH, campus_public,
  LEGACY_IDENTIFIER_HASH_HEX_LENGTH, district_public
))

collision_check <- dbGetQuery(con, sprintf(
  "WITH campus_source_count AS (
     SELECT count(DISTINCT source_address) AS n FROM read_parquet('%s')
   ), campus_public_count AS (
     SELECT count(DISTINCT source_address) AS n FROM read_parquet('%s')
   ), sensor_map AS (
     SELECT id_last FROM read_csv_auto('%s', header = true)
   ), district_source_count AS (
     SELECT count(DISTINCT w.source_address) AS n
     FROM read_csv_auto('%s', header = true) AS w
     INNER JOIN sensor_map AS s ON w.sensor_name = s.id_last
     WHERE CAST(w.RSSI AS BIGINT) > -100 AND CAST(w.RSSI AS BIGINT) < 0
   ), district_public_count AS (
     SELECT count(DISTINCT source_address) AS n
     FROM read_parquet('%s')
   )
   SELECT 'UNIST campus' AS site,
          campus_source_count.n AS source_devices,
          campus_public_count.n AS public_devices,
          campus_source_count.n - campus_public_count.n AS hash_collisions
   FROM campus_source_count, campus_public_count
   UNION ALL
   SELECT 'Commercial district' AS site,
          district_source_count.n AS source_devices,
          district_public_count.n AS public_devices,
          district_source_count.n - district_public_count.n AS hash_collisions
   FROM district_source_count, district_public_count",
  campus_source, campus_public,
  district_sensors, district_source, district_public
))

results <- rbind(
  data.frame(check = "campus_sensor_windows", campus_diff),
  data.frame(check = "district_sensor_windows", district_diff)
)
print(results, row.names = FALSE)
print(location_check, row.names = FALSE)
print(identifier_check, row.names = FALSE)
print(collision_check, row.names = FALSE)

failed <- any(results$source_minus_public != 0) ||
  any(results$public_minus_source != 0) ||
  location_check$location_mismatches != 0 ||
  any(identifier_check$nonhashed_rows != 0) ||
  any(collision_check$hash_collisions != 0)
if (failed) stop("Standardized-data verification failed")

cat("\nAll standardized-data checks passed.\n")
