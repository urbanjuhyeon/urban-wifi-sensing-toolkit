# =============================================================================
# 5-2-casestudy_v2.R: Activities + Identity in UoU Commercial District
# =============================================================================
#
# Figure 3 for the online case study: 3-panel figure
#   a) Map: sensor locations with stay rate + ped-priority street overlay
#   b) Boxplot: per-sensor stay rates by street type (horizontal)
#   c) Dumbbell: stay rate by visit frequency x street type
#
# Pipeline:
#   1. Localize: 20-sec windows, strength sum(100+RSSI) -> strongest sensor (Ch 4-2)
#   2. Trajectories: gap > 2 hr -> new trajectory (Ch 4-4)
#   3. Quality filter: min 2 sensors, 1 min - 2 hr duration
#   4. Anchor clustering: Li et al. (2008), theta = 75 m
#   5. Stay detection: clusters split into episodes at silences >= 10 min,
#      episode span >= 5 min -> stay at the episode's primary sensor (Ch 4-6)
#   6. Visit frequency: Single-day (1 day) vs Multi-day (2+ days)
#   7. Cross-analysis: visit frequency x street type -> stay rate
#
# Site: UoU commercial district, Ulsan (Jul 11-19, 2020), 17 sensors
#
# Input:  workflow/uou20/data/wifi_uou20_20sec.parquet
#         workflow/uou20/output/sensors_coords.csv
#         workflow/uou20/data/poi_uou.gpkg
#
# Output: workflow/uou20/output/fig3_activities_v2.png
#         workflow/uou20/output/activities_*.csv
#         workflow/uou20/output/freq_*.csv
#         docs/materials/ch5/fig3_activities.png
#
# =============================================================================


# Setup ----

pacman::p_load(tidyverse, lubridate, data.table, arrow, sf, ggmap, ggrepel, patchwork)

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

sample_dir <- file.path(base_dir, "workflow/uou20")
wifi_file  <- Sys.getenv(
  "UOU20_WIFI_FILE",
  unset = file.path(sample_dir, "data/wifi_uou20_20sec.parquet")
)
sensor_file <- Sys.getenv(
  "UOU20_SENSOR_FILE",
  unset = file.path(sample_dir, "output/sensors_coords.csv")
)
out_dir <- Sys.getenv(
  "UOU20_OUTPUT_DIR",
  unset = file.path(sample_dir, "output")
)
analysis_only <- tolower(Sys.getenv("UOU20_ANALYSIS_ONLY", unset = "false")) %in%
  c("1", "true", "yes")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Parameters
sampling_window <- 20      # seconds -- localization time window
gap_threshold   <- 7200    # seconds (2 hr) -- trajectory splitting
theta_dist      <- 75      # meters -- spatial clustering distance
stay_threshold  <- 300     # seconds (5 min) -- minimum stay duration
continuity_gap  <- 600     # seconds (10 min) -- silence that ends a detection
                           # episode (Reinhart et al. 2017; Yuan et al. 2025)
min_sensors     <- 2       # minimum sensors per trajectory
min_duration    <- 60      # seconds (1 min) -- minimum trajectory duration
max_duration    <- 7200    # seconds (2 hr) -- maximum trajectory duration
night_hours     <- 0:4     # local hours used for nighttime persistence
night_day_min   <- 3       # observed at night on N+ local days
local_timezone  <- "Asia/Seoul"

TYPE_COLORS <- c("Pedestrian-priority" = "#2979FF", "Conventional" = "#999999")
FREQ_COLORS <- c("Single-day" = "#E65100", "Multi-day" = "#1565C0")


# Load Data ----

cat("Loading data...\n")

## Sensor Coordinates ----

sensors_raw <- read_csv(sensor_file, show_col_types = FALSE)

sensors       <- sensors_raw |> transmute(sensor_name = id_sensor, street_type, x, y)
rm(sensors_raw)

## Standardized 20-second WiFi ----

