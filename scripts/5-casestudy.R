# =============================================================================
# 5-casestudy.R: Ch5 Supporting Figures for Quarto Book
# =============================================================================
#
# Generates figures for docs/5-2-casestudy.qmd (UoU commercial district).
# Reads pre-computed CSVs from 9-2-figure3.R — run that script first.
#
# Output: docs/materials/ch5/fig_ch5_freq_dist.png
#         docs/materials/ch5/fig_ch5_*.png (additional as needed)
#
# =============================================================================


# Setup ----

pacman::p_load(tidyverse)

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

data_dir <- file.path(base_dir, "workflow/uou20/output")
ch5_dir  <- file.path(base_dir, "docs/materials/ch5")
dir.create(ch5_dir, recursive = TRUE, showWarnings = FALSE)

# Colors — consistent with 9-2-figure3.R
TYPE_COLORS <- c("Ped-priority" = "#2979FF", "Conventional" = "#999999")
FREQ_COLORS <- c("Single-day" = "#E65100", "Multi-day" = "#1565C0")


# Load CSVs ----

cat("Loading pre-computed CSVs from 9-2-figure3.R...\n")

freq_ndays    <- read_csv(file.path(data_dir, "freq_ndays_dist.csv"),
                           show_col_types = FALSE)
freq_cross    <- read_csv(file.path(data_dir, "freq_stay_cross.csv"),
                           show_col_types = FALSE)
freq_class    <- read_csv(file.path(data_dir, "freq_classification.csv"),
                           show_col_types = FALSE)
sensor_result <- read_csv(file.path(data_dir, "activities_sensor_result.csv"),
                           show_col_types = FALSE)
sensor_freq   <- read_csv(file.path(data_dir, "freq_sensor_result.csv"),
                           show_col_types = FALSE)

cat("  Loaded:", nrow(freq_ndays), "day bins,",
    nrow(freq_cross), "cross cells,",
    nrow(sensor_freq), "sensor-freq rows\n")


# Fig: n_days distribution ----
# Horizontal bar chart showing qualifying visit days per device.
# Motivates the Single-day (1 day) vs Multi-day (2+ days) classification.

cat("\nGenerating n_days distribution figure...\n")

p_freq_dist <- ggplot(freq_ndays,
                       aes(x = reorder(factor(n_days), -n_days),
                           y = n_devices, fill = visit_type)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = paste0(format(n_devices, big.mark = ","),
                                " (", pct, "%)")),
            hjust = -0.05, size = 3, fontface = "bold", color = "grey25") +
  scale_fill_manual(values = FREQ_COLORS, name = NULL) +
  scale_y_continuous(labels = scales::comma,
                     expand = expansion(mult = c(0, 0.35))) +
  coord_flip() +
  labs(x = "Days with a qualifying visit", y = "Number of devices") +
  theme_bw() +
  theme(
    legend.position = c(0.82, 0.18),
    legend.background = element_rect(fill = "white", color = "grey70",
                                      linewidth = 0.3),
    legend.text      = element_text(size = 9),
    axis.text        = element_text(size = 9),
    axis.title       = element_text(size = 10),
    panel.grid.minor = element_blank()
  )

ggsave(file.path(ch5_dir, "fig_ch5_freq_dist.png"), p_freq_dist,
       width = 6, height = 3.5, dpi = 300, bg = "white")

cat("  Saved: fig_ch5_freq_dist.png\n")


# Done ----

cat("\nDone. Ch5 figures saved to:", ch5_dir, "\n")
