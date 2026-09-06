# 9-4-figureS4.R ===============================================================
# Figure S4: five deployment sites (2019-2024) for the randomization snapshot
#
# Input:  workflow/figS4/sensors_5sites.gpkg  (site, sensor_id, EPSG:4326)
# Output: manuscript/figures/fig_s4_sites.png
#
# Style follows A-deployment-map.R: BW Google satellite (key in
# .google_api_key), magenta sensor dots (#C2185B) with white ring, manual
# scale bar, theme_void with panel border. Panels use per-site aspect ratios
# (SITES$aspect = ground W/H) sized to each sensor array; row aspect sums are
# equal (0.88+0.72 = 0.42+0.46+0.72 = 1.60) so both rows span the same width.
# Set S4_PROVIDER=CartoDB.VoyagerNoLabels for the keyless vector fallback
# (kept because Esri imagery is cloud-covered over Jeonju).

pacman::p_load(tidyverse, sf, ggmap, maptiles, terra, tidyterra, patchwork)

base_dir <- tryCatch(
  normalizePath(file.path(dirname(
    rstudioapi::getSourceEditorContext()$path), ".."), winslash = "/"),
  error = function(e) normalizePath(".", winslash = "/"))  # Rscript fallback

PROVIDER <- Sys.getenv("S4_PROVIDER", "google")
IS_GOOGLE <- PROVIDER == "google"

if (IS_GOOGLE) {
  register_google(key = readLines(
    file.path(base_dir, ".google_api_key"), warn = FALSE))
}

sensors <- st_read(
  file.path(base_dir, "workflow/figS4/sensors_5sites.gpkg"), quiet = TRUE)

street_ground_w <- c(
  motorway = 12, trunk = 12, primary = 12, secondary = 10, tertiary = 8,
  unclassified = 6, residential = 6, living_street = 6, service = 4,
  pedestrian = 5, footway = 2, path = 2, cycleway = 2, track = 2, steps = 1.5
)

streets_all <- st_read(
  file.path(base_dir, "workflow/figS4/streets_5sites.gpkg"),
  layer = "streets", quiet = TRUE
)

site_poly <- function(site_id) {
  stw <- streets_all |> filter(site == site_id)
  if (!nrow(stw)) return(NULL)
  d <- st_transform(stw, 32652)
  if (!"gw" %in% names(d)) d$gw <- street_ground_w[d$highway]
  # Match Figure 2's cartographic minimum for narrow UNIST campus paths;
  # preserve the source ground widths for the other four sites.
  width_m <- if (site_id == "unist19") pmax(d$gw, 5.5) else d$gw
  st_transform(st_union(st_buffer(d, dist = width_m / 2)), 4326)
}

SITES <- tribble(
  ~site,        ~title,                    ~subtitle,                        ~zoom, ~bar_m, ~aspect,
  "unist19",    "(a) UNIST campus",        "Ulsan · Oct–Nov 2019 · 24 sensors", 16, 200, 0.88,
  "uou20",      "(b) Commercial district", "Ulsan · Jul 2020 · 17 sensors",  17, 100, 0.72,
  "seongnam22", "(c) Old downtown",        "Ulsan · Nov 2022 · 8 sensors",   17, 100, 0.42,
  "jeonju23",   "(d) Pedestrian street",   "Jeonju · Jul 2023 · 3 sensors",  17, 50,  0.46,
  "pops24",     "(e) Privately owned public space", "Ulsan · Apr 2024 · 3 sensors", 18, 50, 0.72
)

sensor_color <- "#C2185B"

# shared overlay: points + scale bar + framing, in the panel's native crs
add_overlays <- function(p, xy, xlim, ylim, bar_len, bar_m, title, subtitle,
                         crs) {
  # scale bar box anchored flush to the bottom-left panel corner
  padx <- 0.02 * diff(xlim)
  boxh <- 0.11 * diff(ylim)
  bx   <- xlim[1] + padx
  p +
    geom_point(data = xy, aes(X, Y),
               shape = 21, size = 2.6, fill = sensor_color,
               color = "white", stroke = 0.7, inherit.aes = FALSE) +
    annotate("rect",
             xmin = xlim[1], xmax = xlim[1] + bar_len + 2 * padx,
             ymin = ylim[1], ymax = ylim[1] + boxh,
             fill = alpha("black", 0.4)) +
    annotate("segment", x = bx, xend = bx + bar_len,
             y = ylim[1] + 0.62 * boxh, yend = ylim[1] + 0.62 * boxh,
             linewidth = 0.5, color = "white") +
    annotate("text", x = bx + bar_len / 2, y = ylim[1] + 0.30 * boxh,
             label = paste(bar_m, "m"), size = 2.6, color = "white",
             fontface = "bold", vjust = 0.9) +
    coord_sf(crs = crs, xlim = xlim, ylim = ylim, expand = FALSE) +
    labs(title = title, subtitle = subtitle) +
    theme_void() +
    theme(
      plot.title    = element_text(size = 11.5, face = "bold",
                                   margin = margin(b = 4)),
      plot.subtitle = element_text(size = 9.5, color = "grey30",
                                   margin = margin(b = 4, l = 1.5)),
      panel.border  = element_rect(colour = "grey50", fill = NA,
                                   linewidth = 0.4),
      plot.margin   = margin(12, 3, 4, 3)
    )
}

# extent helpers: pad then normalize to the site's width/height aspect on the
# ground (meters), widening the narrower dimension around its center
norm_extent <- function(xlim, ylim, to_m_x, to_m_y, aspect = 0.8) {
  w <- diff(xlim) * to_m_x; h <- diff(ylim) * to_m_y
  if (w / h < aspect) {
    grow <- (aspect * h - w) / 2 / to_m_x
    xlim <- xlim + c(-grow, grow)
  } else {
    grow <- (w / aspect - h) / 2 / to_m_y
    ylim <- ylim + c(-grow, grow)
  }
  list(xlim = xlim, ylim = ylim)
}

