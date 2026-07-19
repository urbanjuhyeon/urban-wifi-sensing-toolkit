# =============================================================================
# 4-6-activities.R: Activity Detection
# =============================================================================
#
# Stay detection: localize → trajectory → quality filter → anchor clustering → classify
#
# Pipeline (Toolkit Ch 4-2 → 4-4 → here):
#   1. Localize: strongest sensor per (identifier, timestamp) via strength_sum (Ch 4-2)
#   2. Trajectories: gap > 30 min → new trajectory (Ch 4-4)
#   3. Quality filter: remove trajectories < 3 detections or > 2 hours
#   4. Anchor clustering: distance from anchor > 150m → new cluster
#   5. Continuity: split clusters at detection gaps >= 10 min
#   6. Stay: episode duration >= 5 min; primary sensor is the modal sensor
#      within that episode
#
# Input:  workflow/unist19_main/data/sample_main/ (wifi.parquet, sensors.gpkg)
#         = extracted docs/downloads/sample_main.zip (public release data),
#         so figures reproduce exactly what a reader following Ch4-6 gets
# Output (workflow/unist19_main/output/):
#   Figures (copied to docs/materials/ch4/):
#     - activities_type_dist.png: Episode-duration class distribution
#     - activities_duration_dist.png: Stay duration distribution
#     - activities_hourly.png: Hourly stay count
#     - activities_sensor.png: Spatial distribution of stays
#     - activities_by_freq.png: Activity types by observed-day band
#   Data:
#     - activities_stay_summary.csv, activities_type_dist.csv
#     - activities_duration_dist.csv, activities_hourly.csv
#     - activities_sensor.csv, activities_by_freq.csv
#     - activities_type_by_freq.csv
#
# =============================================================================

# Setup ----

pacman::p_load(tidyverse, lubridate, arrow, sf, ggmap, ggrepel, data.table)

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

## Load data ----

wifi_raw <- read_parquet(file.path(data_dir, "wifi.parquet")) |>
  # Stored in UTC as in the release; convert once so calendar variables are local
  mutate(
    timestamp = with_tz(timestamp, "Asia/Seoul"),
    date = as_date(timestamp),
    hour = hour(timestamp)
  )

sensors <- st_read(file.path(data_dir, "sensors.gpkg"), quiet = TRUE)

## Sensor coordinates ----

sensor_coords <- sensors |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(sensors |> st_drop_geometry() |> select(sensor_name))

## Distance matrix (meters) ----

sensor_sf <- sensors |> st_transform(5179)
dist_mat <- as.numeric(st_distance(sensor_sf))
dist_mat <- matrix(dist_mat, nrow = nrow(sensor_sf),
                   dimnames = list(sensors$sensor_name, sensors$sensor_name))
sensor_idx <- setNames(seq_len(nrow(sensors)), sensors$sensor_name)

## Basemap ----

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

cat("Raw rows:", format(nrow(wifi_raw), big.mark = ","), "\n")
cat("Retained identifiers:",
    format(n_distinct(wifi_raw$source_address), big.mark = ","), "\n")


# Localize ----

cat("\n=== Localize ===\n")
cat("Selecting strongest sensor per (identifier, timestamp) via sum(100 + RSSI)...\n")

# Public sample data ships without strength_sum; derive it as in the tutorial
wifi <- wifi_raw |>
  mutate(strength_sum = 100 * detections + rssi_sum) |>
  arrange(source_address, timestamp, desc(strength_sum), sensor_name) |>
  distinct(source_address, timestamp, .keep_all = TRUE)

n_total_days <- n_distinct(wifi$date)
cat("  Raw:", format(nrow(wifi_raw), big.mark = ","),
    "-> Localized:", format(nrow(wifi), big.mark = ","),
    paste0("(", round(nrow(wifi) / nrow(wifi_raw) * 100, 1), "%)\n"))
cat("  Period:", as.character(min(wifi$date)), "to", as.character(max(wifi$date)),
    paste0("(", n_total_days, " days)\n"))

rm(wifi_raw)


# Stay Detection ----

cat("\n=== Stay Detection ===\n")

## Parameters ----

gap_threshold  <- 30   # minutes — trajectory splitting
dist_threshold <- 150  # meters — anchor clustering distance
continuity_gap <- 600  # seconds — silence that starts a new detection episode
time_threshold <- 5    # minutes — minimum stay duration

## Trajectories ----

cat("Building trajectories (gap >", gap_threshold, "min)...\n")

dt <- as.data.table(wifi)
setorder(dt, source_address, timestamp)

dt[, time_gap := as.numeric(difftime(timestamp, shift(timestamp), units = "mins")),
   by = source_address]
dt[, new_traj := is.na(time_gap) | time_gap > gap_threshold]
dt[, traj_id := cumsum(new_traj), by = source_address]

