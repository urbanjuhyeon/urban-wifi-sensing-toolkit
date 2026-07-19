# =============================================================================
# 4-4-track.R: WiFi Tracking Analysis - OD Patterns
# =============================================================================
#
# Analyzes observed trajectory patterns: gap-bounded trajectories,
# origin-destination matrices, and geom_curve flow maps.
#
# Input (from workflow/unist19_main/data/):
#   - wifi.parquet: 1-week WiFi sample (Oct 28 - Nov 3, 2019), public release
#   - sensors.gpkg: outdoor sensor locations
#   - poi.gpkg: campus points of interest
#
# Output (workflow/unist19_main/output/):
#   Figures (copied to docs/materials/ch4/):
#     - track_od_heatmap.png: OD probability matrix
#     - track_od_map.png: Top 5 flow map
#     - track_od_weekday_weekend.png: Weekday vs Weekend
#     - track_od_morning_evening.png: Morning vs Evening
#   Data:
#     - track_od_top5.csv
#     - track_od_daytype.csv
#     - track_od_timeperiod.csv
#
# =============================================================================

# Setup ----

pacman::p_load(
  tidyverse, lubridate, data.table, arrow, sf,
  ggmap, ggrepel
)

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

data_dir <- file.path(base_dir, "workflow/unist19_main/data/sample_main")
fig_dir    <- file.path(base_dir, "docs/materials/ch4")
out_dir    <- file.path(base_dir, "workflow/unist19_main/output")

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

api_key_file <- file.path(base_dir, ".google_api_key")
if (file.exists(api_key_file)) {
  register_google(key = readLines(api_key_file, warn = FALSE))
}

# Parameters ----

col_weekday <- "#FF8C00"
col_weekend <- "#00CED1"
gap_threshold <- 30   # minutes
top_n_flows   <- 15   # for comparison maps

# Load Data ----

cat("Loading data...\n")
wifi_raw <- read_parquet(file.path(data_dir, "wifi.parquet")) |>
  # Stored in UTC as in the release; convert once so calendar variables are local
  mutate(timestamp = with_tz(timestamp, "Asia/Seoul"))

cat("  Rows:", format(nrow(wifi_raw), big.mark = ","), "\n")
cat("  Period:", as.character(min(wifi_raw$timestamp)), "to",
    as.character(max(wifi_raw$timestamp)), "\n")
cat("  Retained identifiers:",
    format(n_distinct(wifi_raw$source_address), big.mark = ","), "\n")

sensors <- st_read(file.path(data_dir, "sensors.gpkg"), quiet = TRUE)

sensor_coords <- sensors |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(sensors |> st_drop_geometry() |> select(sensor_name))

cat("  Sensors:", nrow(sensors), "\n")

poi <- st_read(file.path(data_dir, "poi.gpkg"), quiet = TRUE)

poi_coords <- poi |>
  st_centroid() |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(poi |> st_drop_geometry() |> select(name)) |>
  mutate(label = str_wrap(name, width = 5))

cat("  POI:", nrow(poi), "\n")

## Basemap ----

cat("Loading basemap...\n")
bbox <- st_bbox(sensors)
pad <- 0.002

base_map <- get_map(
  location = c(
    lon = (bbox["xmin"] + bbox["xmax"]) / 2,
    lat = (bbox["ymin"] + bbox["ymax"]) / 2
  ),
  zoom = 16, maptype = "satellite", source = "google", color = "bw"
)

bb <- attr(base_map, "bb")
xlim <- c(bbox["xmin"] - pad, bbox["xmax"] + pad)
ylim <- c(bbox["ymin"] - pad, bbox["ymax"] + pad)

# Localize ----

cat("\nLocalizing (20-sec strongest sensor)...\n")

wifi <- as.data.table(wifi_raw)
# Public sample data ships without strength_sum; derive it as in the tutorial
wifi[, strength_sum := 100 * detections + rssi_sum]
setorder(wifi, source_address, timestamp, -strength_sum, sensor_name)
wifi <- wifi[, head(.SD, 1), by = .(source_address, timestamp)]
wifi <- wifi[, .(source_address, timestamp, sensor_name)]

