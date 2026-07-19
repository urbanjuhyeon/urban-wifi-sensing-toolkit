# Figure 2: Count + Track (UNIST campus, 26-day)
#
# a) Per-sensor count map — size = devices, fill = weekend/weekday ratio
# b) Top OD flows — weekday (orange) + weekend (cyan)
#
# Input:  workflow/unist19_main/data/{wifi_unist19_20sec.parquet, sensors.gpkg, poi.gpkg}
# Output: manuscript/figures/{fig_count_track.png, fig2a_*.csv, fig2b_*.csv}

# Setup ----
pacman::p_load(
  tidyverse, lubridate, data.table, arrow, sf,
  ggmap, ggrepel, tidygraph, ggraph, patchwork
)

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

data_dir <- file.path(base_dir, "workflow/unist19_main/data")
fig_dir  <- file.path(base_dir, "manuscript/figures")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

api_key_file <- file.path(base_dir, ".google_api_key")
if (file.exists(api_key_file)) {
  register_google(key = readLines(api_key_file, warn = FALSE))
}

gap_minutes    <- 30
top_n_flows    <- 7
col_weekday    <- "#FF8C00"
col_weekend    <- "#00CED1"
col_casing     <- "grey25"           # flow arrow casing (panel b)
col_rim        <- "grey15"           # count circle rims (panel a), one step darker
exclude_sensors <- c("comm_center")  # ping-pong artifact
crop_adj       <- 0.001              # panel b) vertical crop (increase to crop more)

# Prep ----

## Load ----
cat("Loading data...\n")
wifi_raw <- read_parquet(file.path(data_dir, "wifi_unist19_20sec.parquet"))
sensors  <- st_read(file.path(data_dir, "sensors.gpkg"), quiet = TRUE)
poi      <- st_read(file.path(data_dir, "poi.gpkg"), quiet = TRUE)

required_cols <- c(
  "timestamp", "source_address", "sensor_name", "rssi_median",
  "rssi_sum", "detections"
)
if (!all(required_cols %in% names(wifi_raw))) {
  stop("The standardized 20-second input is missing required columns")
}
if (!"strength_sum" %in% names(wifi_raw)) {
  # The public release ships without strength_sum; restore the localization score
  wifi_raw$strength_sum <- 100 * wifi_raw$detections + wifi_raw$rssi_sum
} else if (any(wifi_raw$strength_sum != 100 * wifi_raw$detections + wifi_raw$rssi_sum)) {
  stop("strength_sum invariant failed")
}

cat("  Rows:", format(nrow(wifi_raw), big.mark = ","), "\n")
cat("  Period:", as.character(min(wifi_raw$timestamp)), "to",
    as.character(max(wifi_raw$timestamp)), "\n")
cat("  Devices:", format(n_distinct(wifi_raw$source_address), big.mark = ","), "\n")
cat("  Sensors:", nrow(sensors), "\n")

wifi_raw <- wifi_raw |> filter(!sensor_name %in% exclude_sensors)
sensors  <- sensors |> filter(!sensor_name %in% exclude_sensors)
cat("  After excluding", paste(exclude_sensors, collapse = ", "), ":",
    nrow(sensors), "sensors,", format(nrow(wifi_raw), big.mark = ","), "rows\n")

sensor_coords <- sensors |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(sensors |> st_drop_geometry() |> select(sensor_name)) |>
  mutate(node_id = row_number())

name_to_id <- setNames(sensor_coords$node_id, sensor_coords$sensor_name)

poi_coords <- poi |>
  st_centroid() |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(poi |> st_drop_geometry() |> select(name)) |>
  mutate(label = case_when(
    name == "Engineering Bldg." ~ "Engineering\nBldg.",
    name == "Bus Station"       ~ "Bus Stn.",
    name == "Off-campus shops"  ~ "Amenities",
    TRUE ~ name
  ))

## Street overlay ----

street_ground_w <- c(
  motorway = 12, trunk = 12, primary = 12, secondary = 10, tertiary = 8,
  unclassified = 6, residential = 6, living_street = 6, service = 4,
  pedestrian = 5, footway = 2, path = 2, cycleway = 2, track = 2, steps = 1.5
)

