#!/usr/bin/env Rscript

# Verify schemas, physical Parquet types, UTC alignment, key uniqueness,
# value ranges, and the exact cleaned-1-second -> 20-second calculation.

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), mustWork = TRUE)
source(file.path(dirname(script_path), "_common.R"))

usage <- function() {
  cat(paste0(
    "Usage:\n",
    "  Rscript 04_verify_pipeline.R \\\n",
    "    --one-second aggregated_1second.parquet \\\n",
    "    --cleaned-one-second cleaned_1second.parquet \\\n",
    "    --twenty-second analysis_20second.parquet\n"
  ))
}

raw_args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% raw_args) {
  usage()
  quit(status = 0L)
}
options <- parse_pipeline_args(raw_args)
reject_unknown_options(
  options, c("one_second", "cleaned_one_second", "twenty_second")
)
require_pipeline_args(options, c("one_second", "cleaned_one_second", "twenty_second"))
require_pipeline_packages(c("data.table", "bit64"))

one_second <- read_pipeline_table(
  options$one_second, PIPELINE_ONE_SECOND_COLUMNS, "aggregated one-second input"
)
one_second <- normalize_one_second_table(
  one_second, "aggregated one-second input", require_unique = TRUE
)

cleaned <- read_pipeline_table(
  options$cleaned_one_second, PIPELINE_ONE_SECOND_COLUMNS, "cleaned one-second input"
)
cleaned <- normalize_one_second_table(
  cleaned, "cleaned one-second input", require_unique = TRUE
)
if (nrow(cleaned) && any(cleaned$source_address_randomized != 0L)) {
  stop_pipeline("Cleaned one-second data contains a randomized-address row")
}

twenty_second <- read_pipeline_table(
  options$twenty_second, PIPELINE_TWENTY_SECOND_COLUMNS, "20-second input"
)
twenty_second[, timestamp := parse_utc_z(
  timestamp, "20-second timestamp", require_whole_second = TRUE
)]
twenty_second[, source_address := validate_identifier(
  source_address, "20-second source_address"
)]
if (anyNA(twenty_second$sensor_name) ||
    any(!grepl("^[A-Za-z0-9_-]{1,32}$", twenty_second$sensor_name))) {
  stop_pipeline("20-second sensor_name must match [A-Za-z0-9_-]{1,32}")
}
twenty_second[, sensor_name := as.character(sensor_name)]
twenty_second[, rssi_median := normalize_finite_double(
  rssi_median, "20-second rssi_median", -127, 0
)]
twenty_second[, rssi_sum := normalize_finite_double(
  rssi_sum, "20-second rssi_sum"
)]
twenty_second[, detections := normalize_positive_int64(
  detections, "20-second detections"
)]
twenty_second[, strength_sum := normalize_finite_double(
  strength_sum, "20-second strength_sum"
)]
assert_unique_key(
  twenty_second,
  c("timestamp", "source_address", "sensor_name"),
  "20-second data"
)

epoch <- as.numeric(twenty_second$timestamp)
if (any(abs(epoch %% PIPELINE_WINDOW_SECONDS) > 1e-6)) {
  stop_pipeline("20-second timestamps are not aligned to UTC epoch boundaries")
}
detections_numeric <- as.numeric(twenty_second$detections)
if (any(detections_numeric < 1 | detections_numeric > PIPELINE_WINDOW_SECONDS)) {
  stop_pipeline("20-second detections must be integers from 1 through 20")
}
if (any(abs(
  twenty_second$strength_sum -
    (100 * detections_numeric + twenty_second$rssi_sum)
) > 1e-9)) {
  stop_pipeline("strength_sum must equal 100 * detections + rssi_sum")
}

# Verify the full aggregation, not only row-local invariants.
expected <- build_twenty_second(data.table::copy(cleaned))
actual <- data.table::copy(twenty_second)
key <- c("timestamp", "source_address", "sensor_name")
data.table::setkeyv(expected, key)
data.table::setkeyv(actual, key)
if (nrow(expected) != nrow(actual) || !identical(expected[, ..key], actual[, ..key])) {
  stop_pipeline("20-second keys do not exactly match the cleaned one-second input")
}
if (
  any(abs(expected$rssi_median - actual$rssi_median) > 1e-9) ||
  any(abs(expected$rssi_sum - actual$rssi_sum) > 1e-9) ||
  any(expected$detections != actual$detections) ||
  any(abs(expected$strength_sum - actual$strength_sum) > 1e-9)
) {
  stop_pipeline("20-second values do not exactly reproduce the maintained aggregation")
}

for (entry in list(
  list(
    path = options$one_second,
    expected = c(
      timestamp = "timestamp[us, tz=UTC]", source_address = "string",
      sensor_name = "string", source_address_randomized = "int32",
      rssi_median = "double", packet_count = "int64"
    ),
    label = "aggregated one-second"
  ),
  list(
    path = options$cleaned_one_second,
    expected = c(
      timestamp = "timestamp[us, tz=UTC]", source_address = "string",
      sensor_name = "string", source_address_randomized = "int32",
      rssi_median = "double", packet_count = "int64"
    ),
    label = "cleaned one-second"
  ),
  list(
    path = options$twenty_second,
    expected = c(
      timestamp = "timestamp[us, tz=UTC]", source_address = "string",
      sensor_name = "string", rssi_median = "double", rssi_sum = "double",
      detections = "int64", strength_sum = "double"
    ),
    label = "20-second"
  )
)) {
  if (tolower(tools::file_ext(entry$path)) == "parquet") {
    actual_types <- parquet_schema_types(entry$path)
    if (!identical(actual_types, entry$expected)) {
      stop_pipeline(
        entry$label, " Parquet physical schema mismatch. Expected ",
        paste(names(entry$expected), entry$expected, sep = "=", collapse = ", "),
        "; found ",
        paste(names(actual_types), actual_types, sep = "=", collapse = ", ")
      )
    }
  } else {
    warning(
      entry$label,
      " is CSV; values were verified, but CSV cannot preserve Parquet physical types",
      call. = FALSE
    )
  }
}

cat(
  "PASS: maintained pipeline verified\n",
  "  one-second rows: ", format(nrow(one_second), big.mark = ","), "\n",
  "  cleaned rows:    ", format(nrow(cleaned), big.mark = ","), "\n",
  "  20-second rows:  ", format(nrow(twenty_second), big.mark = ","), "\n",
  "  timestamps:      explicit UTC (Z / Parquet tz=UTC)\n",
  "  local calendar:  derive explicitly with tz='", PIPELINE_LOCAL_TIMEZONE, "'\n",
  sep = ""
)