cat("  Localized rows:", format(nrow(wifi), big.mark = ","),
    "(from", format(nrow(wifi_raw), big.mark = ","), "raw)\n")

# Build OD Matrix ----

cat("\nBuilding OD matrix...\n")

## Define Trajectories ----

setkey(wifi, source_address, timestamp)
wifi[, time_gap := as.numeric(difftime(timestamp, shift(timestamp), units = "mins")),
     by = source_address]
wifi[, trajectory_id := cumsum(is.na(time_gap) | time_gap > gap_threshold),
     by = source_address]

## Extract OD Pairs ----

od_pairs <- wifi[, .(
  origin       = sensor_name[1L],
  destination  = sensor_name[.N],
  trajectory_start = timestamp[1L],
  trajectory_end   = timestamp[.N],
  n_detections = .N
), by = .(source_address, trajectory_id)]

od_pairs <- od_pairs[origin != destination & n_detections >= 2L]
wifi[, c("time_gap", "trajectory_id") := NULL]

cat("  OD segments:", format(nrow(od_pairs), big.mark = ","), "\n")

od_pairs <- as_tibble(od_pairs)

## OD Counts ----

od_counts <- od_pairs |>
  count(origin, destination, name = "n_segments")

od_probs <- od_counts |>
  group_by(origin) |>
  mutate(total_from = sum(n_segments), prob = n_segments / total_from) |>
  ungroup()

## By Day Type ----

od_by_daytype <- od_pairs |>
  mutate(day_type = if_else(wday(trajectory_start) %in% c(1, 7), "Weekend", "Weekday")) |>
  count(origin, destination, day_type, name = "n_segments")

## By Time Period ----

od_time_period <- od_pairs |>
  filter(wday(trajectory_start) %in% 2:6) |>
  mutate(
    hour = hour(trajectory_start),
    time_period = case_when(
      hour >= 7 & hour < 10 ~ "Morning (7-10)",
      hour >= 17 & hour < 20 ~ "Evening (17-20)",
      TRUE ~ NA_character_
    )
  ) |>
  filter(!is.na(time_period)) |>
  count(origin, destination, time_period, name = "n_segments")


# Helper: single-panel flow map (geom_curve — matches the Track chapter qmd) ----