streets <- st_read(
  file.path(base_dir, "workflow/figS4/streets_5sites.gpkg"),
  layer = "streets", quiet = TRUE
) |>
  filter(site == "unist19")

street_poly <- local({
  d <- st_transform(streets, 32652)
  if (!"gw" %in% names(d)) d$gw <- street_ground_w[d$highway]
  # Preserve feature-level gw while enforcing a legible cartographic minimum
  # for narrow campus footways at the final manuscript figure size.
  u <- st_union(st_buffer(d, dist = pmax(d$gw, 5.5) / 2))
  st_cast(st_transform(u, 4326), "MULTIPOLYGON")
})

street_poly_df <- as.data.frame(st_coordinates(street_poly)) |>
  mutate(group = paste(L3, L2, sep = "."), subgroup = L1)

street_layer <- geom_polygon(
  data = street_poly_df,
  aes(X, Y, group = group, subgroup = subgroup),
  fill = alpha("white", 0.40),
  color = alpha("grey20", 0.35), linewidth = 0.25,
  inherit.aes = FALSE
)

## Count ----
cat("\nComputing count metrics (midday 11-14h)...\n")

midday <- wifi_raw |>
  mutate(
    date        = as.Date(timestamp),
    day_type    = if_else(wday(timestamp) %in% c(1, 7), "Weekend", "Weekday"),
    hour_of_day = hour(timestamp)
  ) |>
  filter(hour_of_day >= 11 & hour_of_day <= 14)

# Circle size: unique addresses over the whole period (union — pooling
# weekday and weekend uniques would double-count addresses seen in both)
sensor_total <- midday |>
  group_by(sensor_name) |>
  summarise(total = n_distinct(source_address), .groups = "drop")

# Fill: weekend/weekday ratio of mean daily unique addresses
# (20 weekdays vs 6 weekend days — pooled uniques would confound day counts)
sensor_daily <- midday |>
  group_by(sensor_name, day_type, date) |>
  summarise(n_daily = n_distinct(source_address), .groups = "drop") |>
  group_by(sensor_name, day_type) |>
  summarise(mean_daily = mean(n_daily), .groups = "drop") |>
  pivot_wider(names_from = day_type, values_from = mean_daily) |>
  mutate(ratio = Weekend / Weekday)

sensor_ratio <- sensor_total |> left_join(sensor_daily, by = "sensor_name")

cat("  Ratio range:", round(min(sensor_ratio$ratio), 2), "to",
    round(max(sensor_ratio$ratio), 2), "\n")

sensors_plot <- sensors |>
  left_join(sensor_ratio, by = "sensor_name") |>
  filter(!is.na(total))

sensors_xy <- sensor_coords |>
  left_join(sensor_ratio, by = "sensor_name") |>
  filter(!is.na(total))

## Trip ----
cat("\nComputing track metrics...\n")

wifi_loc <- as.data.table(wifi_raw)
# Exact strength ties are resolved by sensor identifier so results do not
# depend on Parquet row order.
setorder(wifi_loc, source_address, timestamp, -strength_sum, sensor_name)
wifi_loc <- wifi_loc[, head(.SD, 1), by = .(source_address, timestamp)]
wifi_loc <- wifi_loc[, .(source_address, timestamp, sensor_name)]
cat("  Localized rows:", format(nrow(wifi_loc), big.mark = ","), "\n")

setkey(wifi_loc, source_address, timestamp)
wifi_loc[,
  time_gap := as.numeric(difftime(timestamp, shift(timestamp), units = "mins")),
  by = source_address
]
wifi_loc[,
  trip_id := cumsum(is.na(time_gap) | time_gap > gap_minutes),
  by = source_address
]

od_pairs <- wifi_loc[, .(
  origin       = sensor_name[1L],
  destination  = sensor_name[.N],
  trip_start   = timestamp[1L],
  n_detections = .N
), by = .(source_address, trip_id)]

od_pairs <- od_pairs[origin != destination & n_detections >= 2L]
cat("  Total OD pairs:", format(nrow(od_pairs), big.mark = ","), "\n")

