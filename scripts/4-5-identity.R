# =============================================================================
# 4-5-identity.R: Observed-Day Revisit Profile
# =============================================================================
#
# Frequency bands based on the number of deployment days on which an
# identifier was retained in the public tutorial data.
#
# Input:  workflow/unist19_main/data/sample_main/ (wifi.parquet, sensors.gpkg, poi.gpkg)
# Output (workflow/unist19_main/output/):
#   Figures (copied to docs/materials/ch4/):
#     - identity_freq_dist.png: Visit frequency distribution
#     - identity_freq_hourly.png: Hourly detection rates by group
#     - identity_freq_sensor.png: Spatial distribution difference
#     - identity_freq_sensors.png: Spatial coverage violin plot
#     - identity_freq_od.png: Movement corridors by group
#   Data:
#     - identity_freq_dist.csv, identity_freq_hourly.csv
#     - identity_freq_sensor.csv, identity_freq_visit_summary.csv
#     - identity_freq_od.csv
#
# =============================================================================

# Setup ----

pacman::p_load(tidyverse, lubridate, arrow, sf, ggmap, ggrepel)

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

data_dir <- file.path(base_dir, "workflow/unist19_main/data/sample_main")
fig_dir  <- file.path(base_dir, "docs/materials/ch4")
out_dir  <- file.path(base_dir, "workflow/unist19_main/output")

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

## Load Data ----

wifi <- read_parquet(file.path(data_dir, "wifi.parquet")) |>
  # Stored in UTC as in the release; convert once so calendar variables are local
  mutate(
    timestamp = with_tz(timestamp, "Asia/Seoul"),
    date = as_date(timestamp),
    hour = hour(timestamp)
  )

sensors <- st_read(file.path(data_dir, "sensors.gpkg"), quiet = TRUE)
poi <- st_read(file.path(data_dir, "poi.gpkg"), quiet = TRUE)

sensor_coords <- sensors |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(sensors |> st_drop_geometry() |> select(sensor_name))

## Load Basemap ----

api_key_file <- file.path(base_dir, ".google_api_key")
if (file.exists(api_key_file)) {
  register_google(key = readLines(api_key_file, warn = FALSE))
}

bbox <- st_bbox(sensors)
pad <- 0.002
center_lon <- (bbox["xmin"] + bbox["xmax"]) / 2
center_lat <- (bbox["ymin"] + bbox["ymax"]) / 2

base_map <- get_map(
  location = c(lon = center_lon, lat = center_lat),
  zoom = 16, maptype = "satellite", source = "google",
  color = "bw"
)

n_total_days <- n_distinct(wifi$date)
cat("Rows:", format(nrow(wifi), big.mark = ","), "\n")
cat("Retained identifiers:",
    format(n_distinct(wifi$source_address), big.mark = ","), "\n")
cat("Period:", as.character(min(wifi$date)), "to", as.character(max(wifi$date)),
    paste0("(", n_total_days, " days)\n"))


# Parameters ----

high_frequency_threshold <- 5  # days (5+ out of the 7-day deployment)

# Frequency Classification ----

cat("\n=== Frequency Classification ===\n")
cat("High-frequency band starts at:", high_frequency_threshold, "days\n")

## 1. Classify Retained Identifiers ----

identifier_days <- wifi |>
  group_by(source_address) |>
  summarise(n_days = n_distinct(date), .groups = "drop") |>
  mutate(observed_day_band = factor(
    case_when(
      n_days == 1 ~ "1 day",
      n_days >= high_frequency_threshold ~ "5–7 days",
      TRUE ~ "2–4 days"
    ),
    levels = c("1 day", "2–4 days", "5–7 days")
  ))

count(identifier_days, observed_day_band, sort = TRUE) |> print()

wifi <- wifi |>
  left_join(identifier_days |> select(source_address, observed_day_band),
            by = "source_address")

## 2. Visit Distribution ----

dist_data <- count(identifier_days, n_days, observed_day_band)
write_csv(dist_data, file.path(out_dir, "identity_freq_dist.csv"))