build_flow_map <- function(edges_df, flow_color = "#2c7bb6",
                           map_xlim = xlim, map_ylim = ylim,
                           width_breaks = NULL, label_sensors = TRUE) {

  # Join endpoint coordinates for geom_curve
  edges_plot <- edges_df |>
    left_join(sensor_coords |> select(sensor_name, X, Y),
              by = c("origin" = "sensor_name")) |>
    rename(x = X, y = Y) |>
    left_join(sensor_coords |> select(sensor_name, X, Y),
              by = c("destination" = "sensor_name")) |>
    rename(xend = X, yend = Y)

  # Pre-scaled widths so the grey casing sits outline_delta wider than the
  # colored flow; identity scale keeps the legend in real segment counts
  outline_delta <- 0.7
  rng <- range(edges_plot$n_segments)
  edges_plot <- edges_plot |>
    mutate(w_main = scales::rescale(n_segments, to = c(0.5, 3), from = rng),
           w_out  = w_main + outline_delta)
  if (is.null(width_breaks)) {
    width_breaks <- pretty(rng, n = 3)
    width_breaks <- width_breaks[width_breaks >= rng[1] & width_breaks <= rng[2]]
  }
  brk_w <- scales::rescale(width_breaks, to = c(0.5, 3), from = rng)

  od_sensors <- unique(c(edges_plot$origin, edges_plot$destination))
  sensor_labels <- sensor_coords |> filter(sensor_name %in% od_sensors)

  p <- ggplot() +
    # Basemap
    annotation_raster(base_map,
      xmin = bb$ll.lon, xmax = bb$ur.lon,
      ymin = bb$ll.lat, ymax = bb$ur.lat, interpolate = TRUE) +
    annotate("rect",
      xmin = bb$ll.lon, xmax = bb$ur.lon,
      ymin = bb$ll.lat, ymax = bb$ur.lat,
      fill = "white", alpha = 0.3) +
    # Grey casing under the colored flow separates it from the basemap
    geom_curve(data = edges_plot,
      aes(x = x, y = y, xend = xend, yend = yend, linewidth = w_out),
      arrow = arrow(length = unit(2.0, "mm"), type = "closed"),
      curvature = 0.3, color = "grey25", alpha = 1, show.legend = FALSE) +
    geom_curve(data = edges_plot,
      aes(x = x, y = y, xend = xend, yend = yend, linewidth = w_main),
      arrow = arrow(length = unit(1.5, "mm"), type = "closed"),
      curvature = 0.3, color = flow_color, alpha = 1) +
    scale_linewidth_identity(
      name   = "OD segments",
      breaks = brk_w,
      labels = scales::comma(width_breaks),
      guide  = guide_legend(override.aes = list(color = flow_color))) +
    # Non-OD nodes (grey), then OD nodes (double ring in the flow color)
    geom_point(data = sensor_coords, aes(x = X, y = Y),
      size = 2, color = "white", alpha = 0.6) +
    geom_point(data = sensor_coords, aes(x = X, y = Y),
      size = 1.5, color = "grey40", alpha = 0.6) +
    geom_point(data = sensor_labels, aes(x = X, y = Y),
      size = 2.5, color = "white") +
    geom_point(data = sensor_labels, aes(x = X, y = Y),
      size = 2, color = flow_color, alpha = 0.8) +
    # POI labels
    geom_text_repel(
      data = poi_coords, aes(x = X, y = Y, label = label),
      size = 2, fontface = "bold.italic", color = "gray10",
      bg.color = "white", bg.r = 0.15,
      lineheight = 0.85,
      box.padding = 0.4, point.padding = 0.2,
      segment.color = "gray80", segment.size = 0.2,
      min.segment.length = 0,
      alpha = 0.8,
      max.overlaps = 20, seed = 42, inherit.aes = FALSE) +
    coord_fixed(ratio = 1.23, xlim = map_xlim, ylim = map_ylim) +
    theme_bw() +
    theme(
      plot.tag   = element_text(face = "bold.italic", size = 11),
      plot.title = element_text(face = "bold", size = 11, hjust = 0.5),
      axis.title = element_blank(),
      axis.text  = element_blank(),
      axis.ticks = element_blank(),
      panel.grid = element_blank(),
      legend.position      = c(0.975, 0.02),
      legend.justification = c(1, 0),
      legend.background    = element_rect(color = "grey30", fill = "white",
                                          linewidth = 0.3),
      legend.title         = element_text(size = 7),
      legend.text          = element_text(size = 6),
      legend.key.width     = unit(0.8, "cm"),
      legend.key.height    = unit(0.45, "cm"),
      legend.margin        = margin(4, 6, 4, 6),
      plot.margin = margin(2, 4, 2, 4)
    )

  # Optional: sensor name labels for OD nodes
  if (label_sensors) {
    od_nodes <- sensor_labels |>
      mutate(label = str_replace_all(sensor_name, "_", "\n") |> str_wrap(width = 8))
    p <- p +
      geom_text_repel(
        data = od_nodes, aes(x = X, y = Y, label = label),
        size = 2.2, fontface = "bold.italic",
        color = "black", bg.color = "white", bg.r = 0.12,
        box.padding = 0.4, point.padding = 0.3,
        max.overlaps = 20, seed = 42, inherit.aes = FALSE)
  }

  p
}


# Visualizations ----

cat("\nGenerating visualizations...\n")

## Figure 1: Heatmap ----

cat("  Heatmap...\n")

p1 <- ggplot(od_probs, aes(x = destination, y = origin, fill = prob)) +
  geom_tile(color = "white") +
  geom_text(aes(label = ifelse(prob >= 0.1, sprintf("%.0f%%", prob * 100), "")),
            size = 2.5, color = "white") +
  scale_fill_gradient(low = "gray90", high = "#d7191c",
                      labels = scales::percent, name = "Probability") +
  labs(x = "Destination", y = "Origin") +
  theme_bw() +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1, size = 7),
    axis.text.y = element_text(size = 7),
    panel.grid = element_blank()
  )

