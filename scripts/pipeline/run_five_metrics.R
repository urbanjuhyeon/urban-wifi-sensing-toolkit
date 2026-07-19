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
    "  Rscript run_five_metrics.R \\\n",
    "    --input analysis_20second.parquet \\\n",
    "    --sensors synthetic_sensors.csv \\\n",
    "    --fixture-manifest manifest.json --output-dir output [options]\n\n",
    "The documented smoke-test thresholds are defaults; use --help on\n",
    "05_build_five_metrics.R for the optional threshold names.\n"
  ))
}

raw_args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% raw_args) {
  usage()
  quit(status = 0L)
}
options <- parse_pipeline_args(raw_args, defaults = METRIC_PARAMETER_DEFAULTS)
reject_unknown_options(
  options, c(
    "input", "sensors", "fixture_manifest", "output_dir",
    names(METRIC_PARAMETER_DEFAULTS)
  )
)
require_pipeline_args(
  options, c("input", "sensors", "fixture_manifest", "output_dir")
)
invisible(parse_metric_parameters(options))

rscript <- file.path(R.home("bin"), "Rscript")
run_stage <- function(script_name, arguments) {
  status <- system2(
    rscript, c(shQuote(file.path(script_dir, script_name)), arguments)
  )
  if (!identical(status, 0L)) {
    stop_pipeline(script_name, " failed with exit status ", status)
  }
}
arguments <- c(
  "--input", shQuote(options$input),
  "--sensors", shQuote(options$sensors),
  "--fixture-manifest", shQuote(options$fixture_manifest),
  "--output-dir", shQuote(options$output_dir)
)
for (name in names(METRIC_PARAMETER_DEFAULTS)) {
  arguments <- c(
    arguments,
    paste0("--", gsub("_", "-", name, fixed = TRUE)),
    shQuote(options[[name]])
  )
}
run_stage("05_build_five_metrics.R", arguments)
run_stage("06_verify_five_metrics.R", arguments)
cat("Maintained five-metric smoke workflow completed.\n")