# Group-level % labels + bracket ranges
group_pct <- dist_data |>
  group_by(observed_day_band) |>
  summarise(total = sum(n), x_min = min(n_days), x_max = max(n_days),
            x_mid = median(n_days), y_top = max(n), .groups = "drop") |>
  mutate(pct_label = paste0(round(total / sum(total) * 100), "%"))

bracket_groups <- group_pct |> filter(x_min != x_max)
bracket_y <- max(bracket_groups$y_top) * 1.08
label_y   <- bracket_y * 1.06

# Dynamic subtitle
high_band_pct <- group_pct |>
  filter(observed_day_band == "5–7 days") |>
  pull(pct_label)
one_day_pct <- group_pct |>
  filter(observed_day_band == "1 day") |>
  pull(pct_label)

p_dist <- ggplot(dist_data, aes(n_days, n, fill = observed_day_band)) +
  geom_col(width = 0.8) +
  # Single-day band: simple text above its bar
  geom_text(data = group_pct |> filter(x_min == x_max),
            aes(x = x_mid, y = y_top, label = pct_label),
            vjust = -0.5, fontface = "bold", size = 3.8, color = "#d7191c",
            inherit.aes = FALSE) +
  # Multi-day bands: bracket + label
  geom_segment(data = bracket_groups,
               aes(x = x_min, xend = x_max, y = bracket_y, yend = bracket_y,
                   color = observed_day_band),
               linewidth = 0.6, inherit.aes = FALSE, show.legend = FALSE) +
  geom_segment(data = bracket_groups,
               aes(x = x_min, xend = x_min, y = bracket_y * 0.98,
                   yend = bracket_y, color = observed_day_band),
               linewidth = 0.6, inherit.aes = FALSE, show.legend = FALSE) +
  geom_segment(data = bracket_groups,
               aes(x = x_max, xend = x_max, y = bracket_y * 0.98,
                   yend = bracket_y, color = observed_day_band),
               linewidth = 0.6, inherit.aes = FALSE, show.legend = FALSE) +
  geom_label(data = bracket_groups,
             aes(x = x_mid, y = bracket_y, label = pct_label,
                 color = observed_day_band),
             fontface = "bold", size = 3.8, fill = "white", linewidth = 0,
             label.padding = unit(0.15, "lines"),
             inherit.aes = FALSE, show.legend = FALSE) +
  scale_fill_manual(
    values = c("1 day" = "#d7191c", "2–4 days" = "gray55",
               "5–7 days" = "#2c7bb6"),
    name = NULL
  ) +
  scale_color_manual(
    values = c("1 day" = "#d7191c", "2–4 days" = "gray55",
               "5–7 days" = "#2c7bb6")
  ) +
  scale_x_continuous(breaks = seq(1, n_total_days)) +
  scale_y_continuous(labels = scales::comma, expand = expansion(mult = c(0, 0.12))) +
  labs(title = "Distribution of Observed-Day Frequency",
       subtitle = paste0(one_day_pct, " in the 1-day band; ", high_band_pct,
                         " in the 5–7-day band"),
       x = "Days Observed", y = NULL) +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        legend.position = "top", legend.justification = "left",
        legend.margin = margin(1.5, -0.5, 0, 0), legend.box.just = "left",
        legend.key.size = unit(1, "lines"),
        panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "identity_freq_dist.png"), p_dist,
       width = 6, height = 4, dpi = 300, bg = "white")

## 3. Hourly Pattern ----

wifi_freq <- wifi |>
  filter(observed_day_band %in% c("1 day", "5–7 days"))

h_freq <- wifi_freq |>
  group_by(observed_day_band, hour) |>
  summarise(n = n_distinct(source_address), .groups = "drop") |>
  group_by(observed_day_band) |>
  mutate(pct = n / sum(n) * 100)

write_csv(h_freq, file.path(out_dir, "identity_freq_hourly.csv"))

