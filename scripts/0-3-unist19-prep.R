# 0-3-unist19-prep.R ============================================================
# Combine parquets → clean → hash → aggregate
# Input:  workflow/unist19_source/<sensor>/<file>.parquet
# Output: workflow/unist19_source/wifi_clean.parquet  (cleaned, hashed, 1-sec)
#         workflow/unist19_main/data/wifi.parquet      (20-sec aggregated)
#         workflow/unist19_main/data/sensors.gpkg      (filtered)
# ==============================================================================

# Setup ----

## Load Packages ----
pacman::p_load(tidyverse, data.table, arrow, digest, DBI, duckdb, sf)

## Define Paths ----
script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")
source(file.path(base_dir, "scripts/_legacy_identifier_hash.R"))
source(file.path(base_dir, "scripts/_parquet_time.R"))
raw_dir  <- file.path(base_dir, "workflow/unist19_source")
src_dir  <- file.path(base_dir, "workflow/unist19_source")
out_dir  <- file.path(base_dir, "workflow/unist19_main/data")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

## Set Parameters ----
# 0-2-unist19-check 결과 기반
exclude_sensors  <- c("206_front", "comm_center")
session_gap      <- 300     # 5 min: gap to start new session
session_thresh   <- 7200    # 2 hours: flag as stationary
min_detections   <- 5       # minimum detections to keep

# Load Data ----

## Open Dataset ----
ds <- open_dataset(
  list.files(list.dirs(raw_dir, recursive = FALSE), pattern = "\\.parquet$", full.names = TRUE),
  format = "parquet"
)

all_sensors <- ds |> distinct(sensor_name) |> collect() |> pull(sensor_name) |> sort()
analysis_sensors <- setdiff(all_sensors, exclude_sensors)
cat("Sensors:", length(all_sensors), "→", length(analysis_sensors),
    "(excluded:", paste(exclude_sensors, collapse = ", "), ")\n")

## Collect Filtered ----
t0 <- Sys.time()

wifi <- as.data.table(
  ds |>
    filter(!(sensor_name %in% exclude_sensors)) |>
    select(timestamp, source_address, sensor_name, rssi, n) |>
    collect()
)

cat("Loaded:", format(nrow(wifi), big.mark = ","), "rows |",
    format(uniqueN(wifi$source_address), big.mark = ","), "devices\n\n")

# Clean Data ----

## Remove Invalid Rows ----
# All-zero source addresses are capture placeholders, not devices, and
# out-of-range RSSI values are capture sentinels; both would otherwise pass
# the filters below.
addr <- unique(wifi$source_address)
bad_addr <- addr[!grepl("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", tolower(addr)) |
                   tolower(addr) %chin%
                     c("00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff")]
n0 <- nrow(wifi)
wifi <- wifi[!source_address %chin% bad_addr][rssi > -100 & rssi < 0]
cat("Filter 0 (invalid address/RSSI):",
    format(n0 - nrow(wifi), big.mark = ","), "rows |",
    length(bad_addr), "addresses removed\n")

n_initial <- nrow(wifi)
d_initial <- uniqueN(wifi$source_address)

## Remove Random MACs ----
# Second hex character: 2,3,6,7,a,b,e,f → locally administered (randomized)
wifi <- wifi[!substr(tolower(source_address), 2, 2) %chin%
               c("2", "3", "6", "7", "a", "b", "e", "f")]

n_after_f1 <- nrow(wifi)
d_after_f1 <- uniqueN(wifi$source_address)
cat("Filter 1 (random MAC):",
    format(d_initial, big.mark = ","), "→", format(d_after_f1, big.mark = ","), "devices |",
    format(n_initial, big.mark = ","), "→", format(n_after_f1, big.mark = ","), "rows\n")

## Remove Stationary ----
# Session: continuous detection with gaps < 5 min
# Device with any session > 2 hours → stationary (AP, desktop, IoT)
setkey(wifi, source_address, sensor_name, timestamp)

wifi[, gap := as.numeric(difftime(timestamp, shift(timestamp), units = "secs")),
     by = .(source_address, sensor_name)]
wifi[, session_id := cumsum(is.na(gap) | gap > session_gap),
     by = .(source_address, sensor_name)]

stationary_devices <- wifi[
  , .(session_dur = as.numeric(difftime(max(timestamp), min(timestamp), units = "secs"))),
  by = .(source_address, sensor_name, session_id)
][session_dur >= session_thresh, unique(source_address)]

wifi[, c("gap", "session_id") := NULL]
wifi <- wifi[!source_address %chin% stationary_devices]

n_after_f2 <- nrow(wifi)
d_after_f2 <- uniqueN(wifi$source_address)
cat("Filter 2 (stationary):",
    format(d_after_f1, big.mark = ","), "→", format(d_after_f2, big.mark = ","), "devices |",
    format(n_after_f1, big.mark = ","), "→", format(n_after_f2, big.mark = ","), "rows\n")