n_traj <- dt[, uniqueN(paste(source_address, traj_id))]
cat("  Trajectories:", format(n_traj, big.mark = ","), "\n")

## Trajectory Quality Filter ----
# Remove trajectories that are too long or too sparse for this demonstration.
# Matches methodology from 5-2-casestudy.R.

min_windows  <- 3     # minimum detections per trajectory
max_duration <- 7200  # seconds (2 hours) — excludes extended traces

traj_stats <- dt[, .(
  duration_sec = as.numeric(difftime(max(timestamp), min(timestamp), units = "secs")),
  n_windows = .N
), by = .(source_address, traj_id)]

valid_traj <- traj_stats[n_windows >= min_windows & duration_sec <= max_duration]

n_before <- nrow(dt)
dt <- dt[valid_traj[, .(source_address, traj_id)], on = .(source_address, traj_id)]
setorder(dt, source_address, traj_id, timestamp)

cat("  Quality filter: min_windows >=", min_windows,
    "& max_duration <=", max_duration / 60, "min\n")
cat("    Removed:", format(nrow(traj_stats) - nrow(valid_traj), big.mark = ","),
    "trajectories,", format(n_before - nrow(dt), big.mark = ","), "rows\n")
cat("    Remaining:", format(nrow(valid_traj), big.mark = ","),
    "trajectories,", format(nrow(dt), big.mark = ","), "rows\n")

## Anchor Clustering ----

cat("Anchor clustering (distance >", dist_threshold, "m from anchor)...\n")

# Anchor-based clustering (Li et al. 2008):
# Each cluster starts with an anchor sensor. Subsequent detections
# belong to the same cluster while their sensor is within dist_threshold
# of the anchor. When distance exceeds threshold, a new cluster starts
# with the current sensor as the new anchor.
#
# Unlike consecutive-distance segmentation, anchor clustering is stable
# for stable observations: an identifier alternating between nearby sensors
# stays in one cluster as long as both are within range of the anchor.

# Single pass over sorted data for performance
addr_vec <- dt$source_address
traj_vec <- dt$traj_id
sidx_vec <- sensor_idx[dt$sensor_name]

n <- nrow(dt)
cluster_ids <- integer(n)
cluster_ids[1] <- 1L
anchor <- sidx_vec[1]
cid <- 1L

for (i in 2:n) {
  if (addr_vec[i] != addr_vec[i-1] || traj_vec[i] != traj_vec[i-1]) {
    # New trajectory: reset anchor
    anchor <- sidx_vec[i]
    cid <- 1L
  } else if (dist_mat[anchor, sidx_vec[i]] > dist_threshold) {
    # Moved beyond anchor range: new cluster
    cid <- cid + 1L
    anchor <- sidx_vec[i]
  }
  cluster_ids[i] <- cid
}

dt[, cluster_id := cluster_ids]
rm(addr_vec, traj_vec, sidx_vec, cluster_ids)

## Detection Episodes ----

cat("Splitting clusters at detection gaps >=", continuity_gap / 60, "min...\n")

dt[, gap_prev_sec := as.numeric(difftime(timestamp, shift(timestamp), units = "secs")),
   by = .(source_address, traj_id, cluster_id)]
dt[, episode_id := cumsum(is.na(gap_prev_sec) | gap_prev_sec >= continuity_gap),
   by = .(source_address, traj_id, cluster_id)]

n_spatial_clusters <- dt[, uniqueN(paste(source_address, traj_id, cluster_id, sep = ":"))]

cat("Summarizing detection episodes...\n")
episodes <- dt[, .(
  start_time = min(timestamp),
  end_time = max(timestamp),
  duration_mins = as.numeric(difftime(max(timestamp), min(timestamp), units = "mins")),
  n_detections = .N,
  primary_sensor = names(which.max(table(sensor_name))),
  n_sensors = uniqueN(sensor_name),
  date = as_date(min(timestamp)),
  hour = hour(min(timestamp))
), by = .(source_address, traj_id, cluster_id, episode_id)]

episodes[, `:=`(
  is_stay = duration_mins >= time_threshold,
  activity_type = factor(
    fcase(
      duration_mins < time_threshold, "Pass-through",
      duration_mins < 15, "Short stay",
      duration_mins < 60, "Medium stay",
      default = "Long stay"
    ),
    levels = c("Pass-through", "Short stay", "Medium stay", "Long stay")
  )
)]

# Convert back to tibble for ggplot compatibility
episodes <- as_tibble(episodes)

stay_summary <- episodes |>
  summarise(
    total_spatial_clusters = n_spatial_clusters,
    total_episodes = n(),
    n_stays = sum(is_stay),
    pct_stays = mean(is_stay) * 100,
    median_duration = median(duration_mins[is_stay]),
    mean_duration = mean(duration_mins[is_stay])
  )

