#!/usr/bin/env Rscript

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), mustWork = TRUE)
script_dir <- dirname(script_path)
source(file.path(script_dir, "_common.R"))
source(file.path(script_dir, "_metrics_common.R"))

usage <- function() {
  cat(paste0(
    "Usage:\n",
    "  Rscript 05_build_five_metrics.R \\\n",
    "    --input analysis_20second.parquet \\\n",
    "    --sensors synthetic_sensors.csv \\\n",
    "    --fixture-manifest manifest.json --output-dir output [options]\n\n",
    "Options:\n",
    "  --track-gap-seconds N                  default: 1800\n",
    "  --visit-gap-seconds N                  default: 7200\n",
    "  --revisit-min-windows N                default: 2\n",
    "  --activity-min-windows N               default: 3\n",
    "  --activity-max-duration-seconds N      default: 7200\n",
    "  --activity-distance-metres N           default: 75\n",
    "  --activity-continuity-gap-seconds N    default: 600\n",
    "  --activity-min-duration-seconds N      default: 300\n",
    "  --help                                  show this message\n"
  ))
}

raw_args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% raw_args) {
  usage()
  quit(status = 0L)
}
options <- parse_pipeline_args(raw_args, defaults = METRIC_PARAMETER_DEFAULTS)
reject_unknown_options(options, c(
  "input", "sensors", "fixture_manifest", "output_dir",
  "track_gap_seconds", "visit_gap_seconds", "revisit_min_windows",
  "activity_min_windows",
  "activity_max_duration_seconds", "activity_distance_metres",
  "activity_continuity_gap_seconds", "activity_min_duration_seconds"
))
require_pipeline_args(
  options, c("input", "sensors", "fixture_manifest", "output_dir")
)
require_pipeline_packages(c("data.table", "arrow"))
parameters <- parse_metric_parameters(options)

input_path <- assert_input_file(options$input, "maintained 20-second input")
sensor_path <- assert_input_file(options$sensors, "synthetic sensor metadata")
fixture_path <- assert_input_file(options$fixture_manifest, "synthetic fixture manifest")
dir.create(options$output_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(options$output_dir)) {
  stop_pipeline("cannot create output directory: ", options$output_dir)
}
output_dir <- normalizePath(options$output_dir, winslash = "/", mustWork = TRUE)

input <- read_metric_input(input_path)
sensors <- read_metric_sensors(sensor_path)
contract <- read_fixture_contract(fixture_path)
if (!all(unique(input$source_address) %in%
         c(contract$moving_identifier, contract$activity_identifier))) {
  stop_pipeline("maintained metric input contains an identifier outside fixture roles")
}
outputs <- build_five_metrics(input, sensors, parameters)
paths <- metric_output_paths(output_dir)
for (name in names(outputs)) write_metric_csv(outputs[[name]], paths[[name]])
write_metric_manifest(
  paths$manifest,
  gsub("\\\\", "/", options$input),
  gsub("\\\\", "/", options$sensors),
  gsub("\\\\", "/", options$fixture_manifest),
  parameters, outputs, contract
)

cat(
  "Built maintained five-metric smoke outputs\n",
  "  Location rows:    ", nrow(outputs$location), "\n",
  "  Count rows:       ", nrow(outputs$count), "\n",
  "  Track trajectories: ", nrow(outputs$track_trajectories), "\n",
  "  Track OD pairs:   ", nrow(outputs$track_od), "\n",
  "  Revisits rows:    ", nrow(outputs$revisits), "\n",
  "  Activities rows:  ", nrow(outputs$activities), "\n",
  "  Output directory: ", output_dir, "\n",
  sep = ""
)