wifi_20s <- read_parquet(
  wifi_file
) |>
  mutate(
    timestamp = as.POSIXct(timestamp, tz = "UTC"),
    timestamp_local = with_tz(timestamp, tzone = local_timezone),
    local_date = as_date(timestamp_local),
    local_hour = hour(timestamp_local)
  )

required_cols <- c(
  "timestamp", "source_address", "sensor_name", "rssi_median",
  "rssi_sum", "detections"
)
if (!all(required_cols %in% names(wifi_20s))) {
  stop("The standardized 20-second input is missing required columns")
}
if (!"strength_sum" %in% names(wifi_20s)) {
  # The public release ships without strength_sum; restore the localization score
  wifi_20s$strength_sum <- 100 * wifi_20s$detections + wifi_20s$rssi_sum
} else if (any(wifi_20s$strength_sum != 100 * wifi_20s$detections + wifi_20s$rssi_sum)) {
  stop("strength_sum invariant failed")
}
if (any(as.numeric(wifi_20s$timestamp) %% sampling_window != 0)) {
  stop("Input timestamps are not aligned to 20-second windows")
}

cat("  20-second sensor-level rows:", format(nrow(wifi_20s), big.mark = ","),
    "| Retained identifiers:", n_distinct(wifi_20s$source_address),
    "| Sensors:", n_distinct(wifi_20s$sensor_name), "\n")

## Distance Matrix ----

sensor_sf <- st_as_sf(sensors, coords = c("x", "y"), crs = 4326) |>
  st_transform(5179)

dist_mat <- st_coordinates(sensor_sf) |> dist() |> as.matrix()
dimnames(dist_mat) <- list(sensors$sensor_name, sensors$sensor_name)

sensor_idx <- setNames(seq_len(nrow(sensors)), sensors$sensor_name)


# Localize ----

cat("Localizing standardized ", sampling_window,
    "-sec windows by strength sum...\n", sep = "")

## Strongest Sensor ----

dt <- as.data.table(wifi_20s)
# Exact strength ties are resolved by sensor identifier so results do not
# depend on CSV/Parquet row order.
wifi <- dt[order(source_address, timestamp, -strength_sum, sensor_name)
][, head(.SD, 1), by = .(source_address, timestamp)
][, .(source_address,
      timestamp,
      timestamp_local,
      local_date,
      local_hour,
      sensor_name
      )] |>
  as_tibble()

rm(dt, wifi_20s)

wifi <- wifi |>
  inner_join(sensors |> select(sensor_name, street_type), by = "sensor_name")

cat("  Localized rows:", format(nrow(wifi), big.mark = ","),
    "identifier-windows\n")


# Sensor Uptime ----

cat("Checking sensor uptime...\n")

all_sensor_days <- expand_grid(
  sensor_name = unique(sensors$sensor_name),
  local_date  = unique(wifi$local_date)
)

uptime <- wifi |>
  mutate(slot = floor_date(timestamp_local, "30 minutes")) |>
  distinct(sensor_name, local_date, slot) |>
  count(sensor_name, local_date, name = "n_slots") |>
  right_join(all_sensor_days, by = c("sensor_name", "local_date")) |>
  replace_na(list(n_slots = 0L))

expected_slots <- max(uptime$n_slots)

uptime <- uptime |>
  mutate(coverage = round(n_slots / expected_slots, 2),
         healthy  = coverage >= 0.5)

valid_days <- uptime |>
  group_by(local_date) |>
  summarise(
    n_sensors   = n(),
    n_healthy   = sum(healthy),
    pct_healthy = round(n_healthy / n_sensors * 100, 1),
    .groups = "drop"
  )

write_csv(uptime, file.path(out_dir, "diag_sensor_uptime.csv"))
write_csv(valid_days, file.path(out_dir, "diag_valid_days.csv"))

valid_dates <- valid_days |> filter(pct_healthy >= 80) |> pull(local_date)
excluded    <- setdiff(unique(wifi$local_date), valid_dates)

cat("  Valid local days:", length(valid_dates), "of",
    n_distinct(wifi$local_date), "\n")
