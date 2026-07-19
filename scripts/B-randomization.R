# B-randomization.R ============================================================
# Operational LAA-bit comparison across retained source-address streams
#
# Sites:
#   UNIST campus (24 sensors, Oct–Nov 2019)
#   Commercial district near Univ. of Ulsan (17 sensors, Jul 2020)
#
# Approach:
#   Both sites: restricted raw Parquets → filter analysis sensors → LAA bit flag
#   Descriptive comparison: LAA-flagged vs LAA-unflagged address counts
#   Address values are disjoint between groups, but physical devices and people
#   are not observed and the groups must not be called independent samples.
#
# Input:  workflow/unist19_source/, workflow/uou20_source/
# Output: docs/materials/appendix/  →  randomization_*.csv, fig_rand_*.png
# ==============================================================================


# Setup ----

pacman::p_load(tidyverse, data.table, arrow, patchwork, ggrepel)

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")
out_dir  <- file.path(base_dir, "docs/materials/appendix")
ms_fig_dir <- file.path(base_dir, "manuscript/figures")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(ms_fig_dir, recursive = TRUE, showWarnings = FALSE)

# Remove only outputs owned by this script. Figure S4's online-book copy is
# also named fig_rand_sites.png and must not be deleted here.
old_files <- list.files(
  out_dir,
  "^(fig_rand_(landscape|spatial|supplementary|temporal)|randomization_)",
  full.names = TRUE
)
if (length(old_files)) {
  file.remove(old_files)
  cat("  Removed", length(old_files), "old output files\n")
}

LA_HEX <- c("2", "3", "6", "7", "a", "b", "e", "f")

SITE_LEVELS <- c("UNIST campus (2019)", "Commercial district (2020)")

# UoU sensor mapping (matching Ch 5 / Appendix A naming: u01–u17)
uou_coords    <- fread(file.path(base_dir, "workflow/uou20/output/sensors_coords.csv"))
UOU_ID_MAP    <- setNames(uou_coords$id_sensor, uou_coords$id_last)
SENSORS_UOU   <- names(UOU_ID_MAP)


# Prep ----

## UNIST load ----

cat("--- UNIST 2019 ---\n")
raw_dirs_u <- list.dirs(
  file.path(base_dir, "workflow/unist19_source"), recursive = FALSE)
raw_dirs_u <- raw_dirs_u[!basename(raw_dirs_u) %in% c("206_front", "comm_center")]

dt_u <- as.data.table(
  open_dataset(list.files(raw_dirs_u, "\\.parquet$", full.names = TRUE)) |>
    select(timestamp, source_address, sensor_name) |> collect()
)
dt_u[, hour_ts := floor_date(timestamp, "hour")]
cat(sprintf("  %s rows | %d sensors\n",
    format(nrow(dt_u), big.mark = ","), uniqueN(dt_u$sensor_name)))


## UoU load ----

cat("--- UoU 2020 ---\n")
uou_files <- list.files(
  file.path(base_dir, "workflow/uou20_source"),
  "\\.parquet$", recursive = TRUE, full.names = TRUE
)

dt_c <- as.data.table(
  open_dataset(uou_files) |>
    select(timestamp, source_address, sensor_name) |> collect()
)
dt_c <- dt_c[sensor_name %chin% SENSORS_UOU]
dt_c[, sensor_name := UOU_ID_MAP[sensor_name]]
dt_c[, hour_ts := floor_date(timestamp, "hour")]
cat(sprintf("  %s rows | %d sensors\n",
    format(nrow(dt_c), big.mark = ","), uniqueN(dt_c$sensor_name)))


## Invalid addresses ----
# All-zero (and malformed) source addresses are capture artifacts, not
# physical devices; the all-zero address passes the LAA-bit test as unflagged
# and alone carries ~4% of raw UNIST detections.
MAC_RE <- "^([0-9a-f]{2}:){5}[0-9a-f]{2}$"
drop_invalid <- function(dt, label) {
  addrs <- unique(dt$source_address)
  bad <- addrs[!grepl(MAC_RE, tolower(addrs)) |
                 tolower(addrs) %chin%
                   c("00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff")]
  n0 <- nrow(dt)
  dt <- dt[!source_address %chin% bad]
  cat(sprintf("  %s: removed %s rows | %d invalid addresses\n", label,
              format(n0 - nrow(dt), big.mark = ","), length(bad)))
  dt
}
dt_u <- drop_invalid(dt_u, "UNIST")
dt_c <- drop_invalid(dt_c, "UoU")

## LA bit flag ----

dt_u[, is_random := substr(tolower(source_address), 2, 2) %chin% LA_HEX]
dt_c[, is_random := substr(tolower(source_address), 2, 2) %chin% LA_HEX]

