# 0-4-unist19-location.R ========================================================
# Extract WiFi + GPS for location validation
# Input:  workflow/unist19_source/<sensor>/*.parquet  (from 0-1)
#         workflow/unist19_source/db_GPS_unist19_ALL.csv (GPS with MAC mapping)
#         workflow/unist19_source/unist_basemap.gpkg     (sensor coordinates)
# Restricted output: workflow/unist19_loc/data/
#           wifi_tutorial_restricted.parquet (single device, release input)
#           wifi_all.parquet                (all GPS devices, validation)
#           gps_tutorial_restricted.csv     (single device, release input)
#           gps_all.csv                     (all GPS devices)
#           sensors.gpkg                    (outdoor sensors)
#
# This historical-preparation script never overwrites the tracked public
# wifi.parquet or gps.csv. Those files are built separately with a 32-character,
# release- and dataset-specific HMAC-SHA-256 pseudonym.
# ==============================================================================

# Setup ----

## Load Packages ----
pacman::p_load(data.table, dplyr, arrow, digest, sf)

## Define Paths ----
script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")
source(file.path(base_dir, "scripts/_legacy_identifier_hash.R"))

raw_dir      <- file.path(base_dir, "workflow/unist19_source")
gps_path     <- file.path(base_dir, "workflow/unist19_source/db_GPS_unist19_ALL.csv")
basemap_path <- file.path(base_dir, "workflow/unist19_source/unist_basemap.gpkg")
loc_dir      <- file.path(base_dir, "workflow/unist19_loc")
out_dir      <- file.path(loc_dir, "data")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
generated_files <- file.path(
  out_dir,
  c("wifi_tutorial_restricted.parquet", "wifi_all.parquet",
    "gps_tutorial_restricted.csv", "gps_all.csv", "sensors.gpkg")
)
for (path in generated_files[file.exists(generated_files)]) unlink(path)

# Load GPS Ground Truth ----

cat("Loading GPS ground truth...\n")
gps_raw <- fread(gps_path, select = c("source_address", "timestamp_GPS", "x", "y"))
gps_macs <- unique(gps_raw$source_address)
cat("  GPS devices:", length(gps_macs), "\n")

# Extract WiFi (all GPS devices) ----

cat("\nExtracting WiFi for all GPS-labeled devices...\n")
ds <- open_dataset(
  list.files(list.dirs(raw_dir, recursive = FALSE), pattern = "\\.parquet$", full.names = TRUE),
  format = "parquet"
)

mac_counts <- as.data.table(
  ds |>
    filter(source_address %in% gps_macs) |>
    count(source_address) |>
    collect()
)
cat("  Devices found in WiFi:", nrow(mac_counts), "of", length(gps_macs), "\n")

wifi_all <- as.data.table(
  ds |>
    filter(source_address %in% mac_counts$source_address) |>
    select(timestamp, source_address, sensor_name, rssi) |>
    collect()
)
setorder(wifi_all, timestamp)
cat("  WiFi rows:", format(nrow(wifi_all), big.mark = ","), "\n")

# Hash MACs ----

cat("\nHashing MAC addresses...\n")
unique_macs <- unique(wifi_all$source_address)
hashed_macs <- legacy_hash_identifier(unique_macs)
assert_no_legacy_identifier_hash_collisions(unique_macs, hashed_macs)
hash_lookup <- setNames(hashed_macs, unique_macs)

wifi_all[, source_address := hash_lookup[source_address]]

gps_all <- gps_raw[
  source_address %in% names(hash_lookup),
  .(source_address = hash_lookup[source_address],
    timestamp = as.POSIXct(timestamp_GPS, tz = "UTC"),
    x, y)
]
setorder(gps_all, timestamp)

cat("  Hashed devices:", length(unique_macs), "\n")

# Select Best Device (for tutorial) ----

mac_counts[, hashed := hash_lookup[source_address]]
target_hash <- mac_counts[order(-n)][1, hashed]

cat("  Tutorial device:", target_hash,
    "(", format(mac_counts[hashed == target_hash, n], big.mark = ","), "detections)\n")

wifi_single <- wifi_all[source_address == target_hash]
gps_single  <- gps_all[source_address == target_hash]

# Sensors ----

cat("\nPreparing sensor coordinates...\n")
sensor_sf <- st_read(basemap_path, layer = "sensors", quiet = TRUE)
sensor_sf <- sensor_sf[sensor_sf$outdoor == 1, ]

# Rename id_last -> sensor_name (consistent with 0-1/0-3)
sensor_sf$sensor_name <- sensor_sf$id_last
sensor_sf <- sensor_sf[, "sensor_name"]

# Add non-outdoor sensors detected by any GPS device
wifi_sensors <- unique(wifi_all$sensor_name)
missing <- setdiff(wifi_sensors, sensor_sf$sensor_name)
if (length(missing) > 0) {
  cat("  Adding non-outdoor sensors:", paste(missing, collapse = ", "), "\n")
  extra <- st_read(basemap_path, layer = "sensors", quiet = TRUE)
  extra <- extra[extra$id_last %in% missing, ]
  extra$sensor_name <- extra$id_last
  extra <- extra[, "sensor_name"]
  sensor_sf <- rbind(sensor_sf, extra)
}

cat("  Sensors:", nrow(sensor_sf), "\n")

# Save Output ----

cat("\nSaving output...\n")

# Restricted tutorial inputs (single device). The public filenames are reserved
# for the downstream release-HMAC build and are deliberately not written here.
write_parquet(
  wifi_single,
  file.path(out_dir, "wifi_tutorial_restricted.parquet"),
  write_statistics = FALSE
)
fwrite(gps_single, file.path(out_dir, "gps_tutorial_restricted.csv"))

# Validation (all GPS devices)
write_parquet(wifi_all, file.path(out_dir, "wifi_all.parquet"), write_statistics = FALSE)
fwrite(gps_all, file.path(out_dir, "gps_all.csv"))

# Sensors
st_write(sensor_sf, file.path(out_dir, "sensors.gpkg"), delete_dsn = TRUE, quiet = TRUE)

cat("  wifi_tutorial_restricted.parquet: ",
    format(nrow(wifi_single), big.mark = ","), "rows",
    sprintf("(%.1f KB)\n",
            file.info(file.path(out_dir, "wifi_tutorial_restricted.parquet"))$size / 1024))
cat("  wifi_all.parquet: ", format(nrow(wifi_all), big.mark = ","), "rows",
    sprintf("(%.1f MB)\n", file.info(file.path(out_dir, "wifi_all.parquet"))$size / 1024^2))
cat("  gps_tutorial_restricted.csv: ",
    format(nrow(gps_single), big.mark = ","), "rows\n")
cat("  gps_all.csv:      ", format(nrow(gps_all), big.mark = ","), "rows\n")
cat("  sensors.gpkg:     ", nrow(sensor_sf), "sensors\n")

# Print Summary ----

cat("\n=== Location Data Summary ===\n")
cat("Tutorial device:", target_hash, "\n")
cat("  WiFi:", format(nrow(wifi_single), big.mark = ","), "detections at",
    uniqueN(wifi_single$sensor_name), "sensors\n")
cat("  GPS: ", format(nrow(gps_single), big.mark = ","), "points\n")
cat("Validation:\n")
cat("  WiFi:", format(nrow(wifi_all), big.mark = ","), "detections,",
    uniqueN(wifi_all$source_address), "devices\n")
cat("  GPS: ", format(nrow(gps_all), big.mark = ","), "points,",
    uniqueN(gps_all$source_address), "devices\n")