cat("\nStay detection results:\n")
cat("  Spatial clusters:", format(stay_summary$total_spatial_clusters, big.mark = ","), "\n")
cat("  Detection episodes:", format(stay_summary$total_episodes, big.mark = ","), "\n")
cat("  Stays (>=", time_threshold, "min):", format(stay_summary$n_stays, big.mark = ","),
    "(", round(stay_summary$pct_stays, 1), "%)\n")
cat("  Median stay duration:", round(stay_summary$median_duration, 1), "mins\n")

write_csv(stay_summary, file.path(out_dir, "activities_stay_summary.csv"))


# Observed Episode Patterns ----

cat("\n=== Observed Episode Patterns ===\n")

## Episode-duration class distribution ----

activity_dist <- episodes |>
  count(activity_type) |>
  mutate(pct = n / sum(n) * 100)

write_csv(activity_dist, file.path(out_dir, "activities_type_dist.csv"))
cat("\nEpisode-duration class distribution:\n")
print(activity_dist)

p_dist <- ggplot(activity_dist, aes(activity_type, pct, fill = activity_type)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = paste0(round(pct, 1), "%")),
            vjust = -0.5, fontface = "bold", size = 3.5) +
  scale_fill_manual(values = c("Pass-through" = "gray55",
                               "Short stay" = "#fdae61",
                               "Medium stay" = "#f46d43",
                               "Long stay" = "#d73027")) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(title = "Episode-Duration Class Distribution",
       subtitle = "Pass-through denotes an episode below the 5-minute threshold",
       x = NULL, y = "%") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        legend.position = "none",
        panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "activities_type_dist.png"), p_dist,
       width = 5.5, height = 4, dpi = 300, bg = "white")

## Duration distribution ----

stays_only <- episodes |> filter(is_stay)

duration_bins <- stays_only |>
  mutate(duration_bin = cut(duration_mins,
                            breaks = c(5, 10, 15, 30, 60, 120, Inf),
                            labels = c("5-10", "10-15", "15-30", "30-60", "60-120", "120+"),
                            right = FALSE)) |>
  count(duration_bin) |>
  mutate(pct = n / sum(n) * 100)

write_csv(duration_bins, file.path(out_dir, "activities_duration_dist.csv"))

p_duration <- ggplot(duration_bins, aes(duration_bin, pct)) +
  geom_col(fill = "gray45", width = 0.7) +
  geom_text(aes(label = paste0(round(pct, 1), "%")),
            vjust = -0.5, size = 3.2) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(title = "Stay Duration Distribution",
       x = "Duration (minutes)", y = "%") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "activities_duration_dist.png"), p_duration,
       width = 5.5, height = 4, dpi = 300, bg = "white")

## Hourly pattern ----

hourly_stays <- episodes |>
  group_by(hour) |>
  summarise(
    n_total = n(),
    n_stays = sum(is_stay),
    stay_rate = mean(is_stay) * 100,
    .groups = "drop"
  )

write_csv(hourly_stays, file.path(out_dir, "activities_hourly.csv"))

p_hourly <- ggplot(hourly_stays, aes(hour, n_stays)) +
  geom_col(fill = "gray45", width = 0.8) +
  scale_x_continuous(breaks = c(0, 4, 8, 12, 16, 20, 23),
                     labels = c("0AM", "4", "8", "12PM", "16", "20", "23")) +
  scale_y_continuous(labels = scales::comma) +
  labs(title = "Hourly Stay Count",
       subtitle = "Episodes are grouped by their start hour",
       x = NULL, y = "Number of stays") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "activities_hourly.png"), p_hourly,
       width = 6, height = 4, dpi = 300, bg = "white")

## Spatial pattern ----

sensor_activity <- episodes |>
  group_by(primary_sensor) |>
  summarise(
    n_episodes = n(),
    n_stays = sum(is_stay),
    stay_rate = mean(is_stay) * 100,
    avg_duration = mean(duration_mins[is_stay], na.rm = TRUE),
    .groups = "drop"
  ) |>
  left_join(sensor_coords, by = c("primary_sensor" = "sensor_name"))

write_csv(sensor_activity |> select(-X, -Y), file.path(out_dir, "activities_sensor.csv"))

# Top sensors by stay rate
top_stay_sensors <- sensor_activity |>
  filter(n_episodes >= 100) |>
  slice_max(stay_rate, n = 10)