if (length(excluded) > 0) cat("  Excluded:", paste(excluded, collapse = ", "), "\n")

wifi <- wifi |> filter(local_date %in% valid_dates)

cat("  After date filtering:", format(nrow(wifi), big.mark = ","), "rows |",
    n_distinct(wifi$source_address), "retained identifiers\n")


# Nighttime-Persistence Filter ----

cat("Filtering nighttime-persistent pseudonyms (local hour ",
    min(night_hours), "-", max(night_hours), ", >=", night_day_min,
    " local days; timezone=", local_timezone, ")...\n", sep = "")

nighttime_persistent <- wifi |>
  filter(local_hour %in% night_hours) |>
  distinct(source_address, local_date) |>
  count(source_address, name = "night_days") |>
  filter(night_days >= night_day_min) |>
  pull(source_address)

wifi <- wifi |> filter(!source_address %in% nighttime_persistent)

cat("  Nighttime-persistent pseudonyms removed:", length(nighttime_persistent),
    "| Remaining:", format(nrow(wifi), big.mark = ","), "rows |",
    n_distinct(wifi$source_address), "pseudonyms\n")


# Stay Detection ----

## Build Trajectories ----

cat("\nBuilding trajectories (gap >", gap_threshold / 3600, "hr)...\n")

wifi <- wifi |>
  arrange(source_address, timestamp) |>
  group_by(source_address) |>
  mutate(
    time_gap = as.numeric(difftime(timestamp, lag(timestamp), units = "secs")),
    traj_id  = cumsum(is.na(time_gap) | time_gap > gap_threshold)
  ) |>
  ungroup() |>
  select(-time_gap)

traj_summary <- wifi |>
  group_by(source_address, traj_id) |>
  summarise(
    duration_sec = as.numeric(difftime(max(timestamp), min(timestamp), units = "secs")),
    n_windows    = n(),
    n_sensors    = n_distinct(sensor_name),
    local_date   = as_date(min(timestamp_local)),
    .groups = "drop"
  )

cat("  Raw trajectories:", format(nrow(traj_summary), big.mark = ","), "\n")

## Quality Filter ----

valid_traj <- traj_summary |>
  filter(n_sensors >= min_sensors,
         duration_sec >= min_duration,
         duration_sec <= max_duration)

wifi <- wifi |>
  semi_join(valid_traj, by = c("source_address", "traj_id"))

traj_summary <- valid_traj

cat("  After filtering (sensors >=", min_sensors,
    ", duration", min_duration, "-", max_duration, "sec):",
    format(nrow(traj_summary), big.mark = ","),
    "| Median duration:", round(median(traj_summary$duration_sec) / 60, 1), "min\n")


# Visit Frequency Classification ----

cat("\nClassifying visit frequency (Single-day vs Multi-day)...\n")

# Classify by the number of distinct days carrying a qualifying visit, i.e. a
# trajectory that passed the quality filter above. Detection-only days (e.g. a
# single probe from a passing vehicle) do not count as visit days, so the
# classification shares its population with the stay analysis below.
# Single-day: qualifying visits on exactly 1 of 9 valid days
# Multi-day:  qualifying visits on 2+ local dates

visit_freq <- traj_summary |>
  distinct(source_address, local_date) |>
  count(source_address, name = "n_days") |>
  mutate(visit_type = if_else(n_days == 1L, "Single-day", "Multi-day"))

freq_summary <- visit_freq |>
  count(visit_type, name = "n_identifiers") |>
  mutate(pct = round(n_identifiers / sum(n_identifiers) * 100, 1))

cat("\nVisit frequency classification:\n")
print(freq_summary)
write_csv(freq_summary, file.path(out_dir, "freq_classification.csv"))


## Anchor Clustering ----

cat("Anchor clustering (theta =", theta_dist, "m)...\n")

