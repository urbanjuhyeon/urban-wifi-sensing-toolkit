# =============================================================================
# 4-2-location.R: WiFi Localization Analysis - UNIST Campus
# =============================================================================
#
# This script runs localization analysis on the full dataset and generates
# a validation plot comparing three methods.
#
# Three localization methods compared:
# - Proximity: assign to sensor with the largest cumulative strength,
#   sum(100 + RSSI) over the window (rewards frequent and strong detections)
# - Centroid: simple average of detecting sensor coordinates
# - Weighted Centroid: weighted average using (100 + RSSI) as weight
#
# Windows are tumbling floor_date windows, matching the production pipeline
# (0-3-unist19-prep.R, 9-2-figure3.R), and the validation runs on the same
# 24-sensor analysis network as the main pipeline.
#
# Input (from workflow/unist19_loc/data/):
#   - wifi_all.parquet: WiFi with RSSI (all GPS-labeled devices)
#   - gps_all.csv: GPS ground truth
#   - sensors.gpkg: sensor locations (outdoor)
#
# Output:
#   workflow/unist19_loc/output/:
#     - localization_error.csv: Summary statistics
#     - localization_error.png: Median error by sampling time
#   docs/materials/ch4/:
#     - localization_error.png (copy)
#
# =============================================================================

# Setup ----

pacman::p_load(data.table, arrow, sf, ggplot2, lubridate)

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

data_dir <- file.path(base_dir, "workflow/unist19_loc/data")
out_dir  <- file.path(base_dir, "workflow/unist19_loc/output")
fig_dir  <- file.path(base_dir, "docs/materials/ch4")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

sampling_times <- c(1, 5, seq(10, 120, by = 10))

# Same 24-sensor analysis network as 0-3-unist19-prep.R
exclude_sensors <- c("206_front", "comm_center")

# Load Data ----

cat("Loading data...\n")

## WiFi and GPS ----

wifi_dt <- as.data.table(read_parquet(file.path(data_dir, "wifi_all.parquet")))

gps_dt <- fread(file.path(data_dir, "gps_all.csv"))[
  , timestamp := as.POSIXct(timestamp, tz = "UTC")
]

## Sensors ----

sensor_sf <- st_read(file.path(data_dir, "sensors.gpkg"), quiet = TRUE)
sensor_sf$x_sensor <- st_coordinates(sensor_sf)[, 1]
sensor_sf$y_sensor <- st_coordinates(sensor_sf)[, 2]
sensor_dt <- as.data.table(st_drop_geometry(sensor_sf))[
  !sensor_name %in% exclude_sensors,
  .(sensor_name, x_sensor, y_sensor)
]

cat("WiFi records:", format(nrow(wifi_dt), big.mark = ","), "\n")
cat("GPS records:", format(nrow(gps_dt), big.mark = ","), "\n")
cat("Sensors:", nrow(sensor_dt), "\n")

# Localization Analysis ----

cat("\nRunning localization analysis...\n")

## Prepare Data ----

wifi_dt <- wifi_dt[sensor_dt, on = "sensor_name", nomatch = NULL]

# Guard against capture sentinels (e.g. RSSI = -255): keep plausible dBm only
n_bad_rssi <- wifi_dt[rssi <= -100 | rssi >= 0, .N]
wifi_dt <- wifi_dt[rssi > -100 & rssi < 0]
cat("Removed", n_bad_rssi, "rows with invalid RSSI |",
    format(nrow(wifi_dt), big.mark = ","), "rows remain\n")

wifi_dt[, strength := 100 + rssi]

gps_dt[, timestamp_temp := timestamp]
setkey(gps_dt, source_address, timestamp_temp)

## Run Methods ----

run_localization <- function(ts) {
  cat("  ts =", ts, "sec\n")

  # Tumbling windows (floor_date), as in the production pipeline;
  # the window midpoint carries the estimate
  wifi_agg <- wifi_dt[
    , .(
      strength_sum = sum(strength),
      x_sensor = first(x_sensor),
      y_sensor = first(y_sensor)
    ),
    by = .(source_address,
           # epoch floor: identical to floor_date() for ts <= 60 (e.g. the
           # production 20-sec windows) and valid for the longer test windows
           window_start = as.POSIXct(floor(as.numeric(timestamp) / ts) * ts,
                                     origin = "1970-01-01", tz = "UTC"),
           sensor_name)
  ]
  wifi_agg[, timestamp_step := window_start + ts / 2]

  # Method 1: Proximity (strongest cumulative strength, sum(100 + RSSI))
  prox <- wifi_agg[
    order(source_address, timestamp_step, -strength_sum)
  ][
    , head(.SD, 1), by = .(source_address, timestamp_step)
  ][
    , .(source_address, timestamp_step,
        x_est = x_sensor, y_est = y_sensor,
        method = "Proximity")
  ]

  # Method 2: Centroid
  cent <- wifi_agg[
    , .(x_est = mean(x_sensor), y_est = mean(y_sensor)),
    by = .(source_address, timestamp_step)
  ][, method := "Centroid"]

  # Method 3: Weighted Centroid
  wcent <- wifi_agg[
    , .(
      x_est = sum(x_sensor * strength_sum) / sum(strength_sum),
      y_est = sum(y_sensor * strength_sum) / sum(strength_sum)
    ),
    by = .(source_address, timestamp_step)
  ][, method := "Wcentroid"]

  # Combine and join with GPS
  all_methods <- rbindlist(list(prox, cent, wcent), use.names = TRUE)
  all_methods[, timestamp_temp := timestamp_step]
  setkey(all_methods, source_address, timestamp_temp)

  result <- gps_dt[all_methods, roll = "nearest"]
  result <- result[abs(difftime(timestamp, timestamp_step, units = "secs")) <= ts / 2]

  result[, `:=`(
    error = sqrt((x_est - x)^2 + (y_est - y)^2),
    time_sampling = ts
  )]

  result[, .(source_address, timestamp_step, x_est, y_est, method,
             timestamp_GPS = timestamp, x_gps = x, y_gps = y, error, time_sampling)]
}

