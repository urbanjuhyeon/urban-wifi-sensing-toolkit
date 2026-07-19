# Appendix A: Deployment Maps
#
# a) UNIST campus — 25 outdoor sensors, Oct-Nov 2019
# b) Commercial district near University of Ulsan — 17 sensors, Jul 2020
#
# Input:  workflow/unist19_main/data/{sensors.gpkg, poi.gpkg}
#         workflow/uou20/output/sensors_coords.csv
#         workflow/uou20/data/poi_uou.gpkg
#
# Output: docs/materials/appendix/fig_deployment.png

# Setup ----

pacman::p_load(tidyverse, sf, ggmap, ggrepel, patchwork)

base_dir <- normalizePath(file.path(dirname(
  rstudioapi::getSourceEditorContext()$path), ".."), winslash = "/")

out_dir <- file.path(base_dir, "docs/materials/appendix")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

api_key_file <- file.path(base_dir, ".google_api_key")
if (file.exists(api_key_file)) {
  register_google(key = readLines(api_key_file, warn = FALSE))
}


# Load Data ----

## UNIST campus ----
sensors_unist <- st_read(
  file.path(base_dir, "workflow/unist19_main/data/sensors.gpkg"), quiet = TRUE
) |> filter(sensor_name != "comm_center")

poi_unist <- st_read(
  file.path(base_dir, "workflow/unist19_main/data/poi.gpkg"), quiet = TRUE
)

unist_coords <- sensors_unist |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(sensors_unist |> st_drop_geometry() |> select(sensor_name))

poi_unist_coords <- poi_unist |>
  st_centroid() |>
  st_coordinates() |>
  as_tibble() |>
  bind_cols(poi_unist |> st_drop_geometry() |> select(name)) |>
  mutate(label = case_when(
    name == "Engineering Bldg." ~ "Engineering\nBldg.",
    name == "Bus Station"       ~ "Bus Stn.",
    name == "Off-campus shops"  ~ "Amenities",
    TRUE ~ name
  ))

## Commercial district ----
sensors_uou <- read_csv(
  file.path(base_dir, "workflow/uou20/output/sensors_coords.csv"),
  show_col_types = FALSE
)

sensors_uou <- sensors_uou |>
  transmute(
    sensor_name = id_sensor,
    street_type = case_match(
      street_type,
      "Pedestrian" ~ "Ped-priority",
      "Regular"    ~ "Conventional"
    ),
    x, y
  )

# Bus stops
poi_file <- file.path(base_dir, "workflow/uou20/data/poi_uou.gpkg")
has_bus_stops <- file.exists(poi_file)
if (has_bus_stops) {
  bus_stops <- st_read(poi_file, quiet = TRUE) |> st_transform(4326)
  bus_coords <- as.data.frame(st_coordinates(bus_stops)) |> rename(x = X, y = Y)
}

cat("UNIST sensors:", nrow(unist_coords), "\n")
cat("UoU sensors:", nrow(sensors_uou), "\n")


# Basemaps ----

bbox_unist <- st_bbox(sensors_unist)
map_unist <- get_map(
  location = c(
    lon = (bbox_unist["xmin"] + bbox_unist["xmax"]) / 2,
    lat = (bbox_unist["ymin"] + bbox_unist["ymax"]) / 2
  ),
  zoom = 16, maptype = "satellite", source = "google", color = "bw"
)

map_uou <- get_map(
  location = c(lon = mean(sensors_uou$x), lat = mean(sensors_uou$y)),
  zoom = 17, maptype = "satellite", source = "google", color = "bw"
)


# Plot ----

sensor_color <- "#FF5722"  # deep orange — visible on BW satellite

# Panel a) UNIST campus ----

pad_a <- 0.002
bb_a  <- attr(map_unist, "bb")
xlim_a <- c(bbox_unist["xmin"] - pad_a, bbox_unist["xmax"] + pad_a)
ylim_a <- c(
  max(bbox_unist["ymin"] - pad_a * 1.25, bb_a$ll.lat) + 0.001,
  min(bbox_unist["ymax"] + pad_a * 1.25, bb_a$ur.lat) - 0.001
)

pa <- ggmap(map_unist, darken = c(0.3, "white")) +
  geom_point(
    data = unist_coords,
    aes(x = X, y = Y),
    shape = 21, size = 3, fill = sensor_color, color = "white", stroke = 0.6,
    inherit.aes = FALSE
  ) +
  geom_text_repel(
    data = bind_rows(
      unist_coords |> transmute(X, Y, label = sensor_name, type = "sensor"),
      poi_unist_coords |> transmute(X, Y, label, type = "poi")
    ),
    aes(x = X, y = Y, label = label, size = type, fontface = type, color = type),
    bg.color = "grey20", bg.r = 0.12,
    box.padding = 0.3, point.padding = 0.2,
    max.overlaps = 30, seed = 42, inherit.aes = FALSE
  ) +
  scale_size_manual(values = c("sensor" = 1.8, "poi" = 2.2), guide = "none") +
  scale_discrete_manual("fontface", values = c("sensor" = "bold", "poi" = "bold.italic"), guide = "none") +
  scale_color_manual(values = c("sensor" = "white", "poi" = "#64B5F6"), guide = "none") +
  # Scale bar (100 m)
  annotate("rect",
    xmin = xlim_a[1] + pad_a * 0.01,
    xmax = xlim_a[1] + pad_a * 0.08 + 0.0011 + pad_a * 0.055,
    ymin = ylim_a[1] + pad_a * 0.01,
    ymax = ylim_a[1] + pad_a * 0.33,
    fill = alpha("black", 0.35)
  ) +
  annotate("segment",
    x    = xlim_a[1] + pad_a * 0.08,
    xend = xlim_a[1] + pad_a * 0.08 + 0.0011,
    y    = ylim_a[1] + pad_a * 0.24,
    yend = ylim_a[1] + pad_a * 0.24,
    linewidth = 0.3, color = "white"
  ) +
  annotate("text",
    x     = xlim_a[1] + pad_a * 0.08 + 0.0011 / 2,
    y     = ylim_a[1] + pad_a * 0.11,
    label = "100 m", size = 2, color = "white"
  ) +
  coord_sf(crs = 4326,
           xlim = xlim_a, ylim = ylim_a) +
  labs(title = "UNIST campus") +
  theme_void() +
  theme(
    plot.title  = element_text(size = 10, face = "bold"),
    panel.border = element_rect(colour = "grey50", fill = NA, linewidth = 0.4),
    plot.margin = margin(2, 4, 2, 2)
  )