cat(sprintf("  UNIST LAA-flagged: %.1f%% det | UoU LAA-flagged: %.1f%% det\n",
    dt_u[(is_random), .N] / nrow(dt_u) * 100,
    dt_c[(is_random), .N] / nrow(dt_c) * 100))


# Landscape ----

## Compute share ----

proportion <- rbind(
  data.table(
    site           = SITE_LEVELS[1],
    n_sensors                  = uniqueN(dt_u$sensor_name),
    n_detections               = nrow(dt_u),
    det_pct_laa_flagged        = round(dt_u[(is_random), .N] / nrow(dt_u) * 100, 1),
    n_distinct_addresses       = uniqueN(dt_u$source_address),
    n_laa_flagged_addresses    = uniqueN(dt_u[(is_random), source_address]),
    n_laa_unflagged_addresses  = uniqueN(dt_u[!(is_random), source_address]),
    address_pct_laa_flagged    = round(uniqueN(dt_u[(is_random), source_address]) /
                                       uniqueN(dt_u$source_address) * 100, 1)
  ),
  data.table(
    site           = SITE_LEVELS[2],
    n_sensors                  = uniqueN(dt_c$sensor_name),
    n_detections               = nrow(dt_c),
    det_pct_laa_flagged        = round(dt_c[(is_random), .N] / nrow(dt_c) * 100, 1),
    n_distinct_addresses       = uniqueN(dt_c$source_address),
    n_laa_flagged_addresses    = uniqueN(dt_c[(is_random), source_address]),
    n_laa_unflagged_addresses  = uniqueN(dt_c[!(is_random), source_address]),
    address_pct_laa_flagged    = round(uniqueN(dt_c[(is_random), source_address]) /
                                       uniqueN(dt_c$source_address) * 100, 1)
  )
)
proportion[, address_to_detection_share_ratio := round(
  address_pct_laa_flagged / det_pct_laa_flagged, 1
)]

fwrite(proportion, file.path(out_dir, "randomization_proportion.csv"))
cat("\n=== Landscape ===\n"); print(proportion)


## Plot landscape ----

prop_long <- rbindlist(lapply(1:nrow(proportion), function(i) {
  r <- proportion[i]
  rbind(
    data.table(site = r$site, level = "Detection\nevents",
               type = "LAA-unflagged", pct = round(100 - r$det_pct_laa_flagged, 1)),
    data.table(site = r$site, level = "Detection\nevents",
               type = "LAA-flagged", pct = r$det_pct_laa_flagged),
    data.table(site = r$site, level = "Distinct\nsource addresses",
               type = "LAA-unflagged", pct = round(100 - r$address_pct_laa_flagged, 1)),
    data.table(site = r$site, level = "Distinct\nsource addresses",
               type = "LAA-flagged", pct = r$address_pct_laa_flagged)
  )
}))
prop_long[, `:=`(
  type  = factor(type, c("LAA-unflagged", "LAA-flagged")),
  level = factor(level, c("Detection\nevents", "Distinct\nsource addresses")),
  site  = factor(site, SITE_LEVELS)
)]

p_landscape <- ggplot(prop_long, aes(level, pct, fill = type)) +
  geom_col(width = 0.7, color = "white", linewidth = 0.3) +
  geom_text(aes(label = paste0(pct, "%")),
            position = position_stack(vjust = 0.5),
            size = 3.3, fontface = "bold", color = "white") +
  facet_wrap(~site, nrow = 1) +
  scale_fill_manual(values = c("LAA-unflagged" = "#1565C0",
                                "LAA-flagged" = "#E65100"), name = NULL) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.02))) +
  labs(x = NULL, y = "Share (%)") +
  theme_bw(base_size = 11) +
  theme(axis.text.x        = element_text(size = 9, lineheight = 0.9),
        strip.text         = element_text(size = 9, face = "bold"),
        strip.background   = element_rect(fill = "grey95"),
        legend.position    = "top",
        legend.text        = element_text(size = 10),
        legend.margin      = margin(0, 0, -5, 0),
        panel.grid.major.x = element_blank())

ggsave(file.path(out_dir, "fig_rand_landscape.png"), p_landscape,
       width = 8, height = 4, dpi = 300, bg = "white")


# Temporal ----
# Descriptive hourly comparison of disjoint source-address value groups.
# The data do not establish independent physical-device or person samples.

## Compute hourly ----

hourly_u <- dt_u[, .(n_random    = uniqueN(source_address[is_random]),
                      n_nonrandom = uniqueN(source_address[!is_random])),
                  by = hour_ts]

hourly_c <- dt_c[, .(n_random    = uniqueN(source_address[is_random]),
                      n_nonrandom = uniqueN(source_address[!is_random])),
                  by = hour_ts]