assign_clusters <- function(sensors, dist_mat, sensor_idx, theta_dist) {
  n <- length(sensors)
  if (n <= 1L) return(rep(1L, n))

  ids <- integer(n)
  ids[1] <- 1L
  anchor <- sensor_idx[sensors[1]]
  cid <- 1L

  for (i in 2:n) {
    cur <- sensor_idx[sensors[i]]
    if (dist_mat[anchor, cur] > theta_dist) {
      cid <- cid + 1L
      anchor <- cur
    }
    ids[i] <- cid
  }
  ids
}

wifi <- wifi |>
  group_by(source_address, traj_id) |>
  mutate(cluster_id = assign_clusters(sensor_name, dist_mat, sensor_idx, theta_dist)) |>
  ungroup()

# Episode split: within a cluster, detections >= continuity_gap apart belong
# to separate episodes, so silent stretches cannot extend a stay. Each episode
# carries its own primary sensor (Reinhart et al. 2017; Yuan et al. 2025).
episodes <- wifi |>
  arrange(source_address, traj_id, timestamp) |>
  group_by(source_address, traj_id, cluster_id) |>
  mutate(
    gap_prev = as.numeric(difftime(timestamp, lag(timestamp), units = "secs")),
    episode  = cumsum(is.na(gap_prev) | gap_prev >= continuity_gap)
  ) |>
  group_by(source_address, traj_id, cluster_id, episode) |>
  summarise(
    duration_sec   = as.numeric(difftime(max(timestamp), min(timestamp), units = "secs")),
    n_windows      = n(),
    n_sensors      = n_distinct(sensor_name),
    primary_sensor = names(which.max(table(sensor_name))),
    local_date     = as_date(min(timestamp_local)),
    .groups = "drop"
  ) |>
  mutate(is_stay = duration_sec >= stay_threshold) |>
  left_join(
    sensors |> select(primary_sensor = sensor_name, street_type),
    by = "primary_sensor"
  )

cat("  Episodes:", format(nrow(episodes), big.mark = ","),
    "( from", format(nrow(distinct(episodes, source_address, traj_id, cluster_id)),
                     big.mark = ","), "clusters )",
    "| Stay (>=", stay_threshold / 60, "min):", sum(episodes$is_stay),
    "(", round(mean(episodes$is_stay) * 100, 1), "%)\n")


## Stay Classification ----

cat("Classifying trajectory-sensor pairs...\n")

traj_sensor <- wifi |>
  group_by(source_address, traj_id, sensor_name, street_type) |>
  summarise(local_date = first(local_date), .groups = "drop")

stay_flags <- episodes |>
  filter(is_stay) |>
  distinct(source_address, traj_id, primary_sensor) |>
  mutate(stay_flag = TRUE)

traj_sensor <- traj_sensor |>
  left_join(
    stay_flags,
    by = c("source_address", "traj_id", "sensor_name" = "primary_sensor")
  ) |>
  mutate(
    is_stay       = !is.na(stay_flag),
    activity_type = if_else(is_stay, "Stay", "Pass-through")
  ) |>
  select(-stay_flag)

cat("  Pairs:", format(nrow(traj_sensor), big.mark = ","),
    "| Stay:", sum(traj_sensor$is_stay),
    "(", round(mean(traj_sensor$is_stay) * 100, 1), "%)\n")


# Street Comparison ----

cat("\nComparing street types...\n")

## Per-Sensor Results ----

sensor_result <- traj_sensor |>
  group_by(sensor_name, street_type) |>
  summarise(
    n_traj    = n(),
    n_stay    = sum(is_stay),
    n_move    = sum(!is_stay),
    stay_rate = round(mean(is_stay) * 100, 1),
    n_identifiers = n_distinct(source_address),
    .groups = "drop"
  ) |>
  arrange(desc(stay_rate))

cat("\nPer-sensor stay rates:\n")
print(sensor_result)
write_csv(sensor_result, file.path(out_dir, "activities_sensor_result.csv"))

## Type Comparison ----

type_result <- traj_sensor |>
  group_by(street_type) |>
  summarise(
    n_traj_sensor = n(),
    n_stay        = sum(is_stay),
    stay_rate     = round(mean(is_stay) * 100, 1),
    n_identifiers = n_distinct(source_address),
    .groups = "drop"
  )

