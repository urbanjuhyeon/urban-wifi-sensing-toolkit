# Shared helpers for the maintained SQLite -> 1-second -> 20-second pipeline.
#
# This code intentionally does not source the historical 0-* scripts.  The
# maintained capture database already contains a 32-character, deployment-
# scoped HMAC pseudonym and a pre-HMAC locally administered address flag;
# neither the original address nor the HMAC key is available to this pipeline.

PIPELINE_PACKET_COLUMNS <- c(
  "timestamp", "type", "subtype", "strength", "source_address",
  "source_address_randomized", "channel", "sensor_name"
)

PIPELINE_ONE_SECOND_COLUMNS <- c(
  "timestamp", "source_address", "sensor_name",
  "source_address_randomized", "rssi_median", "packet_count"
)

PIPELINE_TWENTY_SECOND_COLUMNS <- c(
  "timestamp", "source_address", "sensor_name", "rssi_median", "rssi_sum",
  "detections", "strength_sum"
)

PIPELINE_LOCAL_TIMEZONE <- "Asia/Seoul"
PIPELINE_WINDOW_SECONDS <- 20L
PIPELINE_IDENTIFIER_SCHEME <- "hmac-sha256-128-v1"
PIPELINE_IDENTIFIER_HEX_LENGTH <- 32L
PIPELINE_IDENTIFIER_PATTERN <- paste0(
  "^[0-9a-f]{", PIPELINE_IDENTIFIER_HEX_LENGTH, "}$"
)

stop_pipeline <- function(...) {
  stop(..., call. = FALSE)
}

require_pipeline_packages <- function(packages) {
  missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) {
    stop_pipeline(
      "Missing R package(s): ", paste(missing, collapse = ", "),
      ". Install them before running this pipeline."
    )
  }
}

parse_pipeline_args <- function(args, defaults = list(), flags = character()) {
  result <- defaults
  index <- 1L

  while (index <= length(args)) {
    token <- args[[index]]
    if (!startsWith(token, "--") || nchar(token) <= 2L) {
      stop_pipeline("Unexpected command-line argument: ", token)
    }

    key <- sub("^--", "", token)
    key_r <- gsub("-", "_", key, fixed = TRUE)
    if (key %in% flags) {
      result[[key_r]] <- TRUE
      index <- index + 1L
      next
    }

    if (index == length(args) || startsWith(args[[index + 1L]], "--")) {
      stop_pipeline("Option --", key, " requires a value")
    }
    result[[key_r]] <- args[[index + 1L]]
    index <- index + 2L
  }
  result
}

require_pipeline_args <- function(options, names) {
  missing <- names[vapply(names, function(name) {
    value <- options[[name]]
    is.null(value) || length(value) != 1L || is.na(value) || !nzchar(value)
  }, logical(1))]
  if (length(missing)) {
    stop_pipeline(
      "Missing required option(s): ",
      paste0("--", gsub("_", "-", missing, fixed = TRUE), collapse = ", ")
    )
  }
}

reject_unknown_options <- function(options, allowed) {
  unknown <- setdiff(names(options), allowed)
  if (length(unknown)) {
    stop_pipeline(
      "Unknown option(s): ",
      paste0("--", gsub("_", "-", unknown, fixed = TRUE), collapse = ", ")
    )
  }
  invisible(TRUE)
}

parse_finite_number <- function(value, label) {
  parsed <- suppressWarnings(as.numeric(value))
  if (length(parsed) != 1L || is.na(parsed) || !is.finite(parsed)) {
    stop_pipeline(label, " must be one finite number")
  }
  parsed
}

parse_positive_number <- function(value, label) {
  parsed <- parse_finite_number(value, label)
  if (parsed <= 0) stop_pipeline(label, " must be greater than zero")
  parsed
}

parse_output_format <- function(value) {
  value <- tolower(value)
  if (!value %in% c("parquet", "csv")) {
    stop_pipeline("--format must be 'parquet' or 'csv'")
  }
  value
}