temporal <- rbind(
  data.table(site = SITE_LEVELS[1],
    pearson_r    = round(cor(hourly_u$n_random, hourly_u$n_nonrandom), 3),
    spearman_rho = round(cor(hourly_u$n_random, hourly_u$n_nonrandom,
                             method = "spearman"), 3),
    n_hours      = nrow(hourly_u)),
  data.table(site = SITE_LEVELS[2],
    pearson_r    = round(cor(hourly_c$n_random, hourly_c$n_nonrandom), 3),
    spearman_rho = round(cor(hourly_c$n_random, hourly_c$n_nonrandom,
                             method = "spearman"), 3),
    n_hours      = nrow(hourly_c))
)

fwrite(temporal, file.path(out_dir, "randomization_temporal.csv"))
cat("\n=== Temporal ===\n"); print(temporal)


## Prep scatter data ----

scatter_temporal <- rbind(
  hourly_u[, .(n_random, n_nonrandom, site = SITE_LEVELS[1])],
  hourly_c[, .(n_random, n_nonrandom, site = SITE_LEVELS[2])]
)
scatter_temporal[, site := factor(site, SITE_LEVELS)]


# Spatial ----

## Compute per-sensor ----

sensor_u <- dt_u[, .(n_random    = uniqueN(source_address[is_random]),
                      n_nonrandom = uniqueN(source_address[!is_random])),
                  by = .(sensor_name, hour_ts)]

sensor_r_u <- sensor_u[, {
  if (sum(n_nonrandom > 0) >= 10)
    list(pearson_r = round(cor(n_random, n_nonrandom), 3), n_hours = .N)
  else
    list(pearson_r = NA_real_, n_hours = .N)
}, by = sensor_name]
sensor_r_u[, site := SITE_LEVELS[1]]

sensor_c <- dt_c[, .(n_random    = uniqueN(source_address[is_random]),
                      n_nonrandom = uniqueN(source_address[!is_random])),
                  by = .(sensor_name, hour_ts)]

sensor_r_c <- sensor_c[, {
  if (sum(n_nonrandom > 0) >= 10)
    list(pearson_r = round(cor(n_random, n_nonrandom), 3), n_hours = .N)
  else
    list(pearson_r = NA_real_, n_hours = .N)
}, by = sensor_name]
sensor_r_c[, site := SITE_LEVELS[2]]

sensor_all <- rbind(sensor_r_u, sensor_r_c)

# Per-sensor hourly diagnostics
diag_u <- sensor_u[, .(
  mean_rand      = round(mean(n_random), 1),
  mean_nonrand   = round(mean(n_nonrandom), 1),
  median_rand    = as.double(median(n_random)),
  median_nonrand = as.double(median(n_nonrandom)),
  pct_zero_rand  = round(mean(n_random <= 2) * 100, 1),
  pct_zero_nonrand = round(mean(n_nonrandom <= 2) * 100, 1),
  cv_rand        = round(sd(n_random) / mean(n_random), 2),
  cv_nonrand     = round(sd(n_nonrandom) / mean(n_nonrandom), 2)
), by = sensor_name]
diag_u[, site := SITE_LEVELS[1]]

diag_c <- sensor_c[, .(
  mean_rand      = round(mean(n_random), 1),
  mean_nonrand   = round(mean(n_nonrandom), 1),
  median_rand    = as.double(median(n_random)),
  median_nonrand = as.double(median(n_nonrandom)),
  pct_zero_rand  = round(mean(n_random <= 2) * 100, 1),
  pct_zero_nonrand = round(mean(n_nonrandom <= 2) * 100, 1),
  cv_rand        = round(sd(n_random) / mean(n_random), 2),
  cv_nonrand     = round(sd(n_nonrandom) / mean(n_nonrandom), 2)
), by = sensor_name]
diag_c[, site := SITE_LEVELS[2]]

sensor_diag <- rbind(diag_u, diag_c)

# Add detection counts per sensor
det_counts <- rbind(
  dt_u[, .(n_detections = .N), by = sensor_name][, site := SITE_LEVELS[1]],
  dt_c[, .(n_detections = .N), by = sensor_name][, site := SITE_LEVELS[2]]
)

sensor_all[det_counts, n_detections := i.n_detections,
           on = .(sensor_name, site)]
sensor_all[sensor_diag, `:=`(
  mean_rand      = i.mean_rand,
  mean_nonrand   = i.mean_nonrand,
  median_rand    = i.median_rand,
  median_nonrand = i.median_nonrand,
  pct_zero_rand  = i.pct_zero_rand,
  pct_zero_nonrand = i.pct_zero_nonrand,
  cv_rand        = i.cv_rand,
  cv_nonrand     = i.cv_nonrand
), on = .(sensor_name, site)]

