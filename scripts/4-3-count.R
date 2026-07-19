# =============================================================================
# 4-3-count.R: WiFi Counting Analysis - UNIST Campus
# =============================================================================
#
# This script generates counting visualizations from WiFi detection data.
#
# Input (from workflow/unist19_main/data/):
#   - wifi.parquet: 1-week WiFi sample (Oct 28 - Nov 3, 2019), public release
#   - sensors.gpkg: outdoor sensor locations
#   - poi.gpkg: campus points of interest
#
# Output:
#   workflow/unist19_main/output/:
#     - count_hourly_pattern.csv: Average hourly counts by day type
#     - count_weekday_weekend.png: Hourly pattern by day type
#     - count_calendar.png: Daily calendar view (26 days)
#     - count_sensor_map_detailed.png: Spatial distribution
#   docs/materials/ch4/:
#     - count_weekday_weekend.png (copy)
#     - count_calendar.png (copy)
#     - count_sensor_map_detailed.png (copy)
#
# =============================================================================

# Setup ----

pacman::p_load(tidyverse, lubridate, arrow, sf, ggmap, ggrepel)

# Paths
script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

data_dir <- file.path(base_dir, "workflow/unist19_main/data/sample_main")
out_dir  <- file.path(base_dir, "workflow/unist19_main/output")
fig_dir  <- file.path(base_dir, "docs/materials/ch4")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

# Google Maps API (optional)
api_key_file <- file.path(base_dir, ".google_api_key")
if (file.exists(api_key_file)) {
  google_api_key <- readLines(api_key_file, warn = FALSE)
  register_google(key = google_api_key)
}

# Load Data ----

cat("Loading WiFi data...\n")
wifi_raw <- read_parquet(file.path(data_dir, "wifi.parquet")) |>
  # Stored in UTC as in the release; convert once so calendar variables are local
  mutate(timestamp = with_tz(timestamp, "Asia/Seoul"))

cat("  Rows:", format(nrow(wifi_raw), big.mark = ","), "\n")
cat("  Period:", as.character(min(wifi_raw$timestamp)), "to",
    as.character(max(wifi_raw$timestamp)), "\n")
cat("  Retained identifiers:",
    format(n_distinct(wifi_raw$source_address), big.mark = ","), "\n")

cat("\nLoading sensors...\n")
sensors <- st_read(file.path(data_dir, "sensors.gpkg"), quiet = TRUE)
cat("  Sensors:", nrow(sensors), "\n")

cat("\nLoading POI...\n")
poi <- st_read(file.path(data_dir, "poi.gpkg"), quiet = TRUE) |>
  mutate(name_wrap = str_wrap(name, width = 5))

# Analysis ----

cat("\nRunning counting analysis...\n")

## Hourly Pattern ----

# Hourly counts (전체 센서 합계)
hourly_counts <- wifi_raw |>
  mutate(
    hour = floor_date(timestamp, "hour"),
    day_type = if_else(wday(timestamp) %in% c(1, 7), "Weekend", "Weekday")
  ) |>
  group_by(hour, day_type) |>
  summarise(n_devices = n_distinct(source_address), .groups = "drop")

# Average pattern by hour of day
hourly_pattern <- hourly_counts |>
  mutate(hour_of_day = hour(hour)) |>
  group_by(hour_of_day, day_type) |>
  summarise(
    mean_devices = mean(n_devices),
    sd_devices = sd(n_devices),
    .groups = "drop"
  )

## Figure 1: Weekday vs Weekend ----

cat("  Generating Figure 1: Weekday vs Weekend...\n")

p1 <- ggplot(hourly_pattern, aes(x = hour_of_day, y = mean_devices,
                                  color = day_type, fill = day_type)) +
  geom_ribbon(aes(ymin = pmax(0, mean_devices - sd_devices),
                  ymax = mean_devices + sd_devices),
              alpha = 0.2, color = NA) +
  geom_line(linewidth = 1) +
  geom_point(size = 2) +
  scale_x_continuous(breaks = seq(0, 23, by = 3)) +
  scale_color_manual(values = c("Weekday" = "#2c7bb6", "Weekend" = "#d7191c")) +
  scale_fill_manual(values = c("Weekday" = "#2c7bb6", "Weekend" = "#d7191c")) +
  labs(x = "Hour of Day", y = "Unique Retained Identifiers",
       color = NULL, fill = NULL) +
  theme_bw() +
  theme(
    legend.position = c(0.02, 0.98),
    legend.justification = c(0, 1),
    legend.background = element_blank(),
    panel.grid.minor = element_blank()
  )

ggsave(file.path(out_dir, "count_weekday_weekend.png"),
       p1, width = 6, height = 4, dpi = 300, bg = "white")

## Figure 2: Calendar View ----

cat("  Generating Figure 2: Calendar view...\n")

