#!/usr/bin/env Rscript

# Build the maintained analysis handoff: one row per source x sensor x
# UTC-aligned 20-second window.  Detections count unique 1-second slots, not
# packets or duplicate rows.

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), mustWork = TRUE)
source(file.path(dirname(script_path), "_common.R"))

usage <- function() {
  cat(paste0(
    "Usage:\n",
    "  Rscript 03_build_20second.R --input cleaned_1second.parquet \\\n",
    "    --output analysis_20second.parquet\n\n",
    "The window is fixed at 20 seconds for the maintained release contract.\n"
  ))
}

raw_args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% raw_args) {
  usage()
  quit(status = 0L)
}
options <- parse_pipeline_args(raw_args)
reject_unknown_options(options, c("input", "output"))
require_pipeline_args(options, c("input", "output"))
require_pipeline_packages(c("data.table", "bit64"))

cleaned <- read_pipeline_table(
  options$input, PIPELINE_ONE_SECOND_COLUMNS, "cleaned one-second input"
)
cleaned <- normalize_one_second_table(
  cleaned, "cleaned one-second input", require_unique = TRUE
)
if (nrow(cleaned) && any(cleaned$source_address_randomized != 0L)) {
  stop_pipeline("Cleaned input still contains source_address_randomized == 1")
}

twenty_second <- build_twenty_second(data.table::copy(cleaned))
assert_unique_key(
  twenty_second,
  c("timestamp", "source_address", "sensor_name"),
  "20-second data"
)
detections_numeric <- as.numeric(twenty_second$detections)
if (any(detections_numeric < 1 | detections_numeric > PIPELINE_WINDOW_SECONDS)) {
  stop_pipeline("20-second detections must be integers from 1 through 20")
}
if (any(abs(
  twenty_second$strength_sum -
    (100 * detections_numeric + twenty_second$rssi_sum)
) > 1e-9)) {
  stop_pipeline("Internal error: strength_sum invariant failed")
}

write_pipeline_table(twenty_second, options$output)
report_stage("Built 20-second", twenty_second, options$output)