ggsave(file.path(out_dir, "track_od_heatmap.png"),
       p1, width = 6, height = 6, dpi = 300, bg = "white")

## Figure 2: Top 5 Flow Map ----

cat("  Flow map (top 5)...\n")

edges_top5 <- od_probs |> slice_max(n_segments, n = 5)

write_csv(
  edges_top5 |> select(origin, destination, n_segments, prob) |> arrange(desc(n_segments)),
  file.path(out_dir, "track_od_top5.csv"))

p2 <- build_flow_map(edges_top5, width_breaks = c(1500, 2000, 2500),
                     label_sensors = TRUE)

ggsave(file.path(out_dir, "track_od_map.png"),
       p2, width = 5, height = 6, dpi = 300)

## Helper: faceted comparison map (matches count.R styling) ----

build_comparison_map <- function(edges_df, facet_var, colors,
                                 width_breaks = NULL) {
  edges_plot <- edges_df |>
    left_join(sensor_coords |> select(sensor_name, X, Y),
              by = c("origin" = "sensor_name")) |>
    rename(x = X, y = Y) |>
    left_join(sensor_coords |> select(sensor_name, X, Y),
              by = c("destination" = "sensor_name")) |>
    rename(xend = X, yend = Y)

  # Global width scale across both facets: panel-to-panel volume differences
  # stay visible; identity scale keeps the legend in real segment counts
  outline_delta <- 0.7
  rng <- range(edges_plot$n_segments)
  edges_plot <- edges_plot |>
    mutate(w_main = scales::rescale(n_segments, to = c(0.5, 3), from = rng),
           w_out  = w_main + outline_delta)
  if (is.null(width_breaks)) {
    width_breaks <- pretty(rng, n = 3)
    width_breaks <- width_breaks[width_breaks >= rng[1] & width_breaks <= rng[2]]
  }
  brk_w <- scales::rescale(width_breaks, to = c(0.5, 3), from = rng)

  ggplot() +
    annotation_raster(base_map,
      xmin = bb$ll.lon, xmax = bb$ur.lon,
      ymin = bb$ll.lat, ymax = bb$ur.lat, interpolate = TRUE) +
    annotate("rect",
      xmin = bb$ll.lon, xmax = bb$ur.lon,
      ymin = bb$ll.lat, ymax = bb$ur.lat,
      fill = "white", alpha = 0.3) +
    # Grey casing under the colored flow separates it from the basemap
    geom_curve(data = edges_plot,
      aes(x = x, y = y, xend = xend, yend = yend, linewidth = w_out),
      arrow = arrow(length = unit(2.0, "mm"), type = "closed"),
      curvature = 0.3, color = "grey25", alpha = 1,
      show.legend = FALSE) +
    geom_curve(data = edges_plot,
      aes(x = x, y = y, xend = xend, yend = yend,
          linewidth = w_main, color = .data[[facet_var]]),
      arrow = arrow(length = unit(1.5, "mm"), type = "closed"),
      curvature = 0.3, alpha = 1) +
    scale_linewidth_identity(
      name   = "OD segments",
      breaks = brk_w,
      labels = scales::comma(width_breaks),
      guide  = guide_legend(
        override.aes = list(color = "grey40"))) +
    scale_color_manual(values = colors, guide = "none") +
    geom_point(data = sensor_coords, aes(x = X, y = Y),
      size = 2, color = "white", alpha = 0.6) +
    geom_point(data = sensor_coords, aes(x = X, y = Y),
      size = 1.5, color = "grey40", alpha = 0.6) +
    geom_text_repel(
      data = poi_coords, aes(x = X, y = Y, label = label),
      size = 2, fontface = "bold.italic", color = "gray10",
      bg.color = "white", bg.r = 0.15,
      lineheight = 0.85,
      box.padding = 0.4, point.padding = 0.2,
      segment.color = "gray80", segment.size = 0.2,
      min.segment.length = 0,
      alpha = 0.8,
      max.overlaps = 20, inherit.aes = FALSE) +
    facet_wrap(as.formula(paste("~", facet_var)), ncol = 2) +
    coord_fixed(ratio = 1.23, xlim = xlim, ylim = ylim) +
    theme_bw() +
    theme(
      axis.title = element_blank(),
      axis.text  = element_blank(),
      axis.ticks = element_blank(),
      strip.text = element_text(size = 11, face = "bold"),
      strip.background = element_rect(fill = "gray90", color = NA),
      panel.spacing = unit(0.5, "lines"),
      panel.grid = element_blank(),
      legend.position   = "bottom",
      legend.title      = element_text(size = 8),
      legend.text       = element_text(size = 7),
      legend.key.width  = unit(0.9, "cm"),
      legend.key.height = unit(0.45, "cm"),
      legend.margin     = margin(0, 6, 2, 6)
    )
}