assert_input_file <- function(path, label = "input") {
  if (!file.exists(path) || dir.exists(path)) {
    stop_pipeline(label, " file does not exist: ", path)
  }
  normalizePath(path, winslash = "/", mustWork = TRUE)
}

assert_exact_columns <- function(data, expected, label) {
  actual <- names(data)
  if (!identical(actual, expected)) {
    stop_pipeline(
      label, " columns must be exactly (and in this order): ",
      paste(expected, collapse = ", "), ". Found: ",
      paste(actual, collapse = ", ")
    )
  }
  invisible(TRUE)
}

validate_identifier <- function(value, label = "source_address") {
  valid <- !is.na(value) & grepl(
    PIPELINE_IDENTIFIER_PATTERN, as.character(value)
  )
  if (!all(valid)) {
    example <- as.character(value[which(!valid)[1L]])
    stop_pipeline(
      label, " must contain only ", PIPELINE_IDENTIFIER_HEX_LENGTH,
      "-character lowercase hexadecimal values ",
      "under the ", PIPELINE_IDENTIFIER_SCHEME, " contract; ",
      "first invalid value: ", example
    )
  }
  as.character(value)
}

normalize_randomized_flag <- function(value, label = "source_address_randomized") {
  numeric_value <- suppressWarnings(as.numeric(value))
  valid <- !is.na(numeric_value) & is.finite(numeric_value) &
    numeric_value == floor(numeric_value) & numeric_value %in% c(0, 1)
  if (!all(valid)) {
    stop_pipeline(label, " must contain only integer 0 or 1 values")
  }
  as.integer(numeric_value)
}

normalize_positive_int64 <- function(value, label) {
  require_pipeline_packages("bit64")

  if (inherits(value, "integer64")) {
    text_value <- as.character(value)
  } else {
    numeric_value <- suppressWarnings(as.numeric(value))
    valid <- !is.na(numeric_value) & is.finite(numeric_value) &
      numeric_value >= 1 & numeric_value == floor(numeric_value) &
      numeric_value <= 2^53
    if (!all(valid)) {
      stop_pipeline(label, " must contain positive, exactly representable integers")
    }
    text_value <- format(numeric_value, scientific = FALSE, trim = TRUE)
  }

  if (anyNA(text_value) || !all(grepl("^[1-9][0-9]*$", text_value))) {
    stop_pipeline(label, " must contain positive integers")
  }
  bit64::as.integer64(text_value)
}

normalize_finite_double <- function(value, label, lower = -Inf, upper = Inf) {
  numeric_value <- suppressWarnings(as.numeric(value))
  valid <- !is.na(numeric_value) & is.finite(numeric_value) &
    numeric_value >= lower & numeric_value <= upper
  if (!all(valid)) {
    stop_pipeline(
      label, " must contain finite values in [", lower, ", ", upper, "]"
    )
  }
  as.double(numeric_value)
}