## Remove Rare ----
# Devices with fewer than 5 total detections
device_counts <- wifi[, .N, by = source_address]
rare_devices <- device_counts[N < min_detections, source_address]
wifi <- wifi[!source_address %chin% rare_devices]

n_after_f3 <- nrow(wifi)
d_after_f3 <- uniqueN(wifi$source_address)
cat("Filter 3 (rare <", min_detections, "):",
    format(d_after_f2, big.mark = ","), "→", format(d_after_f3, big.mark = ","), "devices |",
    format(n_after_f2, big.mark = ","), "→", format(n_after_f3, big.mark = ","), "rows\n\n")

# Hash MACs ----

unique_macs <- unique(wifi$source_address)
cat("Hashing", format(length(unique_macs), big.mark = ","), "MACs...\n")

hashed_macs <- legacy_hash_identifier(unique_macs)
assert_no_legacy_identifier_hash_collisions(unique_macs, hashed_macs)
hash_lookup <- setNames(hashed_macs, unique_macs)
wifi[, source_address := hash_lookup[source_address]]

cat("Unique hashed:", format(uniqueN(wifi$source_address), big.mark = ","), "\n\n")

# Save Output ----

## WiFi Clean 1-sec ----
setorder(wifi, timestamp, source_address)
wifi <- wifi[, .(timestamp, source_address, sensor_name, rssi, n)]

clean_path <- file.path(src_dir, "wifi_clean.parquet")
write_parquet(wifi, clean_path, write_statistics = FALSE)

cat("Saved:", clean_path,
    sprintf("(%.1f MB)\n", file.info(clean_path)$size / 1024^2))

## WiFi 20-sec ----
parquet_path <- file.path(out_dir, "wifi.parquet")
sample_path <- file.path(out_dir, "wifi_sample.parquet")
final_period <- range(wifi$timestamp)
final_sensors <- uniqueN(wifi$sensor_name)
rm(wifi)
invisible(gc())

sql_path <- function(path) gsub("'", "''", normalizePath(path, winslash = "/", mustWork = FALSE))
for (path in c(parquet_path, sample_path)) if (file.exists(path)) unlink(path)

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
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
  sql_path(clean_path), sql_path(parquet_path)
))
attach_utc_timestamp_metadata(parquet_path)

parquet_stats <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n_rows FROM read_parquet('%s')", sql_path(parquet_path)
))

cat("Saved:", parquet_path,
    sprintf("(%.1f MB | %s rows)\n",
            file.info(parquet_path)$size / 1024^2,
            format(parquet_stats$n_rows, big.mark = ",")))

## WiFi 1-week sample (for GitHub) ----
dbExecute(con, sprintf(
  "COPY (
     SELECT * FROM read_parquet('%s')
     WHERE timestamp >= TIMESTAMP '2019-10-28 00:00:00'
       AND timestamp <  TIMESTAMP '2019-11-04 00:00:00'
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  sql_path(parquet_path), sql_path(sample_path)
))
attach_utc_timestamp_metadata(sample_path)

sample_stats <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n_rows, count(DISTINCT source_address) AS n_devices
   FROM read_parquet('%s')", sql_path(sample_path)
))

cat("Saved:", sample_path,
    sprintf("(%.1f MB | %s rows | %s devices)\n",
            file.info(sample_path)$size / 1024^2,
            format(sample_stats$n_rows, big.mark = ","),
            format(sample_stats$n_devices, big.mark = ",")))

## Sensors GeoPackage ----
sensors_path <- file.path(out_dir, "sensors.gpkg")
if (file.exists(sensors_path)) {
  sensors <- st_read(sensors_path, quiet = TRUE)
  n_before <- nrow(sensors)
  sensors <- sensors[sensors$sensor_name %in% analysis_sensors, ]
  st_write(sensors, sensors_path, delete_dsn = TRUE, quiet = TRUE)
  cat("Sensors:", n_before, "→", nrow(sensors), "\n")
}

# Print Summary ----

cat("\n=== Preprocessing Summary ===\n")
cat(sprintf("%-25s %12s %12s\n", "Step", "Devices", "Rows"))
cat(sprintf("%-25s %12s %12s\n", "Initial",
            format(d_initial, big.mark = ","), format(n_initial, big.mark = ",")))
cat(sprintf("%-25s %12s %12s\n", "After random MAC",
            format(d_after_f1, big.mark = ","), format(n_after_f1, big.mark = ",")))
cat(sprintf("%-25s %12s %12s\n", "After stationary",
            format(d_after_f2, big.mark = ","), format(n_after_f2, big.mark = ",")))
cat(sprintf("%-25s %12s %12s\n", "After rare removal",
            format(d_after_f3, big.mark = ","), format(n_after_f3, big.mark = ",")))
cat("\nPeriod:", as.character(final_period[1]), "~", as.character(final_period[2]), "\n")
cat("Sensors:", final_sensors, "\n")
cat("Total:", round(difftime(Sys.time(), t0, units = "mins"), 1), "min\n")