p_sensor <- ggmap(base_map, darken = c(0.3, "white")) +
  geom_point(data = sensor_coords, aes(x = X, y = Y),
             size = 1.2, color = "grey60", inherit.aes = FALSE) +
  geom_point(data = sensor_activity,
             aes(x = X, y = Y, size = n_stays, color = stay_rate),
             alpha = 0.8, inherit.aes = FALSE) +
  geom_text_repel(
    data = top_stay_sensors, aes(x = X, y = Y, label = primary_sensor),
    size = 2.2, fontface = "bold.italic", color = "black",
    bg.color = "white", bg.r = 0.12,
    box.padding = 0.35, point.padding = 0.2,
    max.overlaps = 15, seed = 42, inherit.aes = FALSE
  ) +
  scale_size_continuous(range = c(1.5, 10), name = "Stay\ncount") +
  scale_color_gradient(low = "#fee08b", high = "#d73027", name = "Stay\nrate (%)") +
  coord_sf(crs = 4326,
           xlim = c(bbox["xmin"] - pad * 0.5, bbox["xmax"] + pad * 0.35),
           ylim = c(bbox["ymin"] + pad * 0.2, bbox["ymax"] - pad * 0.025)) +
  labs(title = "Spatial Distribution of Stays",
       subtitle = "Episode-level inferred-stay share by modal sensor") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        legend.position = "right",
        axis.title = element_blank(),
        axis.text = element_blank(),
        axis.ticks = element_blank(),
        panel.grid = element_blank())

ggsave(file.path(out_dir, "activities_sensor.png"), p_sensor,
       width = 6, height = 5, dpi = 300, bg = "white")

## By observed-day band ----

high_frequency_threshold <- 5

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

stays_with_band <- episodes |>
  left_join(identifier_days |> select(source_address, observed_day_band),
            by = "source_address") |>
  filter(observed_day_band %in% c("1 day", "5–7 days"))

stay_by_band <- stays_with_band |>
  group_by(observed_day_band) |>
  summarise(
    n_episodes = n(),
    n_stays = sum(is_stay),
    stay_rate = mean(is_stay) * 100,
    median_duration = median(duration_mins[is_stay], na.rm = TRUE),
    mean_duration = mean(duration_mins[is_stay], na.rm = TRUE),
    .groups = "drop"
  )

write_csv(stay_by_band, file.path(out_dir, "activities_by_freq.csv"))
cat("\nEpisode-level stay patterns by observed-day band:\n")
print(stay_by_band)

# Episode-duration class distribution by observed-day band
activity_by_band <- stays_with_band |>
  count(observed_day_band, activity_type) |>
  group_by(observed_day_band) |>
  mutate(pct = n / sum(n) * 100) |>
  ungroup()

write_csv(activity_by_band, file.path(out_dir, "activities_type_by_freq.csv"))

p_freq <- ggplot(
  activity_by_band,
  aes(activity_type, pct, fill = observed_day_band)
) +
  geom_col(position = "dodge", width = 0.7) +
  scale_fill_manual(values = c("1 day" = "#d7191c", "5–7 days" = "#2c7bb6"),
                    name = NULL) +
  labs(title = "Episode-Duration Classes by Observed-Day Band",
       subtitle = "Percentages use all episodes within each band",
       x = NULL, y = "%") +
  theme_bw() +
  theme(plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "gray40"),
        legend.position = "top", legend.justification = "left",
        legend.margin = margin(1.5, -0.5, 0, 0),
        panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "activities_by_freq.png"), p_freq,
       width = 6, height = 4, dpi = 300, bg = "white")


# Copy figures to docs ----

fig_files <- list.files(out_dir, pattern = "^activities_.*\\.png$", full.names = TRUE)
for (f in fig_files) {
  file.copy(f, file.path(fig_dir, basename(f)), overwrite = TRUE)
}
cat("\nCopied", length(fig_files), "figures to", fig_dir, "\n")

# Summary ----

cat("\n=== Activities Analysis Summary ===\n")
cat("Data period:", as.character(min(wifi$date)), "to",
    as.character(max(wifi$date)), paste0("(", n_total_days, " days)\n"))
cat("Total retained identifiers:",
    format(n_distinct(wifi$source_address), big.mark = ","), "\n")
cat("Pipeline: Localize -> Trajectory -> Quality filter -> Anchor cluster -> Episode -> Classify\n")
cat("Stay threshold:", time_threshold, "min |",
    "Continuity:", continuity_gap / 60, "min |",
    "Distance:", dist_threshold, "m |",
    "Gap:", gap_threshold, "min\n")
cat("Quality filter: min_windows >=", min_windows,
    "| max_duration <=", max_duration / 60, "min\n")
cat("Spatial clusters:", format(stay_summary$total_spatial_clusters, big.mark = ","), "\n")
cat("Detection episodes:", format(stay_summary$total_episodes, big.mark = ","), "\n")
cat("Stays:", format(stay_summary$n_stays, big.mark = ","),
    paste0("(", round(stay_summary$pct_stays, 1), "%)\n"))
cat("\nOutput saved to:", out_dir, "\n")
cat("Figures copied to:", fig_dir, "\n")