# Per-day normalization context: 20 weekdays vs 6 weekend days
dates <- unique(as.Date(wifi_loc$timestamp))
day_counts <- data.table(date = dates)[
  , .(n_days = .N),
  by = .(day_type = fifelse(wday(date) %in% c(1, 7), "Weekend", "Weekday"))
]

od_totals <- od_pairs |>
  as_tibble() |>
  mutate(day_type = if_else(wday(trip_start) %in% c(1, 7), "Weekend", "Weekday")) |>
  count(day_type, name = "n_trips") |>
  left_join(as_tibble(day_counts), by = "day_type") |>
  mutate(trips_per_day = round(n_trips / n_days, 1))

cat("  Trips by day type:\n")
print(od_totals)
cat("  Weekend/weekday ratio: pooled",
    round(od_totals$n_trips[od_totals$day_type == "Weekend"] /
          od_totals$n_trips[od_totals$day_type == "Weekday"], 3),
    "| per-day",
    round(od_totals$trips_per_day[od_totals$day_type == "Weekend"] /
          od_totals$trips_per_day[od_totals$day_type == "Weekday"], 3), "\n")

od_by_daytype <- od_pairs |>
  as_tibble() |>
  mutate(day_type = if_else(wday(trip_start) %in% c(1, 7), "Weekend", "Weekday")) |>
  count(origin, destination, day_type, name = "n_trips")

edges_wk <- od_by_daytype |>
  filter(day_type == "Weekday") |>
  slice_max(n_trips, n = top_n_flows)

edges_we <- od_by_daytype |>
  filter(day_type == "Weekend") |>
  slice_max(n_trips, n = top_n_flows)

cat("  Weekday top", top_n_flows, "flows (max:", max(edges_wk$n_trips), ")\n")
cat("  Weekend top", top_n_flows, "flows (max:", max(edges_we$n_trips), ")\n")

# Plot ----

## Base ----
bbox <- st_bbox(sensors)
pad  <- 0.002

base_map <- get_map(
  location = c(
    lon = (bbox["xmin"] + bbox["xmax"]) / 2,
    lat = (bbox["ymin"] + bbox["ymax"]) / 2
  ),
  zoom = 16, maptype = "satellite", source = "google", color = "bw"
)

bb       <- attr(base_map, "bb")
xlim_a   <- c(bbox["xmin"] - pad, bbox["xmax"] + pad)
xlim_b   <- c(xlim_a[1] + diff(xlim_a) * 0.15, xlim_a[2] - diff(xlim_a) * 0.05)
ylim_raw <- c(bbox["ymin"] - pad * 1.25, bbox["ymax"] + pad * 1.25)
ylim_common <- c(
  max(ylim_raw[1], bb$ll.lat) + crop_adj,
  min(ylim_raw[2], bb$ur.lat) - crop_adj
)

## Count ----
leg_bg <- element_rect(color = "grey30", fill = "white", linewidth = 0.3)