p_fh <- ggplot(h_freq, aes(hour, pct, color = observed_day_band)) +
  geom_line(linewidth = 0.8) + geom_point(size = 1.8) +
  scale_x_continuous(
    breaks = c(0, 4, 8, 12, 16, 20, 23),
    labels = c("0AM", "4", "8", "12PM", "16", "20", "23")
  ) +
  scale_y_continuous(breaks = seq(2, 10, 2)) +
  scale_color_manual(values = c("1 day" = "#d7191c", "5–7 days" = "#2c7bb6"),
                     name = NULL) +
  labs(title = "Within-Band Hourly Distribution",
       subtitle = "Hourly profiles for the two extreme observed-day bands",
       x = NULL, y = "% of identifier-hour incidences") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        legend.position = "top", legend.justification = "left",
        legend.margin = margin(1.5, -0.5, 0, 0), legend.box.just = "left",
        legend.key.size = unit(1, "lines"),
        legend.key = element_rect(fill = NA, color = NA),
        panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "identity_freq_hourly.png"), p_fh,
       width = 6, height = 4, dpi = 300, bg = "white")

## 4. Spatial Distribution ----

# Compute per-sensor % for each group, then difference
s_freq_wide <- wifi_freq |>
  count(observed_day_band, sensor_name) |>
  group_by(observed_day_band) |>
  mutate(pct = n / sum(n) * 100) |>
  ungroup() |>
  select(observed_day_band, sensor_name, pct) |>
  pivot_wider(names_from = observed_day_band, values_from = pct,
              values_fill = 0) |>
  rename(pct_one_day = `1 day`, pct_five_to_seven_days = `5–7 days`) |>
  mutate(diff = pct_one_day - pct_five_to_seven_days,
         abs_diff = abs(diff),
         dominant = if_else(diff > 0, "1 day", "5–7 days")) |>
  left_join(sensor_coords, by = "sensor_name")

write_csv(s_freq_wide |> select(-X, -Y), file.path(out_dir, "identity_freq_sensor.csv"))

# Label sensors with largest differences
top_diff <- s_freq_wide |> slice_max(abs_diff, n = 10)

p_fs <- ggmap(base_map, darken = c(0.3, "white")) +
  geom_point(data = sensor_coords, aes(x = X, y = Y),
             size = 1.2, color = "grey60", inherit.aes = FALSE) +
  geom_point(data = s_freq_wide, aes(x = X, y = Y, size = abs_diff, color = dominant),
             alpha = 0.75, inherit.aes = FALSE) +
  geom_text_repel(
    data = top_diff, aes(x = X, y = Y, label = sensor_name),
    size = 2.2, fontface = "bold.italic", color = "black",
    bg.color = "white", bg.r = 0.12,
    box.padding = 0.35, point.padding = 0.2,
    max.overlaps = 15, seed = 42, inherit.aes = FALSE
  ) +
  scale_size_continuous(range = c(1.5, 10), name = "% point\ndifference") +
  scale_color_manual(values = c("1 day" = "#d7191c", "5–7 days" = "#2c7bb6"),
                     name = "Higher share") +
  coord_sf(crs = 4326,
           xlim = c(bbox["xmin"] - pad, bbox["xmax"] + pad),
           ylim = c(bbox["ymin"] - pad, bbox["ymax"] + pad)) +
  labs(title = "Spatial Distribution",
       subtitle = "Percentage-point differences between observed-day bands") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        legend.position = "right",
        axis.title = element_blank(),
        axis.text = element_blank(),
        axis.ticks = element_blank(),
        panel.grid = element_blank())

ggsave(file.path(out_dir, "identity_freq_sensor.png"), p_fs,
       width = 6, height = 5, dpi = 300, bg = "white")

## 5. Spatial Coverage ----

# Per-visit stats: detections and sensors per visit
identifier_day_stats <- wifi_freq |>
  group_by(source_address, date, observed_day_band) |>
  summarise(
    n_detections = n(),
    n_sensors = n_distinct(sensor_name),
    duration_mins = as.numeric(difftime(max(timestamp), min(timestamp), units = "mins")),
    .groups = "drop"
  )

