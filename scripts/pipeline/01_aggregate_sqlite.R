#!/usr/bin/env Rscript

# Aggregate the maintained eight-column capture contract to one record per
# pseudonymous source x sensor x true UTC second.

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), mustWork = TRUE)
source(file.path(dirname(script_path), "_common.R"))

usage <- function() {
  cat(paste0(
    "Usage:\n",
    "  Rscript 01_aggregate_sqlite.R --input capture.sqlite3 \\\n",
    "    --output aggregated_1second.parquet [options]\n\n",
    "Options:\n",
    "  --rssi-min NUMBER           Inclusive lower RSSI limit (default: -80)\n",
    "  --rssi-max NUMBER           Inclusive upper RSSI limit (default: -30)\n",
    "  --exclude-subtypes LIST    Comma-separated exact subtype names\n",
    "                             (default: beacon,probe-response)\n",
    "  --help                     Show this message\n"
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
    rssi_min = "-80",
    rssi_max = "-30",
    exclude_subtypes = "beacon,probe-response"
  )
)
reject_unknown_options(
  options,
  c("input", "output", "rssi_min", "rssi_max", "exclude_subtypes")
)
require_pipeline_args(options, c("input", "output"))
require_pipeline_packages(c("DBI", "RSQLite", "data.table", "bit64"))

input_path <- assert_input_file(options$input, "SQLite input")
output_path <- options$output
rssi_min <- parse_finite_number(options$rssi_min, "--rssi-min")
rssi_max <- parse_finite_number(options$rssi_max, "--rssi-max")
if (rssi_min > rssi_max) stop_pipeline("--rssi-min cannot exceed --rssi-max")
if (rssi_min < -127 || rssi_max > 0) {
  stop_pipeline("RSSI limits must remain within the capture range [-127, 0]")
}

excluded_subtypes <- trimws(strsplit(options$exclude_subtypes, ",", fixed = TRUE)[[1L]])
excluded_subtypes <- unique(tolower(excluded_subtypes[nzchar(excluded_subtypes)]))

connection <- DBI::dbConnect(RSQLite::SQLite(), input_path, flags = RSQLite::SQLITE_RO)
on.exit(DBI::dbDisconnect(connection), add = TRUE)

schema <- DBI::dbGetQuery(connection, "PRAGMA table_info('packets')")
expected_types <- c("TEXT", "TEXT", "TEXT", "INTEGER", "TEXT", "INTEGER", "INTEGER", "TEXT")
if (
  !identical(schema$name, PIPELINE_PACKET_COLUMNS) ||
  !identical(toupper(schema$type), expected_types) ||
  !all(schema$notnull == 1L)
) {
  stop_pipeline(
    "SQLite packets must implement the exact maintained eight-column contract ",
    "with NOT NULL TEXT/INTEGER declarations in this order: ",
    paste(PIPELINE_PACKET_COLUMNS, collapse = ", ")
  )
}

# Validate every row in bounded chunks before aggregation.  This rejects
# legacy 16-/64-character address formats and local wall-clock timestamps.
result_set <- DBI::dbSendQuery(
  connection,
  paste0("SELECT ", paste(PIPELINE_PACKET_COLUMNS, collapse = ", "), " FROM packets")
)
on.exit(if (DBI::dbIsValid(result_set)) DBI::dbClearResult(result_set), add = TRUE)

rows_validated <- 0
repeat {
  chunk <- DBI::dbFetch(result_set, n = 100000L)
  if (!nrow(chunk)) break

  parse_utc_z(chunk$timestamp, "packets.timestamp")
  validate_identifier(chunk$source_address, "packets.source_address")
  normalize_randomized_flag(
    chunk$source_address_randomized, "packets.source_address_randomized"
  )
  normalize_finite_double(chunk$strength, "packets.strength", -127, 0)
  channel <- suppressWarnings(as.numeric(chunk$channel))
  if (anyNA(channel) || any(!is.finite(channel)) ||
      any(channel != floor(channel)) || any(channel < 1 | channel > 14)) {
    stop_pipeline("packets.channel must contain integers from 1 through 14")
  }
  if (anyNA(chunk$type) || any(!chunk$type %in% c("management", "data"))) {
    stop_pipeline("packets.type must contain only 'management' or 'data'")
  }
  if (anyNA(chunk$subtype) || any(!nzchar(chunk$subtype))) {
    stop_pipeline("packets.subtype must contain non-empty values")
  }
  if (anyNA(chunk$sensor_name) ||
      any(!grepl("^[A-Za-z0-9_-]{1,32}$", chunk$sensor_name))) {
    stop_pipeline("packets.sensor_name must match [A-Za-z0-9_-]{1,32}")
  }
  rows_validated <- rows_validated + nrow(chunk)
}
DBI::dbClearResult(result_set)

flag_conflicts <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT source_address FROM packets",
    "GROUP BY source_address",
    "HAVING min(source_address_randomized) != max(source_address_randomized)",
    "LIMIT 1"
  )
)
if (nrow(flag_conflicts)) {
  stop_pipeline("A source_address is associated with conflicting randomized flags")
}

subtype_filter <- if (length(excluded_subtypes)) {
  quoted <- as.character(DBI::dbQuoteString(connection, excluded_subtypes))
  paste0("AND lower(subtype) NOT IN (", paste(quoted, collapse = ", "), ")")
} else {
  ""
}

sql <- sprintf(
  paste0(
    "WITH filtered AS (\n",
    "  SELECT substr(timestamp, 1, 19) || 'Z' AS timestamp,\n",
    "         source_address, sensor_name, source_address_randomized, strength\n",
    "  FROM packets\n",
    "  WHERE strength BETWEEN %.17g AND %.17g %s\n",
    "), ranked AS (\n",
    "  SELECT timestamp, source_address, sensor_name,\n",
    "         source_address_randomized, strength,\n",
    "         row_number() OVER (\n",
    "           PARTITION BY timestamp, source_address, sensor_name\n",
    "           ORDER BY strength\n",
    "         ) AS rank_in_second,\n",
    "         count(*) OVER (\n",
    "           PARTITION BY timestamp, source_address, sensor_name\n",
    "         ) AS packet_count\n",
    "  FROM filtered\n",
    ")\n",
    "SELECT timestamp, source_address, sensor_name,\n",
    "       min(source_address_randomized) AS source_address_randomized,\n",
    "       CAST(avg(strength) AS REAL) AS rssi_median,\n",
    "       packet_count\n",
    "FROM ranked\n",
    "WHERE rank_in_second IN (\n",
    "  CAST((packet_count + 1) / 2 AS INTEGER),\n",
    "  CAST((packet_count + 2) / 2 AS INTEGER)\n",
    ")\n",
    "GROUP BY timestamp, source_address, sensor_name, packet_count\n",
    "ORDER BY timestamp, source_address, sensor_name"
  ),
  rssi_min, rssi_max, subtype_filter
)

aggregated <- data.table::as.data.table(DBI::dbGetQuery(connection, sql))
assert_exact_columns(aggregated, PIPELINE_ONE_SECOND_COLUMNS, "aggregated one-second data")
aggregated <- normalize_one_second_table(
  aggregated, "aggregated one-second data", require_unique = TRUE
)
data.table::setorder(aggregated, timestamp, source_address, sensor_name)

write_pipeline_table(aggregated, output_path)
cat("Validated ", format(rows_validated, big.mark = ","), " packet rows.\n", sep = "")
report_stage("Aggregated 1-second", aggregated, output_path)