parse_utc_z <- function(value, label = "timestamp", require_whole_second = FALSE) {
  if (inherits(value, "POSIXt")) {
    timezone <- attr(value, "tzone")
    timezone <- if (length(timezone)) timezone[[1L]] else ""
    if (!timezone %in% c("UTC", "GMT", "Etc/UTC")) {
      stop_pipeline(
        label, " must carry explicit UTC timezone metadata; found '", timezone, "'"
      )
    }
    epoch <- as.numeric(value)
  } else {
    text_value <- as.character(value)
    pattern <- paste0(
      "^[0-9]{4}-[0-9]{2}-[0-9]{2}T",
      "[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$"
    )
    valid_shape <- !is.na(text_value) & grepl(pattern, text_value, perl = TRUE)
    if (!all(valid_shape)) {
      example <- text_value[which(!valid_shape)[1L]]
      stop_pipeline(
        label, " must use an explicit ISO-8601 UTC 'Z' timestamp; ",
        "first invalid value: ", example
      )
    }

    whole <- substr(text_value, 1L, 19L)
    parsed_whole <- as.POSIXct(
      whole, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"
    )
    round_trip <- format(parsed_whole, "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    valid_calendar <- !is.na(parsed_whole) & round_trip == whole
    if (!all(valid_calendar)) {
      example <- text_value[which(!valid_calendar)[1L]]
      stop_pipeline(label, " contains an invalid UTC calendar value: ", example)
    }

    has_fraction <- grepl("\\.", text_value)
    fraction <- numeric(length(text_value))
    if (any(has_fraction)) {
      fraction_digits <- sub(
        "^.*\\.([0-9]{1,9})Z$", "\\1", text_value[has_fraction], perl = TRUE
      )
      fraction[has_fraction] <- as.numeric(paste0("0.", fraction_digits))
    }
    epoch <- as.numeric(parsed_whole) + fraction
  }

  if (anyNA(epoch) || any(!is.finite(epoch))) {
    stop_pipeline(label, " contains an invalid timestamp")
  }
  if (require_whole_second && any(abs(epoch - round(epoch)) > 1e-6)) {
    stop_pipeline(label, " must be aligned to whole UTC seconds")
  }

  result <- as.POSIXct(epoch, origin = "1970-01-01", tz = "UTC")
  attr(result, "tzone") <- "UTC"
  result
}

format_utc_z <- function(value) {
  format(value, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC", usetz = FALSE)
}

assert_unique_key <- function(data, keys, label) {
  duplicates <- data[, .N, by = keys][N > 1L]
  if (nrow(duplicates)) {
    stop_pipeline(
      label, " must be unique by ", paste(keys, collapse = " x "),
      "; found ", nrow(duplicates), " duplicated key(s)"
    )
  }
  invisible(TRUE)
}

read_pipeline_table <- function(path, expected_columns, label) {
  require_pipeline_packages("data.table")
  path <- assert_input_file(path, label)
  extension <- tolower(tools::file_ext(path))

  if (extension == "parquet") {
    require_pipeline_packages("arrow")
    data <- arrow::read_parquet(path, as_data_frame = TRUE)
  } else if (extension == "csv") {
    data <- data.table::fread(path, na.strings = c("", "NA"))
  } else {
    stop_pipeline(label, " must be a .parquet or .csv file: ", path)
  }

  data <- data.table::as.data.table(data)
  assert_exact_columns(data, expected_columns, label)
  data
}

write_pipeline_table <- function(data, path) {
  require_pipeline_packages(c("data.table", "bit64"))
  extension <- tolower(tools::file_ext(path))
  if (!extension %in% c("parquet", "csv")) {
    stop_pipeline("Output must end in .parquet or .csv: ", path)
  }

  directory <- dirname(path)
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(directory)) stop_pipeline("Cannot create output directory: ", directory)

  normalized_directory <- normalizePath(directory, winslash = "/", mustWork = TRUE)
  target <- file.path(normalized_directory, basename(path))
  existing_link <- Sys.readlink(target)
  if (length(existing_link) && !is.na(existing_link) && nzchar(existing_link)) {
    stop_pipeline("Refusing to replace a symbolic-link output: ", target)
  }

  temporary <- paste0(
    target, ".tmp-", Sys.getpid(), "-", sprintf("%06d", sample.int(999999L, 1L))
  )
  on.exit(if (file.exists(temporary)) unlink(temporary), add = TRUE)

  if (extension == "parquet") {
    require_pipeline_packages("arrow")
    arrow::write_parquet(data, temporary, compression = "zstd")
  } else {
    csv_data <- data.table::copy(data)
    if ("timestamp" %in% names(csv_data)) {
      csv_data[, timestamp := format_utc_z(timestamp)]
    }
    data.table::fwrite(csv_data, temporary, quote = TRUE, na = "")
  }

  if (file.exists(target)) {
    unlink_status <- unlink(target)
    if (unlink_status != 0L || file.exists(target)) {
      stop_pipeline("Cannot replace existing output: ", target)
    }
  }
  if (!file.rename(temporary, target)) {
    stop_pipeline("Cannot move completed output into place: ", target)
  }
  invisible(target)
}

normalize_one_second_table <- function(data, label, require_unique = FALSE) {
  require_pipeline_packages(c("data.table", "bit64"))
  assert_exact_columns(data, PIPELINE_ONE_SECOND_COLUMNS, label)

  data[, timestamp := parse_utc_z(timestamp, paste0(label, " timestamp"), TRUE)]
  data[, source_address := validate_identifier(
    source_address, paste0(label, " source_address")
  )]
  if (anyNA(data$sensor_name) || any(!grepl("^[A-Za-z0-9_-]{1,32}$", data$sensor_name))) {
    stop_pipeline(label, " sensor_name must match [A-Za-z0-9_-]{1,32}")
  }
  data[, sensor_name := as.character(sensor_name)]
  data[, source_address_randomized := normalize_randomized_flag(
    source_address_randomized, paste0(label, " source_address_randomized")
  )]
  data[, rssi_median := normalize_finite_double(
    rssi_median, paste0(label, " rssi_median"), -127, 0
  )]
  data[, packet_count := normalize_positive_int64(
    packet_count, paste0(label, " packet_count")
  )]

  if (require_unique) {
    assert_unique_key(
      data, c("source_address", "sensor_name", "timestamp"), label
    )
  }
  data
}

deduplicate_one_second <- function(data, label) {
  require_pipeline_packages(c("data.table", "bit64"))
  key <- c("source_address", "sensor_name", "timestamp")

  inconsistent <- data[
    , .(n_flags = data.table::uniqueN(source_address_randomized)), by = key
  ][n_flags != 1L]
  if (nrow(inconsistent)) {
    stop_pipeline(
      label, " has a 1-second key associated with conflicting randomized flags"
    )
  }

  deduplicated <- data[
    , .(
      source_address_randomized = source_address_randomized[[1L]],
      rssi_median = as.double(stats::median(rssi_median)),
      packet_count = sum(packet_count)
    ),
    by = key
  ]
  data.table::setcolorder(deduplicated, PIPELINE_ONE_SECOND_COLUMNS)
  data.table::setorder(deduplicated, timestamp, source_address, sensor_name)
  assert_unique_key(deduplicated, key, paste0(label, " after deterministic deduplication"))
  deduplicated
}

build_twenty_second <- function(cleaned) {
  require_pipeline_packages(c("data.table", "bit64"))
  epoch <- as.numeric(cleaned$timestamp)
  cleaned[, window_timestamp := as.POSIXct(
    floor(epoch / PIPELINE_WINDOW_SECONDS) * PIPELINE_WINDOW_SECONDS,
    origin = "1970-01-01", tz = "UTC"
  )]
  attr(cleaned$window_timestamp, "tzone") <- "UTC"

  result <- cleaned[
    , .(
      rssi_median = as.double(stats::median(rssi_median)),
      rssi_sum = as.double(sum(rssi_median)),
      detections = bit64::as.integer64(.N)
    ),
    by = .(
      timestamp = window_timestamp,
      source_address,
      sensor_name
    )
  ]
  result[, strength_sum := as.double(100 * as.numeric(detections) + rssi_sum)]
  data.table::setcolorder(result, PIPELINE_TWENTY_SECOND_COLUMNS)
  data.table::setorder(result, timestamp, source_address, sensor_name)
  result
}

parquet_schema_types <- function(path) {
  require_pipeline_packages("arrow")
  table <- arrow::read_parquet(path, as_data_frame = FALSE)
  schema <- table$schema
  stats::setNames(vapply(names(table), function(name) {
    schema$GetFieldByName(name)$type$ToString()
  }, character(1)), names(table))
}

report_stage <- function(label, data, path) {
  devices <- if ("source_address" %in% names(data)) {
    data.table::uniqueN(data$source_address)
  } else {
    NA_integer_
  }
  cat(
    sprintf(
      "%s: %s rows | %s identifiers | %s\n",
      label,
      format(nrow(data), big.mark = ",", scientific = FALSE),
      format(devices, big.mark = ",", scientific = FALSE),
      normalizePath(path, winslash = "/", mustWork = TRUE)
    )
  )
}