spatial <- sensor_all[!is.na(pearson_r), .(
  n_sensors    = .N,
  r_median     = round(median(pearson_r), 3),
  r_q25        = round(quantile(pearson_r, 0.25), 3),
  r_q75        = round(quantile(pearson_r, 0.75), 3),
  n_above_09   = sum(pearson_r > 0.9),
  pct_above_09 = round(mean(pearson_r > 0.9) * 100, 1)
), by = site]

fwrite(sensor_all, file.path(out_dir, "randomization_sensor_detail.csv"))
fwrite(spatial, file.path(out_dir, "randomization_spatial.csv"))
cat("\n=== Spatial ===\n"); print(spatial)


## Prep sensor plot data ----

sensor_plot <- copy(sensor_all[!is.na(pearson_r)])
sensor_plot[, site := factor(site, SITE_LEVELS)]


# Supplementary ----
# Combined figure for manuscript: scatter (a) + boxplot (b), unified site colors

SITE_COLORS <- c("UNIST campus (2019)"        = "#1565C0",
                  "Commercial district (2020)" = "#E65100")

## (a) Temporal scatter — both sites, color by site ----

# r labels near end of each regression line
r_pos <- scatter_temporal[, {
  x_pos <- quantile(n_random, 0.9)
  fit <- lm(n_nonrandom ~ n_random)
  y_pos <- predict(fit, newdata = data.frame(n_random = x_pos))
  list(x = x_pos, y = y_pos)
}, by = site]
r_pos <- merge(r_pos, temporal[, .(site, pearson_r)], by = "site")
r_pos[, `:=`(
  label = sprintf("italic(r) == %.3f", pearson_r),
  site  = factor(site, SITE_LEVELS)
)]

p_supp_a <- ggplot(scatter_temporal, aes(n_random, n_nonrandom, color = site)) +
  geom_point(size = 1, alpha = 0.4) +
  geom_smooth(method = "lm", se = FALSE, linewidth = 0.7) +
  geom_label(data = r_pos, aes(x = x, y = y, label = label, color = site),
             inherit.aes = FALSE, parse = TRUE,
             fill = alpha("white", 0.85), linewidth = 0,
             fontface = "bold", size = 3.8, show.legend = FALSE) +
  scale_color_manual(values = SITE_COLORS, name = NULL) +
  labs(x = "LAA-flagged distinct addresses per hour",
       y = "LAA-unflagged distinct addresses per hour") +
  theme_bw(base_size = 11) +
  theme(legend.position  = "bottom",
        legend.text      = element_text(size = 10),
        legend.margin    = margin(-5, 0, 0, 0),
        panel.grid.minor = element_blank())

## (b) Boxplot — same site colors ----

p_supp_b <- ggplot(sensor_plot, aes(x = site, y = pearson_r, fill = site)) +
  geom_boxplot(width = 0.4, outlier.shape = NA, alpha = 0.3, color = "grey60") +
  geom_point(aes(color = site),
             position = position_jitter(width = 0.12, height = 0, seed = 42),
             alpha = 0.7, size = 2, show.legend = FALSE) +
  scale_fill_manual(values = SITE_COLORS, guide = "none") +
  scale_color_manual(values = SITE_COLORS, guide = "none") +
  scale_y_continuous(limits = c(NA, 1.05)) +
  labs(x = NULL, y = "Per-sensor Pearson r\n(LAA-flagged vs LAA-unflagged)") +
  theme_bw(base_size = 11) +
  theme(panel.grid.minor   = element_blank(),
        panel.grid.major.x = element_blank())

## Combine ----

tag_theme <- theme(plot.tag = element_text(face = "bold.italic", size = 16),
                   plot.margin = margin(5, 5, 15, 5))

p_supp <- (p_supp_a + labs(tag = "a)") + tag_theme) /
  (p_supp_b + labs(tag = "b)") +
     theme(plot.tag = element_text(face = "bold.italic", size = 16),
           plot.margin = margin(10, 5, 5, 5))) +
  plot_layout(heights = c(2.5, 2))

supp_file <- file.path(out_dir, "fig_rand_supplementary.png")
ggsave(supp_file, p_supp,
       width = 7, height = 7, dpi = 300, bg = "white")
file.copy(supp_file, file.path(ms_fig_dir, "fig_rand_supplementary.png"),
          overwrite = TRUE)

## Individual panels (no tags) ----

ggsave(file.path(out_dir, "fig_rand_temporal.png"), p_supp_a,
       width = 7, height = 4.5, dpi = 300, bg = "white")

ggsave(file.path(out_dir, "fig_rand_spatial.png"), p_supp_b,
       width = 6, height = 3, dpi = 300, bg = "white")


cat("\nDone. Output saved to:", out_dir, "\n")