print(type_result)
write_csv(type_result, file.path(out_dir, "activities_type_result.csv"))


# Visit Frequency x Street Type ----

cat("\nCross-analysis: visit frequency x street type...\n")

traj_sensor_freq <- traj_sensor |>
  inner_join(visit_freq |> select(source_address, visit_type), by = "source_address")

## Aggregate cross-table ----

freq_cross <- traj_sensor_freq |>
  group_by(visit_type, street_type) |>
  summarise(
    n_traj_sensor = n(),
    n_stay        = sum(is_stay),
    stay_rate     = round(mean(is_stay) * 100, 1),
    n_identifiers = n_distinct(source_address),
    .groups = "drop"
  )

cat("\nVisit frequency x Street type stay rates:\n")
print(freq_cross)
write_csv(freq_cross, file.path(out_dir, "freq_stay_cross.csv"))

## Per-sensor by visit frequency ----

sensor_freq_result <- traj_sensor_freq |>
  group_by(sensor_name, street_type, visit_type) |>
  summarise(
    n_traj    = n(),
    n_stay    = sum(is_stay),
    stay_rate = round(mean(is_stay) * 100, 1),
    .groups = "drop"
  )

write_csv(sensor_freq_result, file.path(out_dir, "freq_sensor_result.csv"))

## Visit frequency summary stats ----

freq_visit_stats <- visit_freq |>
  group_by(visit_type) |>
  summarise(
    n_identifiers = n(),
    median_days = median(n_days),
    mean_days   = round(mean(n_days), 1),
    .groups = "drop"
  )

write_csv(freq_visit_stats, file.path(out_dir, "freq_visit_stats.csv"))

if (analysis_only) {
  cat("\nAnalysis-only mode: figures were not generated.\n")
  cat("Tabular outputs saved to:\n  ", out_dir, "\n", sep = "")
  quit(save = "no", status = 0L)
}


# Generate Figure ----

cat("\nGenerating 3-panel figure...\n")

## Prepare plot data ----

df <- sensor_result |>
  left_join(sensors |> select(sensor_name, x, y), by = "sensor_name") |>
  mutate(street_type = if_else(
    street_type == "Pedestrian", "Pedestrian-priority", "Conventional"
  ) |> factor(levels = c("Conventional", "Pedestrian-priority"))) |>
  arrange(desc(y))

# Bus stops
poi_file <- file.path(sample_dir, "data/poi_uou.gpkg")
if (!file.exists(poi_file)) poi_file <- file.path(sample_dir, "poi_uou.gpkg")
has_bus_stops <- file.exists(poi_file)

if (has_bus_stops) {
  bus_stops <- st_read(poi_file, quiet = TRUE) |> st_transform(4326)
  bus_coords <- as.data.frame(st_coordinates(bus_stops)) |> rename(x = X, y = Y)
}

# Street overlay
street_ground_w <- c(
  motorway = 12, trunk = 12, primary = 12, secondary = 10, tertiary = 8,
  unclassified = 6, residential = 6, living_street = 6, service = 4,
  pedestrian = 5, footway = 2, path = 2, cycleway = 2, track = 2, steps = 1.5
)

streets <- st_read(
  file.path(base_dir, "workflow/figS4/streets_5sites.gpkg"),
  layer = "streets", quiet = TRUE
) |>
  filter(site == "uou20")

street_poly <- local({
  d <- st_transform(streets, 32652)
  if (!"gw" %in% names(d)) d$gw <- street_ground_w[d$highway]
  st_transform(st_union(st_buffer(d, dist = d$gw / 2)), 4326)
})

# Basemap
api_key_file <- file.path(base_dir, ".google_api_key")
if (file.exists(api_key_file)) {
  register_google(key = readLines(api_key_file, warn = FALSE))
}

base_map <- get_map(
  location = c(lon = mean(df$x), lat = mean(df$y)),
  zoom = 17, maptype = "satellite", source = "google", color = "bw"
)