results <- rbindlist(lapply(sampling_times, run_localization))

cat("Total observations:", format(nrow(results), big.mark = ","), "\n")

# Results ----

## Summary Statistics ----

summary_stats <- results[
  !is.na(error),
  .(
    median_error = median(error),
    mean_error = mean(error),
    q25 = quantile(error, 0.25),
    q75 = quantile(error, 0.75),
    n = .N
  ),
  by = .(method, time_sampling)
][order(method, time_sampling)]

cat("\n========== Summary Statistics ==========\n")
print(summary_stats)

fwrite(summary_stats, file.path(out_dir, "localization_error.csv"))

## Validation Plot ----

n_participants <- wifi_dt[, uniqueN(source_address)]
n_days <- wifi_dt[, uniqueN(as.Date(timestamp))]

method_order <- c("Proximity", "Wcentroid", "Centroid")
summary_stats[, method := factor(method, levels = method_order)]

p <- ggplot(summary_stats, aes(x = time_sampling, y = median_error,
                                color = method, shape = method)) +
  annotate("rect", xmin = 10, xmax = 30, ymin = -Inf, ymax = Inf,
           fill = "gray90", alpha = 0.5) +
  geom_vline(xintercept = 20, linetype = "dashed",
             color = "grey40", linewidth = 0.4) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.5) +
  scale_x_continuous(breaks = c(1, 5, seq(10, 120, by = 10))) +
  coord_cartesian(ylim = c(
    min(summary_stats$median_error) * 0.9,
    max(summary_stats$median_error) * 1.1
  )) +
  scale_color_manual(
    breaks = method_order,
    values = c(Proximity = "black", Wcentroid = "firebrick", Centroid = "steelblue"),
    labels = c("Proximity", "Weighted Centroid", "Centroid")
  ) +
  scale_shape_manual(
    breaks = method_order,
    values = c(Proximity = 16, Wcentroid = 15, Centroid = 17),
    labels = c("Proximity", "Weighted Centroid", "Centroid")
  ) +
  labs(
    title = "Localization Error by Sampling Time",
    subtitle = sprintf("UNIST Campus (%d participants, %d days)", n_participants, n_days),
    x = "Sampling Time (seconds)",
    y = "Median Localization Error (m)",
    color = NULL, shape = NULL
  ) +
  theme_bw() +
  theme(
    legend.position = "top",
    legend.justification = "left",
    legend.margin = margin(t = 0, r = 0, b = -5, l = 0),
    legend.text = element_text(size = 9),
    plot.title = element_text(size = 14, face = "bold"),
    plot.subtitle = element_text(size = 10, color = "gray40")
  )

ggsave(file.path(out_dir, "localization_error.png"),
       p, width = 6.5, height = 4, dpi = 300)

# Copy figures to docs
file.copy(file.path(out_dir, "localization_error.png"),
          file.path(fig_dir, "localization_error.png"), overwrite = TRUE)

# Supplementary figure for manuscript (no title/subtitle, legend at bottom)
p_supp <- p +
  labs(title = NULL, subtitle = NULL) +
  theme(
    legend.position = "bottom",
    legend.justification = "center",
    legend.margin = margin(t = 0, r = 0, b = 0, l = 0)
  )

ms_fig_dir <- file.path(base_dir, "manuscript/figures")
dir.create(ms_fig_dir, recursive = TRUE, showWarnings = FALSE)
ggsave(file.path(ms_fig_dir, "fig_supp_localization.png"),
       p_supp, width = 6.5, height = 4, dpi = 300)

cat("\nSaved to:", out_dir, "\n")
cat("Copied to:", fig_dir, "\n")
cat("Manuscript figure saved to:", ms_fig_dir, "\n")