daily_hourly <- wifi_raw |>
  mutate(
    date = as_date(timestamp),
    hour_of_day = hour(timestamp)
  ) |>
  group_by(date, hour_of_day) |>
  summarise(n_devices = n_distinct(source_address), .groups = "drop")

p2 <- ggplot(daily_hourly, aes(x = hour_of_day, y = n_devices)) +
  geom_line(linewidth = 0.5) +
  facet_wrap(~ date, ncol = 7, scales = "free_y") +
  scale_x_continuous(breaks = c(0, 12)) +
  labs(x = "Hour", y = "Retained identifiers") +
  theme_minimal() +
  theme(
    strip.text = element_text(size = 7),
    axis.text = element_text(size = 6),
    panel.grid.minor = element_blank()
  )

ggsave(file.path(out_dir, "count_calendar.png"),
       p2, width = 10, height = 6, dpi = 300, bg = "white")

## Figure 3: Sensor Map ----

cat("  Generating Figure 3: Sensor map...\n")

# Count by sensor and day type - Midday only (11-14)
sensor_counts_midday <- wifi_raw |>
  mutate(
    day_type = if_else(wday(timestamp) %in% c(1, 7), "Weekend", "Weekday"),
    hour_of_day = hour(timestamp)
  ) |>
  filter(hour_of_day >= 11 & hour_of_day <= 14) |>
  group_by(sensor_name, day_type) |>
  summarise(n_devices = n_distinct(source_address), .groups = "drop")

# Join with sensor geometry
sensors_midday <- sensors |>
  left_join(sensor_counts_midday, by = "sensor_name") |>
  filter(!is.na(n_devices))

# Get bounding box for map
bbox <- st_bbox(sensors_midday)
pad <- 0.002
center_lon <- (bbox["xmin"] + bbox["xmax"]) / 2
center_lat <- (bbox["ymin"] + bbox["ymax"]) / 2

# Get Google basemap
base_map <- get_map(
  location = c(lon = center_lon, lat = center_lat),
  zoom = 16, maptype = "satellite", source = "google",
  color = "bw"
)

# Create plot
p3 <- ggmap(base_map, darken = c(0.3, "white")) +
  geom_sf(data = sensors_midday, aes(size = n_devices),
          color = "#d7191c", alpha = 0.85, inherit.aes = FALSE) +
  geom_text_repel(
    data = poi |> mutate(lon = st_coordinates(poi)[, 1], lat = st_coordinates(poi)[, 2]),
    aes(x = lon, y = lat, label = name_wrap),
    size = 2, fontface = "bold.italic", color = "gray10",
    bg.color = "white", bg.r = 0.15,
    lineheight = 0.85,
    box.padding = 0.4, point.padding = 0.2,
    segment.color = "gray80", segment.size = 0.2,
    min.segment.length = 0,
    alpha = 0.8,
    max.overlaps = 20, inherit.aes = FALSE
  ) +
  scale_size_continuous(range = c(1, 8), name = "Retained\nidentifiers") +
  facet_wrap(~ day_type, ncol = 2) +
  coord_sf(
    crs = 4326,
    xlim = c(bbox["xmin"] - pad, bbox["xmax"] + pad),
    ylim = c(bbox["ymin"] - pad, bbox["ymax"] + pad)
  ) +
  theme_bw() +
  theme(
    legend.position = "bottom",
    axis.title = element_blank(),
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    strip.text = element_text(size = 11, face = "bold"),
    strip.background = element_rect(fill = "gray90", color = NA),
    panel.spacing = unit(0.5, "lines")
  )

ggsave(file.path(out_dir, "count_sensor_map_detailed.png"),
       p3, width = 6, height = 5, dpi = 300)

# Save CSV ----

write_csv(hourly_pattern, file.path(out_dir, "count_hourly_pattern.csv"))

# Copy figures to docs ----

for (f in c("count_weekday_weekend.png", "count_calendar.png", "count_sensor_map_detailed.png")) {
  file.copy(file.path(out_dir, f), file.path(fig_dir, f), overwrite = TRUE)
}

# Summary ----

cat("\n=== Count Analysis Summary ===\n")
data_dates <- as_date(wifi_raw$timestamp)
cat("Data period:", as.character(min(data_dates)), "to", as.character(max(data_dates)),
    paste0(" (", n_distinct(data_dates), " days)\n"))
cat("Total observations:", format(nrow(wifi_raw), big.mark = ","), "\n")
cat("Unique retained identifiers:",
    format(n_distinct(wifi_raw$source_address), big.mark = ","), "\n")

cat("\nPeak hours:\n")
hourly_pattern |>
  group_by(day_type) |>
  summarise(
    peak_hour = hour_of_day[which.max(mean_devices)],
    peak_devices = round(max(mean_devices))
  ) |>
  print()

cat("\nSaved to:", out_dir, "\n")
cat("Copied to:", fig_dir, "\n")