# Pedestrian-priority street lines
ped_main <- df |>
  filter(sensor_name %in% c("u02", "u04", "u06", "u09", "u11", "u13", "u15")) |>
  arrange(desc(y))

ped_branch <- df |>
  filter(sensor_name %in% c("u03", "u04")) |>
  arrange(desc(y))


## Panel a) Map ----

pad <- 0.0008

p_map <- ggmap(base_map, darken = c(0.4, "white")) +
  geom_sf(data = street_poly,
          fill = alpha("white", 0.40),
          color = alpha("grey20", 0.35), linewidth = 0.25,
          inherit.aes = FALSE) +
  geom_path(data = ped_main, aes(x = x, y = y, color = "Pedestrian-priority street"),
            linewidth = 2.5, alpha = 0.6, inherit.aes = FALSE) +
  geom_path(data = ped_branch, aes(x = x, y = y, color = "Pedestrian-priority street"),
            linewidth = 2.5, alpha = 0.6, show.legend = FALSE, inherit.aes = FALSE) +
  geom_point(data = df,
             aes(x = x, y = y, fill = stay_rate, size = n_traj),
             shape = 21, color = "white", stroke = 0.6, inherit.aes = FALSE) +
  geom_text_repel(
    data = df, aes(x = x, y = y, label = sensor_name),
    size = 2.8, fontface = "bold", color = "white",
    bg.color = "grey20", bg.r = 0.15,
    box.padding = 0.35, point.padding = 0.25,
    max.overlaps = 20, seed = 42, inherit.aes = FALSE
  ) +
  # Scale bar (50 m)
  annotate("rect",
           xmin = min(df$x) - pad * 1.05,
           xmax = min(df$x) - pad * 0.85 + 0.00055 + pad * 0.2,
           ymin = min(df$y) - pad * 0.68,
           ymax = min(df$y) - pad * 0.15,
           fill = alpha("black", 0.35)) +
  annotate("segment",
           x = min(df$x) - pad * 0.85,
           xend = min(df$x) - pad * 0.85 + 0.00055,
           y = min(df$y) - pad * 0.35,
           yend = min(df$y) - pad * 0.35,
           linewidth = 0.8, color = "white") +
  annotate("text",
           x = min(df$x) - pad * 0.85 + 0.00055 / 2,
           y = min(df$y) - pad * 0.52,
           label = "50 m", size = 2, color = "white", fontface = "bold") +
  scale_color_manual(
    values = c("Pedestrian-priority street" = "#2979FF"),
    labels = c("Pedestrian-priority street" = "Pedestrian-\npriority street"),
    name = NULL
  ) +
  scale_fill_gradient(
    low = "#FFF9C4", high = "#C62828",
    name = "Stay ratio (%)",
    limits = c(0, 20), breaks = c(0, 5, 10, 15, 20)
  ) +
  scale_size_continuous(range = c(3, 9), name = "Trajectories\nobserved",
                        breaks = c(5000, 15000, 25000),
                        labels = scales::comma) +
  guides(
    color = guide_legend(order = 1, override.aes = list(linewidth = 2.6, alpha = 0.85),
                         label.theme = element_text(size = 8)),
    fill  = guide_colorbar(
      order = 2,
      title.theme = element_text(size = 8, face = "bold", margin = margin(b = 8))
    ),
    size  = guide_legend(order = 3, override.aes = list(fill = "grey50"))
  ) +
  coord_sf(crs = 4326,
           xlim = c(min(df$x) - pad, max(df$x) + pad),
           ylim = c(min(df$y) - pad * 0.6, max(df$y) + pad * 0.6)) +
  labs(tag = "a)") +
  theme_void() +
  theme(
    legend.position   = "right",
    legend.title      = element_text(size = 8, face = "bold"),
    legend.text       = element_text(size = 7),
    legend.key.height = unit(0.6, "cm"),
    legend.key.width  = unit(0.35, "cm"),
    legend.margin     = margin(0, 0, 0, 8),
    legend.spacing.y  = unit(0.45, "cm"),
    panel.border      = element_rect(colour = "grey50", fill = NA, linewidth = 0.4),
    plot.tag    = element_text(face = "bold.italic", size = 14),
    plot.margin = margin(5, 2, 5, 5)
  )

