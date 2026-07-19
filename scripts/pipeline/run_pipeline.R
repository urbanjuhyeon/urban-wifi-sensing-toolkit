#!/usr/bin/env Rscript

# Run all maintained stages with Parquet by default.  CSV is an explicit
# compatibility fallback because it cannot retain physical timestamp/int64
# schema metadata.

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), mustWork = TRUE)
script_dir <- dirname(script_path)
source(file.path(script_dir, "_common.R"))

usage <- function() {
  cat(paste0(
    "Usage:\n",
    "  Rscript run_pipeline.R --input capture.sqlite3 --output-dir output [options]\n\n",
    "Options:\n",
    "  --format parquet|csv       Output format (default: parquet)\n",
    "  --rssi-min NUMBER          Inclusive lower RSSI limit (default: -80)\n",
    "  --rssi-max NUMBER          Inclusive upper RSSI limit (default: -30)\n",
    "  --exclude-subtypes LIST   Default: beacon,probe-response\n",
    "  --session-gap-seconds N  Default: 300\n",
    "  --stationary-seconds N   Strictly-greater threshold; default: 7200\n",
    "  --help                    Show this message\n"
  ))
}

raw_args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% raw_args) {
  usage()
  quit(status = 0L)
}
options <- parse_pipeline_args(
  raw_args,
  defaults = list(
    format = "parquet", rssi_min = "-80", rssi_max = "-30",
    exclude_subtypes = "beacon,probe-response",
    session_gap_seconds = "300", stationary_seconds = "7200"
  )
)
reject_unknown_options(
  options,
  c(
    "input", "output_dir", "format", "rssi_min", "rssi_max",
    "exclude_subtypes", "session_gap_seconds", "stationary_seconds"
  )
)
require_pipeline_args(options, c("input", "output_dir"))
format <- parse_output_format(options$format)
if (format == "parquet") require_pipeline_packages("arrow")

dir.create(options$output_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(options$output_dir)) {
  stop_pipeline("Cannot create output directory: ", options$output_dir)
}
output_dir <- normalizePath(options$output_dir, winslash = "/", mustWork = TRUE)

paths <- list(
  one_second = file.path(output_dir, paste0("01_aggregated_1second.", format)),
  cleaned = file.path(output_dir, paste0("02_cleaned_1second.", format)),
  twenty_second = file.path(output_dir, paste0("03_analysis_20second.", format))
)

rscript <- file.path(R.home("bin"), "Rscript")
run_stage <- function(script_name, arguments) {
  command <- c(file.path(script_dir, script_name), arguments)
  status <- system2(rscript, shQuote(command))
  if (!identical(status, 0L)) {
    stop_pipeline(script_name, " failed with exit status ", status)
  }
}

run_stage("01_aggregate_sqlite.R", c(
  "--input", options$input,
  "--output", paths$one_second,
  "--rssi-min", options$rssi_min,
  "--rssi-max", options$rssi_max,
  "--exclude-subtypes", options$exclude_subtypes
))
run_stage("02_clean_1second.R", c(
  "--input", paths$one_second,
  "--output", paths$cleaned,
  "--session-gap-seconds", options$session_gap_seconds,
  "--stationary-seconds", options$stationary_seconds
))
run_stage("03_build_20second.R", c(
  "--input", paths$cleaned,
  "--output", paths$twenty_second
))
run_stage("04_verify_pipeline.R", c(
  "--one-second", paths$one_second,
  "--cleaned-one-second", paths$cleaned,
  "--twenty-second", paths$twenty_second
))

cat("Maintained pipeline completed: ", output_dir, "\n", sep = "")