identifier_day_summary <- identifier_day_stats |>
  group_by(observed_day_band) |>
  summarise(
    n_identifier_days = n(),
    median_detections = median(n_detections),
    mean_detections = mean(n_detections),
    median_sensors = median(n_sensors),
    mean_sensors = mean(n_sensors),
    median_duration = median(duration_mins),
    mean_duration = mean(duration_mins),
    .groups = "drop"
  )

write_csv(identifier_day_summary,
          file.path(out_dir, "identity_freq_visit_summary.csv"))
cat("\nIdentifier-day characteristics by observed-day band:\n")
print(identifier_day_summary)

# Violin plot: sensors per visit
p_sensors <- ggplot(
  identifier_day_stats,
  aes(x = observed_day_band, y = n_sensors, fill = observed_day_band)
) +
  geom_violin(alpha = 0.7, draw_quantiles = c(0.25, 0.5, 0.75)) +
  geom_boxplot(width = 0.12, fill = "white", alpha = 0.8, outlier.shape = NA) +
  scale_fill_manual(values = c("1 day" = "#d7191c", "5–7 days" = "#2c7bb6")) +
  scale_y_continuous(breaks = seq(0, 25, 5)) +
  labs(title = "Sensor Coverage per Identifier-Day",
       x = NULL, y = "Number of sensors") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        legend.position = "none",
        panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "identity_freq_sensors.png"), p_sensors,
       width = 5, height = 4.5, dpi = 300, bg = "white")

## 6. Movement Segments ----

# Localize first so simultaneous multi-sensor detections do not create
# ordering-dependent endpoints. These are 30-minute-gap segments, not
# independently validated trips.
wifi_freq_localized <- wifi_freq |>
  mutate(strength_sum = 100 * detections + rssi_sum) |>
  arrange(source_address, timestamp, desc(strength_sum), sensor_name) |>
  distinct(source_address, timestamp, .keep_all = TRUE)

od_freq <- wifi_freq_localized |>
  arrange(source_address, timestamp) |>
  group_by(source_address) |>
  mutate(gap = as.numeric(difftime(timestamp, lag(timestamp), units = "mins")),
         segment_id = cumsum(is.na(gap) | gap > 30)) |>
  group_by(source_address, segment_id, observed_day_band) |>
  summarise(origin = first(sensor_name), destination = last(sensor_name),
            n_det = n(), .groups = "drop") |>
  filter(origin != destination, n_det >= 2) |>
  count(observed_day_band, origin, destination, name = "n_segments") |>
  group_by(observed_day_band) |>
  slice_max(n_segments, n = 7) |>
  ungroup() |>
  mutate(route = paste0(origin, " -> ", destination))

write_csv(od_freq, file.path(out_dir, "identity_freq_od.csv"))

# Join coordinates for flow map
edges_freq <- od_freq |>
  left_join(sensor_coords, by = c("origin" = "sensor_name")) |>
  rename(x_from = X, y_from = Y) |>
  left_join(sensor_coords, by = c("destination" = "sensor_name")) |>
  rename(x_to = X, y_to = Y) |>
  mutate(observed_day_band = factor(
    observed_day_band,
    levels = c("1 day", "5–7 days")
  ))

# Sensor labels for OD endpoints
od_sensors_freq <- unique(c(edges_freq$origin, edges_freq$destination))
od_labels_freq <- sensor_coords |> filter(sensor_name %in% od_sensors_freq)

# Build faceted flow map
# Pre-scaled widths: grey casing sits slightly wider than the colored flow,
# and the identity scale keeps the legend in real segment counts
outline_delta <- 0.7
rng_fo <- range(edges_freq$n_segments)
edges_freq <- edges_freq |>
  mutate(w_main = scales::rescale(n_segments, to = c(0.5, 3), from = rng_fo),
         w_out  = w_main + outline_delta)
brk_fo <- pretty(rng_fo, n = 3)
brk_fo <- brk_fo[brk_fo >= rng_fo[1] & brk_fo <= rng_fo[2]]

