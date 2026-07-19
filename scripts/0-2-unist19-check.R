# 0-2-unist19-check.R ==========================================================
# Sensor availability check (daily + 4-hour bins)
# Input:  workflow/unist19_source/<sensor>/<file>.parquet
# Output: workflow/unist19_main/output/check_sensor_*.csv
# ==============================================================================

# Setup ----

## Load Packages ----
pacman::p_load(tidyverse, lubridate, arrow)

## Define Paths ----
base_dir <- normalizePath(file.path(dirname(
  rstudioapi::getSourceEditorContext()$path), ".."), winslash = "/")
raw_dir  <- file.path(base_dir, "workflow/unist19_source")
out_dir  <- file.path(base_dir, "workflow/unist19_main/output")

# Check Availability ----

ds <- open_dataset(raw_dir, format = "parquet")

## Daily Summary ----
sensor_daily <- ds |>
  mutate(date = as_date(timestamp)) |>
  count(sensor_name, date) |>
  rename(detections = n) |>
  arrange(sensor_name, date) |>
  collect()

cat("Sensors:", n_distinct(sensor_daily$sensor_name),
    "| Days:", n_distinct(sensor_daily$date),
    "| Period:", as.character(min(sensor_daily$date)),
    "~", as.character(max(sensor_daily$date)), "\n")

## 4-Hour Bins ----
sensor_4h <- ds |>
  mutate(hour_bin = floor_date(timestamp, "4 hours")) |>
  count(sensor_name, hour_bin) |>
  rename(detections = n) |>
  arrange(sensor_name, hour_bin) |>
  collect()

cat("Time bins:", n_distinct(sensor_4h$hour_bin), "\n")

## Sensor Summary ----
sensor_summary <- sensor_daily |>
  group_by(sensor_name) |>
  summarise(
    days_active = n(),
    first_date  = min(date),
    last_date   = max(date),
    total_detections = sum(detections),
    avg_daily   = round(mean(detections)),
    .groups = "drop"
  ) |>
  arrange(first_date, sensor_name)

# Save Results ----

write_csv(sensor_4h,      file.path(out_dir, "check_sensor_4h.csv"))
write_csv(sensor_daily,    file.path(out_dir, "check_sensor_daily.csv"))
write_csv(sensor_summary,  file.path(out_dir, "check_sensor_summary.csv"))

cat("\nSaved: check_sensor_4h.csv, check_sensor_daily.csv, check_sensor_summary.csv\n\n")
print(sensor_summary, n = 30)