make_panel <- function(site_id, title, subtitle, zoom, bar_m, aspect) {
  pts4326 <- sensors |> filter(site == site_id)
  lat   <- mean(st_coordinates(pts4326)[, 2])
  lat_m <- 111320
  lon_m <- lat_m * cos(lat * pi / 180)

  if (IS_GOOGLE) {
    xy  <- as.data.frame(st_coordinates(pts4326))
    ctr <- c(lon = mean(range(xy$X)), lat = mean(range(xy$Y)))
    bm  <- get_map(location = ctr, zoom = zoom,
                   maptype = "satellite", source = "google", color = "bw")

    span <- max(diff(range(xy$X)) * lon_m, diff(range(xy$Y)) * lat_m, 1)
    pad  <- max(0.2 * span, 60)
    xlim <- range(xy$X) + c(-pad, pad) / lon_m
    ylim <- range(xy$Y) + c(-pad, pad) / lat_m
    e    <- norm_extent(xlim, ylim, lon_m, lat_m, aspect)

    bb <- attr(bm, "bb")   # clamp to fetched tile
    e$xlim <- c(max(e$xlim[1], bb$ll.lon), min(e$xlim[2], bb$ur.lon))
    e$ylim <- c(max(e$ylim[1], bb$ll.lat), min(e$ylim[2], bb$ur.lat))

    p <- ggmap(bm, darken = c(0.3, "white"))
    street_poly <- site_poly(site_id)
    if (!is.null(street_poly)) {
      p <- p + geom_sf(
        data = street_poly,
        fill = alpha("white", 0.40),
        color = alpha("grey20", 0.35), linewidth = 0.25,
        inherit.aes = FALSE
      )
    }
    p <- add_overlays(p, xy, e$xlim, e$ylim, bar_m / lon_m, bar_m,
                      title, subtitle, crs = 4326)
    list(plot = p, asp = diff(e$xlim) * lon_m / (diff(e$ylim) * lat_m))
  } else {
    pts <- st_transform(pts4326, 3857)
    xy  <- as.data.frame(st_coordinates(pts))
    mrc <- 1 / cos(lat * pi / 180)

    span <- max(diff(range(xy$X)), diff(range(xy$Y)), 1)
    pad  <- max(0.2 * span, 60 * mrc)
    xlim <- range(xy$X) + c(-pad, pad)
    ylim <- range(xy$Y) + c(-pad, pad)
    e    <- norm_extent(xlim, ylim, 1, 1, aspect)   # 3857 ~isotropic locally

    bbox <- st_as_sfc(st_bbox(
      c(xmin = e$xlim[1], ymin = e$ylim[1],
        xmax = e$xlim[2], ymax = e$ylim[2]), crs = 3857))
    tile <- get_tiles(bbox, provider = PROVIDER, zoom = zoom, crop = TRUE)

    p <- ggplot() +
      geom_spatraster_rgb(data = tile, maxcell = 5e6) +
      annotate("rect", xmin = e$xlim[1], xmax = e$xlim[2],
               ymin = e$ylim[1], ymax = e$ylim[2],
               fill = alpha("white", 0.06))
    p <- add_overlays(p, xy, e$xlim, e$ylim, bar_m * mrc, bar_m,
                      title, subtitle, crs = 3857)
    list(plot = p, asp = diff(e$xlim) / diff(e$ylim))
  }
}

res <- pmap(SITES, function(site, title, subtitle, zoom, bar_m, aspect)
  make_panel(site, title, subtitle, zoom, bar_m, aspect))
asp <- map_dbl(res, "asp")
cat("actual panel aspects:", paste(round(asp, 3), collapse = "  "), "\n")

# rows: widths proportional to ACTUAL (post-clamp) aspects and canvas height
# computed from the same aspects -> panels fill their cells exactly, so the
# title/subtitle block stays flush with the map's left edge (no centering
# slack). SITES$aspect remains the requested framing; asp is what survived
# the tile clamp.
s1 <- sum(asp[1:2]); s2 <- sum(asp[3:5])
row1 <- res[[1]]$plot + res[[2]]$plot + plot_layout(widths = asp[1:2])
row2 <- res[[3]]$plot + res[[4]]$plot + res[[5]]$plot +
  plot_layout(widths = asp[3:5])

lab_in <- 47 / 72                      # per-row label block + vertical margins
h1 <- (7 - 12 / 72) / s1 + lab_in      # 2 panels x 6 pt horizontal margins
h2 <- (7 - 18 / 72) / s2 + lab_in      # 3 panels x 6 pt horizontal margins
fig <- wrap_plots(row1, row2, ncol = 1, heights = c(h1, h2))

out_file <- file.path(base_dir, if (IS_GOOGLE)
  "manuscript/figures/fig_s4_sites.png" else
  "manuscript/figures/fig_s4_sites_voyager.png")
ggsave(out_file, fig, width = 7, height = h1 + h2, dpi = 300, bg = "white")
cat("Saved:", out_file, sprintf(" (%.2f x %.2f in)\n", 7, h1 + h2))

if (IS_GOOGLE) {
  docs_file <- file.path(base_dir, "docs/materials/appendix/fig_rand_sites.png")
  dir.create(dirname(docs_file), recursive = TRUE, showWarnings = FALSE)
  file.copy(out_file, docs_file, overwrite = TRUE)
  cat("Copied:", docs_file, "\n")
}