# Conditional bus stops layer
if (has_bus_stops) {
  p_map <- p_map +
    geom_point(data = bus_coords, aes(x = x, y = y),
               shape = 22, size = 4, fill = alpha("#1565C0", 0.75), color = "white",
               stroke = 0.4, inherit.aes = FALSE) +
    geom_text(data = bus_coords, aes(x = x, y = y, label = "B"),
              size = 2, fontface = "bold", color = "white",
              inherit.aes = FALSE)
}


## Panel b) Boxplot — horizontal, compressed ----

set.seed(42)
df <- df |>
  mutate(x_jit = as.numeric(street_type) + runif(n(), -0.15, 0.15))

p_box <- ggplot(df, aes(x = street_type, y = stay_rate, fill = street_type)) +
  geom_boxplot(width = 0.55, outlier.shape = NA, alpha = 0.3) +
  geom_point(aes(x = x_jit), shape = 21, size = 3.5,
             color = "white", stroke = 0.5, alpha = 0.9) +
  geom_text_repel(aes(x = x_jit, label = sensor_name),
                  size = 2.3, fontface = "bold",
                  color = "grey20", bg.color = "white", bg.r = 0.12,
                  min.segment.length = 0.15, segment.size = 0.3,
                  max.overlaps = Inf, force = 2, seed = 42,
                  direction = "y") +
  scale_fill_manual(values = TYPE_COLORS, guide = "none") +
  scale_x_discrete(labels = c("Conventional" = "Conventional\nstreet",
                               "Pedestrian-priority" = "Pedestrian-\npriority street")) +
  coord_flip() +
  labs(x = NULL, y = "Stay ratio (%)", tag = "b)") +
  theme_bw() +
  theme(
    plot.tag     = element_text(face = "bold.italic", size = 14),
    axis.text.y  = element_text(size = 9, face = "bold"),
    axis.text.x  = element_text(size = 8),
    axis.title.x = element_text(size = 9),
    panel.grid.minor = element_blank(),
    plot.margin = margin(5, 10, 2, 5)
  )


## Panel c) Dumbbell — ped-priority lift by visit frequency ----

# Axes flipped from original: Y = visit frequency, dots = street type
# Both gaps are positive (Pedestrian-priority > Conventional for all groups)
# Uses TYPE_COLORS for visual continuity with panel b)

# Wide format: one row per visit_type, columns = street type stay rates
dumb_wide <- freq_cross |>
  mutate(
    visit_label = factor(visit_type, levels = c("Multi-day", "Single-day"),
                         labels = c("Multi-day\nobserved", "Single-day\nobserved")),
    street_label = if_else(
      street_type == "Pedestrian", "Pedestrian-priority", "Conventional"
    )
  ) |>
  select(visit_label, street_label, stay_rate) |>
  pivot_wider(names_from = street_label, values_from = stay_rate) |>
  mutate(
    gap = `Pedestrian-priority` - Conventional,
    gap_label = paste0("+", sprintf("%.1f", gap), " pp")
  )

# Long format for dots
dumb_long <- freq_cross |>
  mutate(
    visit_label = factor(visit_type, levels = c("Multi-day", "Single-day"),
                         labels = c("Multi-day\nobserved", "Single-day\nobserved")),
    street_label = if_else(
      street_type == "Pedestrian", "Pedestrian-priority", "Conventional"
    ) |> factor(levels = c("Pedestrian-priority", "Conventional"))
  )

# Street type annotations: place above the top row labels only
dumb_annot <- dumb_long |>
  filter(visit_type == "Single-day") |>
  mutate(annot_label = if_else(
    as.character(street_label) == "Pedestrian-priority",
    "Pedestrian-\npriority street", "Conventional\nstreet"
  ))