## Figure 3: Weekday vs Weekend ----

cat("  Weekday vs Weekend...\n")

edges_wk <- od_by_daytype |> filter(day_type == "Weekday") |>
  slice_max(n_segments, n = top_n_flows)
edges_we <- od_by_daytype |> filter(day_type == "Weekend") |>
  slice_max(n_segments, n = top_n_flows)

write_csv(
  od_by_daytype |>
    group_by(day_type) |> slice_max(n_segments, n = top_n_flows) |>
    arrange(day_type, desc(n_segments)),
  file.path(out_dir, "track_od_daytype.csv"))

p3 <- build_comparison_map(
  bind_rows(edges_wk, edges_we) |>
    mutate(day_type = factor(day_type, levels = c("Weekday", "Weekend"))),
  "day_type",
  c("Weekday" = col_weekday, "Weekend" = col_weekend)
)

ggsave(file.path(out_dir, "track_od_weekday_weekend.png"),
       p3, width = 6, height = 5, dpi = 300)

## Figure 4: Morning vs Evening ----

cat("  Morning vs Evening...\n")

edges_am <- od_time_period |> filter(time_period == "Morning (7-10)") |>
  slice_max(n_segments, n = top_n_flows)
edges_pm <- od_time_period |> filter(time_period == "Evening (17-20)") |>
  slice_max(n_segments, n = top_n_flows)

write_csv(
  od_time_period |>
    group_by(time_period) |> slice_max(n_segments, n = top_n_flows) |>
    arrange(time_period, desc(n_segments)),
  file.path(out_dir, "track_od_timeperiod.csv"))

p4 <- build_comparison_map(
  bind_rows(edges_am, edges_pm) |>
    mutate(time_period = factor(time_period,
      levels = c("Morning (7-10)", "Evening (17-20)"))),
  "time_period",
  c("Morning (7-10)" = col_weekday, "Evening (17-20)" = col_weekend)
)

ggsave(file.path(out_dir, "track_od_morning_evening.png"),
       p4, width = 6, height = 5, dpi = 300)

# Copy figures to docs ----

fig_files <- list.files(out_dir, pattern = "^track_.*\\.png$", full.names = TRUE)
for (f in fig_files) {
  file.copy(f, file.path(fig_dir, basename(f)), overwrite = TRUE)
}
cat("\nCopied", length(fig_files), "figures to", fig_dir, "\n")

# Summary ----

cat("\n=== Track Analysis Summary ===\n")
cat("Data period:", as.character(min(wifi_raw$timestamp)), "to",
    as.character(max(wifi_raw$timestamp)), "\n")
cat("Total observations:", format(nrow(wifi_raw), big.mark = ","), "\n")
cat("OD segments:", format(nrow(od_pairs), big.mark = ","), "\n")
cat("Unique retained identifiers:",
    format(n_distinct(od_pairs$source_address), big.mark = ","), "\n\n")

cat("Top 5 OD pairs:\n")
od_probs |> arrange(desc(n_segments)) |> head(5) |> print()

cat("\nOutput saved to:", out_dir, "\n")
cat("Figures copied to:", fig_dir, "\n")