pa <- ggplot() +
  annotation_raster(
    base_map,
    xmin = bb$ll.lon, xmax = bb$ur.lon,
    ymin = bb$ll.lat, ymax = bb$ur.lat,
    interpolate = TRUE
  ) +
  annotate("rect",
    xmin = bb$ll.lon, xmax = bb$ur.lon,
    ymin = bb$ll.lat, ymax = bb$ur.lat,
    fill = "white", alpha = 0.3
  ) +
  street_layer +
  geom_point(
    data = sensors_xy,
    aes(x = X, y = Y, size = total, fill = ratio * 100),
    shape = 21, color = col_rim, stroke = 0.5,
    alpha = 0.90
  ) +
  scale_size_continuous(
    range  = c(1.5, 7),
    name   = "Unique MAC\naddresses",
    breaks = c(2000, 6000, 10000),
    labels = scales::comma
  ) +
  scale_fill_gradient2(
    low      = col_weekday,
    mid      = "grey90",
    high     = col_weekend,
    midpoint = 50,
    limits   = c(30, 100),
    breaks   = c(30, 50, 70, 100),
    name     = "Weekend activity\n(% of weekday level)"
  ) +
  guides(
    fill = guide_colorbar(
      direction = "horizontal", title.position = "top",
      barwidth = unit(2, "cm"), barheight = unit(0.2, "cm"),
      position = "inside",
      theme = theme(
        legend.position.inside = c(0.785, 0.925),
        legend.justification = c(1, 1),
        legend.background = leg_bg,
        legend.margin = margin(3, 6, 3, 6),
        legend.title = element_text(size = 6),
        legend.text  = element_text(size = 5, margin = margin(t = 2.5))
      )
    ),
    size = guide_legend(
      override.aes = list(fill = "grey50", color = col_rim),
      position = "inside",
      theme = theme(
        legend.position.inside = c(0.82, 0.135),
        legend.justification = c(1, 0),
        legend.background = leg_bg,
        legend.margin = margin(4, 6, 4, 6),
        legend.title = element_text(size = 7),
        legend.text  = element_text(size = 6),
        legend.key.size = unit(0.3, "cm")
      )
    )
  ) +
  geom_text_repel(
    data = poi_coords, aes(x = X, y = Y, label = label),
    size = 2.1, fontface = "bold.italic", color = "grey25",
    bg.color = "white", bg.r = 0.15,
    force = 0, max.overlaps = Inf,
    seed = 42, inherit.aes = FALSE
  ) +
  # Scale bar (100 m) — bottom-left
  annotate("rect",
    xmin = xlim_a[1] + pad * 0.01,
    xmax = xlim_a[1] + pad * 0.08 + 0.0011 + pad * 0.055,
    ymin = ylim_common[1] + pad * 0.01,
    ymax = ylim_common[1] + pad * 0.33,
    fill = alpha("black", 0.35)
  ) +
  annotate("segment",
    x    = xlim_a[1] + pad * 0.08,
    xend = xlim_a[1] + pad * 0.08 + 0.0011,
    y    = ylim_common[1] + pad * 0.24,
    yend = ylim_common[1] + pad * 0.24,
    linewidth = 0.3, color = "white"
  ) +
  annotate("text",
    x     = xlim_a[1] + pad * 0.08 + 0.0011 / 2,
    y     = ylim_common[1] + pad * 0.11,
    label = "100 m",
    size  = 2, color = "white"
  ) +
  coord_cartesian(xlim = xlim_a, ylim = ylim_common, expand = FALSE) +
  labs(tag = "a)") +
  theme_bw() +
  theme(
    plot.tag    = element_text(face = "bold.italic", size = 13),
    axis.title  = element_blank(),
    axis.text   = element_blank(),
    axis.ticks  = element_blank(),
    panel.grid  = element_blank(),
    plot.margin = margin(2, 2, 2, 2)
  )

## Trip ----
cat("\nBuilding flow maps...\n")

poi_coords_b <- poi_coords |>
  filter(!name %in% c("Off-campus shops", "Library"))

