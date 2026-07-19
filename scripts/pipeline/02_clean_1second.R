#!/usr/bin/env Rscript

# Deterministically deduplicate 1-second keys, remove locally administered
# addresses, and exclude identifiers with a continuous sensor session longer
# than the declared stationary threshold.

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), mustWork = TRUE)
source(file.path(dirname(script_path), "_common.R"))

usage <- function() {
  cat(paste0(
    "Usage:\n",
    "  Rscript 02_clean_1second.R --input aggregated_1second.parquet \\\n",
    "    --output cleaned_1second.parquet [options]\n\n",
    "Options:\n",
    "  --session-gap-seconds N   A larger gap starts a new session (default: 300)\n",
    "  --stationary-seconds N    Remove a source when any session is longer than\n",
    "                            this threshold (default: 7200)\n",
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
  defaults = list(session_gap_seconds = "300", stationary_seconds = "7200")
)
reject_unknown_options(
  options,
  c("input", "output", "session_gap_seconds", "stationary_seconds")
)
require_pipeline_args(options, c("input", "output"))
require_pipeline_packages(c("data.table", "bit64"))

session_gap_seconds <- parse_positive_number(
  options$session_gap_seconds, "--session-gap-seconds"
)
stationary_seconds <- parse_positive_number(
  options$stationary_seconds, "--stationary-seconds"
)

input <- read_pipeline_table(
  options$input, PIPELINE_ONE_SECOND_COLUMNS, "aggregated one-second input"
)
input <- normalize_one_second_table(input, "aggregated one-second input")
deduplicated <- deduplicate_one_second(input, "aggregated one-second input")

nonrandom <- deduplicated[source_address_randomized == 0L]
data.table::setorder(nonrandom, source_address, sensor_name, timestamp)

if (nrow(nonrandom)) {
  nonrandom[, gap_seconds := c(
    NA_real_, diff(as.numeric(timestamp))
  ), by = .(source_address, sensor_name)]
  nonrandom[, session_id := cumsum(
    is.na(gap_seconds) | gap_seconds > session_gap_seconds
  ), by = .(source_address, sensor_name)]

  sessions <- nonrandom[
    , .(
      first_timestamp = min(timestamp),
      last_timestamp = max(timestamp),
      session_duration_seconds = as.numeric(
        difftime(max(timestamp), min(timestamp), units = "secs")
      )
    ),
    by = .(source_address, sensor_name, session_id)
  ]
  stationary_sources <- unique(
    sessions[session_duration_seconds > stationary_seconds, source_address]
  )
  cleaned <- nonrandom[!source_address %in% stationary_sources]
  cleaned[, c("gap_seconds", "session_id") := NULL]
} else {
  stationary_sources <- character()
  cleaned <- nonrandom
}

data.table::setcolorder(cleaned, PIPELINE_ONE_SECOND_COLUMNS)
data.table::setorder(cleaned, timestamp, source_address, sensor_name)
cleaned <- normalize_one_second_table(
  cleaned, "cleaned one-second data", require_unique = TRUE
)
if (nrow(cleaned) && any(cleaned$source_address_randomized != 0L)) {
  stop_pipeline("Internal error: randomized rows remain after cleaning")
}

write_pipeline_table(cleaned, options$output)
cat(
  "Deterministic duplicate keys removed: ", nrow(input) - nrow(deduplicated), "\n",
  "Randomized rows removed: ",
  nrow(deduplicated) - nrow(nonrandom), "\n",
  "Stationary identifiers removed (> ", stationary_seconds, " s): ",
  length(stationary_sources), "\n",
  sep = ""
)
report_stage("Cleaned 1-second", cleaned, options$output)