# Panel b) Commercial district ----

pad_b <- 0.0008

# Ped-priority street lines
ped_main <- sensors_uou |>
  filter(sensor_name %in% c("u02", "u04", "u06", "u09", "u11", "u13", "u15")) |>
  arrange(desc(y))

ped_branch <- sensors_uou |>
  filter(sensor_name %in% c("u03", "u04")) |>
  arrange(desc(y))

pb <- ggmap(map_uou, darken = c(0.4, "white")) +
  geom_path(data = ped_main, aes(x = x, y = y, color = "Ped-priority street"),
            linewidth = 2.5, alpha = 0.5, inherit.aes = FALSE) +
  geom_path(data = ped_branch, aes(x = x, y = y, color = "Ped-priority street"),
            linewidth = 2.5, alpha = 0.5, show.legend = FALSE, inherit.aes = FALSE) +
  geom_point(
    data = sensors_uou,
    aes(x = x, y = y),
    shape = 21, size = 3, fill = sensor_color, color = "white", stroke = 0.6,
    inherit.aes = FALSE
  ) +
  geom_text_repel(
    data = sensors_uou,
    aes(x = x, y = y, label = sensor_name),
    size = 2.2, fontface = "bold", color = "white",
    bg.color = "grey20", bg.r = 0.12,
    box.padding = 0.3, point.padding = 0.2,
    max.overlaps = 20, seed = 42, inherit.aes = FALSE
  ) +
  scale_color_manual(values = c("Ped-priority street" = "#2979FF"), name = NULL) +
  guides(
    color = guide_legend(
      override.aes = list(linewidth = 2, alpha = 0.7),
      position = "inside",
      theme = theme(
        legend.position.inside = c(0.98, 0.02),
        legend.justification = c(1, 0),
        legend.background = element_rect(fill = alpha("black", 0.4), color = NA),
        legend.text = element_text(size = 7, color = "white"),
        legend.key = element_rect(fill = NA),
        legend.margin = margin(4, 6, 4, 6)
      )
    )
  ) +
  # Scale bar (50 m)
  annotate("rect",
    xmin = min(sensors_uou$x) - pad_b * 1.05,
    xmax = min(sensors_uou$x) - pad_b * 0.85 + 0.00055 + pad_b * 0.2,
    ymin = min(sensors_uou$y) - pad_b * 0.68,
    ymax = min(sensors_uou$y) - pad_b * 0.15,
    fill = alpha("black", 0.35)
  ) +
  annotate("segment",
    x    = min(sensors_uou$x) - pad_b * 0.85,
    xend = min(sensors_uou$x) - pad_b * 0.85 + 0.00055,
    y    = min(sensors_uou$y) - pad_b * 0.35,
    yend = min(sensors_uou$y) - pad_b * 0.35,
    linewidth = 0.8, color = "white"
  ) +
  annotate("text",
    x     = min(sensors_uou$x) - pad_b * 0.85 + 0.00055 / 2,
    y     = min(sensors_uou$y) - pad_b * 0.52,
    label = "50 m", size = 2, color = "white", fontface = "bold"
  ) +
  coord_sf(crs = 4326,
           xlim = c(min(sensors_uou$x) - pad_b, max(sensors_uou$x) + pad_b),
           ylim = c(min(sensors_uou$y) - pad_b * 0.6, max(sensors_uou$y) + pad_b * 0.6)) +
  labs(title = "Commercial district near University of Ulsan") +
  theme_void() +
  theme(
    plot.title   = element_text(size = 10, face = "bold"),
    panel.border = element_rect(colour = "grey50", fill = NA, linewidth = 0.4),
    plot.margin  = margin(2, 2, 2, 4)
  )

# Conditional bus stop layer
if (has_bus_stops) {
  pb <- pb +
    geom_point(data = bus_coords, aes(x = x, y = y),
               shape = 22, size = 3.5, fill = alpha("#1565C0", 0.75),
               color = "white", stroke = 0.4, inherit.aes = FALSE) +
    geom_text(data = bus_coords, aes(x = x, y = y, label = "B"),
              size = 1.8, fontface = "bold", color = "white",
              inherit.aes = FALSE)
}


# Combine & Export ----

fig <- pa + pb + plot_layout(widths = c(1, 1))

out_file <- file.path(out_dir, "fig_deployment.png")
ggsave(out_file, fig, width = 11, height = 5, dpi = 300, bg = "white")
cat("Saved:", out_file, "\n")