# Per-visit-type weighted mean stay rate (combines both street types)
dumb_mean <- freq_cross |>
  group_by(visit_type) |>
  summarise(mean_rate = round(sum(n_stay) / sum(n_traj_sensor) * 100, 1),
            .groups = "drop") |>
  mutate(visit_label = factor(visit_type, levels = c("Multi-day", "Single-day"),
                               labels = c("Multi-day\nobserved", "Single-day\nobserved")))

p_dumbbell <- ggplot() +
  # Connecting segments
  geom_segment(data = dumb_wide,
               aes(x = Conventional, xend = `Pedestrian-priority`,
                   y = visit_label, yend = visit_label),
               color = "grey60", linewidth = 1.5, lineend = "round") +
  # Weighted mean per visit type — diamond marker on segment
  geom_point(data = dumb_mean, aes(x = mean_rate, y = visit_label),
             shape = 18, size = 2.2, color = "grey35") +
  # Rounded-rect labels — replaces point + text
  geom_label(data = dumb_long,
             aes(x = stay_rate, y = visit_label,
                 fill = street_label, label = sprintf("%.1f%%", stay_rate)),
             color = "white", fontface = "bold", size = 3,
             label.r = unit(0.3, "lines"),
             label.padding = unit(0.25, "lines"),
             linewidth = 0, show.legend = FALSE) +
  # Street type names — attached closely to the single-day observed labels
  geom_text(data = dumb_annot,
            aes(x = stay_rate, y = visit_label, label = annot_label,
                color = street_label),
            vjust = -0.7, size = 3, fontface = "bold", show.legend = FALSE) +
  # Gap labels — dark blue, slightly spaced from rightmost label
  geom_text(data = dumb_wide,
            aes(x = `Pedestrian-priority` + 1.6, y = visit_label, label = gap_label),
            size = 2.8, hjust = 0, fontface = "bold", color = "#1A237E") +
  scale_fill_manual(values = TYPE_COLORS) +
  scale_color_manual(values = c("Pedestrian-priority" = "#0D47A1", "Conventional" = "#424242")) +
  scale_x_continuous(
    limits = c(0, NA),
    expand = expansion(mult = c(0.02, 0.20))
  ) +
  labs(x = "Stay ratio (%)", y = NULL, tag = "c)") +
  theme_bw() +
  theme(
    plot.tag     = element_text(face = "bold.italic", size = 14),
    axis.text.y  = element_text(size = 9, face = "bold"),
    axis.text.x  = element_text(size = 8),
    axis.title.x = element_text(size = 9),
    legend.position = "none",
    panel.grid.minor   = element_blank(),
    panel.grid.major.y = element_blank(),
    plot.margin = margin(2, 10, 5, 5)
  )


## Combine & Export ----

# Layout: a) map (left, full height) | b) boxplot (top right) / c) dumbbell (bottom right)
# Using patchwork design string for precise control

design <- "
AABB
AABB
AACC
AACC
"

p_combined <- p_map + p_box + p_dumbbell +
  plot_layout(design = design, widths = c(0.94, 0.94, 1.06, 1.06))

# Save to workflow output
ggsave(file.path(out_dir, "fig3_activities_v2.png"), p_combined,
       width = 9.5, height = 5.5, dpi = 300, bg = "white")

# Copy to docs
docs_dir <- file.path(base_dir, "docs/materials/ch5")
dir.create(docs_dir, recursive = TRUE, showWarnings = FALSE)
ggsave(file.path(docs_dir, "fig3_activities.png"), p_combined,
       width = 9.5, height = 5.5, dpi = 300, bg = "white")

## n_days distribution (for Ch5 book) ----

freq_ndays_dist <- visit_freq |>
  count(n_days, name = "n_identifiers") |>
  mutate(
    visit_type = if_else(n_days == 1L, "Single-day", "Multi-day"),
    pct = round(n_identifiers / sum(n_identifiers) * 100, 1)
  )

write_csv(freq_ndays_dist, file.path(out_dir, "freq_ndays_dist.csv"))


cat("\nDone. Outputs saved to:\n")
cat("  ", out_dir, "\n")
cat("  ", docs_dir, "\n")
