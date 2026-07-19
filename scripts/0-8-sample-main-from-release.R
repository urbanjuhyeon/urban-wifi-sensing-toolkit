# =============================================================================
# Derive the one-week campus tutorial sample from the public release
#
# The tutorial sample is a pure filter of the released campus dataset:
# the local calendar week 2019-10-28 through 2019-11-03 (Asia/Seoul).
# Pseudonyms, schema, and values are identical to the release, so anything
# observed in the sample can be followed into the full data.
#
# Input:  data/release-20sec/wifi_unist19_20sec.parquet
# Output: workflow/unist19_main/data/sample_main/wifi.parquet
#         docs/downloads/sample_main.zip (wifi.parquet + sensors.gpkg + poi.gpkg)
# =============================================================================

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(zip)
})

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

release_path <- file.path(base_dir, "data/release-20sec/wifi_unist19_20sec.parquet")
sample_dir   <- file.path(base_dir, "workflow/unist19_main/data/sample_main")
zip_path     <- file.path(base_dir, "docs/downloads/sample_main.zip")

window <- as.POSIXct(c("2019-10-28 00:00:00", "2019-11-04 00:00:00"),
                     tz = "Asia/Seoul")
# Same instants, displayed in UTC so comparisons against the stored
# UTC timestamps carry a consistent tzone attribute
attr(window, "tzone") <- "UTC"

release <- read_parquet(release_path)
sample <- release |>
  filter(timestamp >= window[1], timestamp < window[2]) |>
  arrange(timestamp, source_address, sensor_name)

expected_cols <- c("timestamp", "source_address", "sensor_name",
                   "rssi_median", "rssi_sum", "detections")
stopifnot(
  identical(names(sample), expected_cols),
  nrow(sample) > 0,
  min(sample$timestamp) >= window[1],
  max(sample$timestamp) < window[2],
  n_distinct(sample$sensor_name) == 24
)

write_parquet(sample, file.path(sample_dir, "wifi.parquet"),
              compression = "zstd")

old_wd <- setwd(sample_dir)
zip::zip(zip_path, files = c("poi.gpkg", "sensors.gpkg", "wifi.parquet"),
         mode = "cherry-pick")
setwd(old_wd)

cat("Sample rows:", format(nrow(sample), big.mark = ","),
    "| unique addresses:", n_distinct(sample$source_address),
    "| sensors:", n_distinct(sample$sensor_name), "\n")
cat("Wrote", file.path(sample_dir, "wifi.parquet"), "\n")
cat("Wrote", zip_path, "\n")