p_fo <- ggmap(base_map, darken = c(0.3, "white")) +
  geom_point(data = sensor_coords, aes(x = X, y = Y),
             size = 1, color = "grey50", inherit.aes = FALSE) +
  geom_curve(data = edges_freq,
             aes(x = x_from, y = y_from, xend = x_to, yend = y_to,
                 linewidth = w_out),
             curvature = 0.25, color = "grey25", alpha = 1,
             arrow = arrow(length = unit(2.0, "mm"), type = "closed"),
             inherit.aes = FALSE, show.legend = FALSE) +
  geom_curve(data = edges_freq,
             aes(x = x_from, y = y_from, xend = x_to, yend = y_to,
                 linewidth = w_main, color = observed_day_band),
             curvature = 0.25, alpha = 1,
             arrow = arrow(length = unit(1.5, "mm"), type = "closed"),
             inherit.aes = FALSE) +
  geom_point(data = od_labels_freq, aes(x = X, y = Y),
             size = 2.5, color = "white", inherit.aes = FALSE) +
  geom_point(data = od_labels_freq, aes(x = X, y = Y),
             size = 2, color = "#333333", inherit.aes = FALSE) +
  geom_text_repel(data = od_labels_freq, aes(x = X, y = Y, label = sensor_name),
                  size = 2.2, fontface = "bold.italic", color = "black",
                  bg.color = "white", bg.r = 0.12,
                  box.padding = 0.35, point.padding = 0.2,
                  max.overlaps = 20, seed = 42, inherit.aes = FALSE) +
  scale_linewidth_identity(
    name   = "Segments",
    breaks = scales::rescale(brk_fo, to = c(0.5, 3), from = rng_fo),
    labels = scales::comma(brk_fo),
    guide  = guide_legend(override.aes = list(color = "grey40"))) +
  scale_color_manual(values = c("1 day" = "#d7191c", "5–7 days" = "#2c7bb6"),
                     guide = "none") +
  facet_wrap(~ observed_day_band, ncol = 2) +
  coord_sf(crs = 4326,
           xlim = c(bbox["xmin"] - pad, bbox["xmax"] + pad),
           ylim = c(bbox["ymin"] - pad, bbox["ymax"] + pad)) +
  labs(title = "Primary Movement Segments",
       subtitle = "Top localized first-to-last segments within each observed-day band") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        strip.text = element_text(size = 11, face = "bold"),
        strip.background = element_rect(fill = "gray90", color = NA),
        panel.spacing = unit(0.5, "lines"),
        legend.position   = "bottom",
        legend.title      = element_text(size = 8),
        legend.text       = element_text(size = 7),
        legend.key.width  = unit(0.9, "cm"),
        legend.key.height = unit(0.45, "cm"),
        legend.margin     = margin(0, 6, 2, 6),
        axis.title = element_blank(),
        axis.text = element_blank(),
        axis.ticks = element_blank(),
        panel.grid = element_blank())

ggsave(file.path(out_dir, "identity_freq_od.png"), p_fo,
       width = 6, height = 5, dpi = 300, bg = "white")


# Copy figures to docs ----

fig_files <- list.files(out_dir, pattern = "^identity_.*\\.png$", full.names = TRUE)
for (f in fig_files) {
  file.copy(f, file.path(fig_dir, basename(f)), overwrite = TRUE)
}
cat("\nCopied", length(fig_files), "figures to", fig_dir, "\n")

# Summary ----

cat("\n=== Observed-Day Revisit Profile Summary ===\n")
cat("Data period:", as.character(min(wifi$date)), "to",
    as.character(max(wifi$date)), paste0("(", n_total_days, " days)\n"))
cat("Total retained identifiers:",
    format(n_distinct(wifi$source_address), big.mark = ","), "\n")
cat("High-frequency band starts at:", high_frequency_threshold, "days\n\n")
count(identifier_days, observed_day_band, sort = TRUE) |> print()
cat("\nOutput saved to:", out_dir, "\n")
cat("Figures copied to:", fig_dir, "\n")