build_flow_map <- function(edges_df, flow_color, tag_label = NULL,
                           day_label = NULL, width_breaks = NULL) {

  # Pre-scaled widths so the casing layer can sit outline_delta wider than
  # the flow layer (a single mapped width scale cannot express both)
  outline_delta <- 0.7
  rng <- range(edges_df$n_trips)
  edges_df <- edges_df |>
    mutate(w_main = scales::rescale(n_trips, to = c(0.5, 3), from = rng),
           w_out  = w_main + outline_delta)
  brk_w <- scales::rescale(width_breaks, to = c(0.5, 3), from = rng)

  od_sensors <- unique(c(edges_df$origin, edges_df$destination))

  nodes_df <- sensor_coords |>
    mutate(in_od = sensor_name %in% od_sensors)

  edges_graph <- edges_df |>
    mutate(from = name_to_id[origin], to = name_to_id[destination]) |>
    filter(!is.na(from), !is.na(to))

  graph <- tbl_graph(nodes = nodes_df, edges = edges_graph, directed = TRUE)
  node_size <- 2

  p <- ggraph(graph, layout = "manual", x = nodes_df$X, y = nodes_df$Y) +
    annotation_raster(
      base_map,
      xmin = bb$ll.lon, xmax = bb$ur.lon,
      ymin = bb$ll.lat, ymax = bb$ur.lat,
      interpolate = TRUE
    ) +
    annotate("rect",
      xmin = bb$ll.lon, xmax = bb$ur.lon,
      ymin = bb$ll.lat, ymax = bb$ur.lat,
      fill = "white", alpha = 0.3
    ) +
    street_layer +
    geom_edge_arc(
      aes(edge_width = w_out),
      arrow     = arrow(length = unit(2.0, "mm"), type = "closed"),
      start_cap = circle(node_size, "mm"),
      end_cap   = circle(node_size + 0.5, "mm"),
      strength  = 0.3,
      color     = col_casing,
      alpha     = 1,
      show.legend = FALSE
    ) +
    geom_edge_arc(
      aes(edge_width = w_main),
      arrow     = arrow(length = unit(1.5, "mm"), type = "closed"),
      start_cap = circle(node_size, "mm"),
      end_cap   = circle(node_size + 0.5, "mm"),
      strength  = 0.3,
      color     = flow_color,
      alpha     = 1
    ) +
    scale_edge_width_identity(
      name   = day_label %||% "Trips",
      breaks = brk_w,
      labels = scales::comma(width_breaks),
      guide  = guide_legend(
        override.aes = list(edge_colour = flow_color, edge_alpha = 1))
    ) +
    geom_node_point(aes(filter = !in_od),
      size = node_size, color = "white", alpha = 0.6) +
    geom_node_point(aes(filter = !in_od),
      size = node_size - 0.5, color = "grey40", alpha = 0.6) +
    geom_node_point(aes(filter = in_od),
      size = node_size, color = "white") +
    geom_node_point(aes(filter = in_od),
      size = node_size - 0.5, color = flow_color, alpha = 0.8) +
    geom_text_repel(
      data = poi_coords_b, aes(x = X, y = Y, label = label),
      size = 2.1, fontface = "bold.italic", color = "grey25",
      bg.color = "white", bg.r = 0.15,
      force = 0, max.overlaps = Inf,
      seed = 42, inherit.aes = FALSE
    ) +
    coord_cartesian(xlim = xlim_b, ylim = ylim_common, expand = FALSE) +
    theme_bw() +
    theme(
      axis.title           = element_blank(),
      axis.text            = element_blank(),
      axis.ticks           = element_blank(),
      panel.grid           = element_blank(),
      panel.border         = element_rect(color = "grey30", linewidth = 0.5),
      plot.tag             = element_text(face = "bold.italic", size = 13),
      legend.position      = c(0.975, 0.018),
      legend.justification = c(1, 0),
      legend.background    = element_rect(color = "grey30", fill = "white",
                                           linewidth = 0.3),
      legend.title         = element_text(size = 7),
      legend.text          = element_text(size = 6),
      legend.key.width     = unit(0.8, "cm"),
      legend.key.height    = unit(0.45, "cm"),
      legend.margin        = margin(4, 6, 4, 6),
      plot.margin          = margin(2, 4, 2, 4)
    )

  if (!is.null(tag_label)) p <- p + labs(tag = tag_label)
  p
}

pb_wk <- build_flow_map(edges_wk, col_weekday,
                         tag_label = "b)", day_label = "Weekday",
                         width_breaks = c(3500, 5000, 7000))
pb_we <- build_flow_map(edges_we, col_weekend,
                         day_label = "Weekend",
                         width_breaks = c(700, 1000, 1500))

## Export ----
cat("\nCombining panels...\n")

fig2 <- pa + pb_wk + pb_we + plot_layout(widths = c(1.25, 1, 1))

out_file <- file.path(fig_dir, "fig_count_track.png")
ggsave(out_file, fig2, width = 7.2, height = 4.5, dpi = 300, bg = "white")
cat("Figure saved:", out_file, "\n")

write_csv(sensor_ratio, file.path(fig_dir, "fig2a_count_sensor.csv"))
write_csv(od_totals, file.path(fig_dir, "fig2b_track_totals.csv"))
write_csv(
  bind_rows(edges_wk, edges_we) |> arrange(day_type, desc(n_trips)),
  file.path(fig_dir, "fig2b_track_od.csv")
)
cat("CSVs saved to:", fig_dir, "\n")
