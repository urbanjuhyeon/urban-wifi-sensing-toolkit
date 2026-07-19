# Build an isolated public-handoff candidate by replacing each historical
# internal pseudonym with a release- and dataset-specific keyed pseudonym.
# No mapping or key material is written to the candidate directory.

suppressPackageStartupMessages({
  library(arrow)
  library(DBI)
  library(digest)
  library(duckdb)
})

PUBLIC_CANDIDATE_VERSION <- "historical-v4-public-candidate-1"
HISTORICAL_CANDIDATE_VERSION <- "historical-v4-candidate-1"
LOCAL_TIMEZONE <- "Asia/Seoul"

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript")
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), winslash = "/")
script_dir <- dirname(script_path)
base_dir <- normalizePath(file.path(script_dir, "../.."), winslash = "/")
source(file.path(script_dir, "_release_hmac.R"), local = TRUE)

argument_value <- function(name, required = TRUE) {
  prefix <- paste0("--", name, "=")
  matches <- commandArgs(TRUE)[startsWith(commandArgs(TRUE), prefix)]
  if (length(matches) > 1L) stop("Duplicate argument: --", name)
  if (!length(matches)) {
    if (required) stop("Missing required argument: --", name, "=<path>")
    return(NULL)
  }
  value <- substring(matches[[1L]], nchar(prefix) + 1L)
  if (!nzchar(value)) stop("Empty argument: --", name)
  value
}

input_root <- normalizePath(
  file.path(base_dir, "tmp/historical-v4-audit"),
  winslash = "/",
  mustWork = TRUE
)
output_root <- normalizePath(
  file.path(base_dir, "tmp/public-release-handoff"),
  winslash = "/",
  mustWork = FALSE
)
input_dir_value <- argument_value("input", required = FALSE)
input_dir <- normalizePath(
  if (is.null(input_dir_value)) {
    file.path(input_root, HISTORICAL_CANDIDATE_VERSION)
  } else {
    input_dir_value
  },
  winslash = "/",
  mustWork = TRUE
)
output_dir_value <- argument_value("output", required = FALSE)
output_dir <- normalizePath(
  if (is.null(output_dir_value)) {
    file.path(output_root, PUBLIC_CANDIDATE_VERSION)
  } else {
    output_dir_value
  },
  winslash = "/",
  mustWork = FALSE
)
if (!is_within_path(input_dir, input_root)) {
  stop("Input must remain under tmp/historical-v4-audit")
}
if (!is_within_path(output_dir, output_root)) {
  stop("Output must remain under tmp/public-release-handoff")
}
if (file.exists(output_dir) || dir.exists(output_dir)) {
  stop("Refusing to overwrite an existing public-handoff candidate")
}
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

campus_key <- read_release_key(
  argument_value("campus-key-file"), repository_root = base_dir
)
district_key <- read_release_key(
  argument_value("district-key-file"), repository_root = base_dir
)
if (identical(campus_key, district_key)) {
  stop("Each dataset must use a different release key")
}

input_paths <- list(
  campus = file.path(input_dir, "wifi_unist19_20sec_v4-candidate.parquet"),
  district = file.path(input_dir, "wifi_uou20_20sec_v4-candidate.parquet"),
  manifest = file.path(input_dir, "candidate_manifest.csv")
)
missing_inputs <- names(input_paths)[!file.exists(unlist(input_paths))]
if (length(missing_inputs)) {
  stop("Missing historical candidate input(s): ", paste(missing_inputs, collapse = ", "))
}

input_manifest <- read.csv(input_paths$manifest, stringsAsFactors = FALSE)
required_manifest_columns <- c("candidate_version", "file", "sha256", "timezone")
if (!all(required_manifest_columns %in% names(input_manifest))) {
  stop("Historical candidate manifest is outside the required contract")
}
if (
  nrow(input_manifest) != 2L ||
    any(input_manifest$candidate_version != HISTORICAL_CANDIDATE_VERSION) ||
    any(input_manifest$timezone != "UTC")
) {
  stop("Historical candidate manifest has an unexpected version or timezone")
}
for (path in input_paths[c("campus", "district")]) {
  row <- input_manifest[input_manifest$file == basename(path), , drop = FALSE]
  if (nrow(row) != 1L) stop("Input file is missing from the historical manifest")
  actual <- digest(path, algo = "sha256", file = TRUE)
  if (!identical(actual, row$sha256[[1L]])) {
    stop("Historical candidate checksum mismatch; refusing public handoff")
  }
}

staging_dir <- paste0(output_dir, ".building-", Sys.getpid())
if (file.exists(staging_dir) || dir.exists(staging_dir)) {
  stop("Refusing an existing staging directory")
}
dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)
completed <- FALSE
on.exit({
  if (!completed && dir.exists(staging_dir)) {
    unlink(staging_dir, recursive = TRUE, force = TRUE)
  }
}, add = TRUE)

output_paths <- list(
  campus = file.path(staging_dir, "wifi_unist19_20sec_public-candidate.parquet"),
  district = file.path(staging_dir, "wifi_uou20_20sec_public-candidate.parquet"),
  manifest = file.path(staging_dir, "public_handoff_manifest.csv"),
  report = file.path(staging_dir, "build_report.md")
)

sql_path <- function(path) {
  gsub("'", "''", normalizePath(path, winslash = "/", mustWork = FALSE))
}

attach_utc_metadata <- function(path, column = "timestamp") {
  table <- arrow::read_parquet(path, as_data_frame = FALSE)
  index <- match(column, names(table)) - 1L
  if (is.na(index)) stop("Timestamp column not found: ", column)
  utc_type <- arrow::timestamp("us", timezone = "UTC")
  utc_column <- table$GetColumnByName(column)$cast(utc_type)
  table <- table$SetColumn(index, arrow::field(column, utc_type), utc_column)
  temporary <- paste0(path, ".utc.tmp.parquet")
  if (file.exists(temporary)) unlink(temporary)
  arrow::write_parquet(table, temporary, compression = "zstd")
  check <- arrow::read_parquet(temporary, col_select = tidyselect::all_of(column))
  if (!identical(attr(check[[column]], "tzone"), "UTC")) {
    unlink(temporary)
    stop("Failed to attach UTC metadata")
  }
  if (file.exists(path)) unlink(path)
  if (!file.rename(temporary, path)) stop("Failed to install UTC Parquet")
}

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit({
  if (!is.null(con)) dbDisconnect(con, shutdown = TRUE)
}, add = TRUE)
invisible(dbExecute(con, "SET threads=1"))
invisible(dbExecute(con, sprintf(
  "SET temp_directory='%s'", sql_path(file.path(staging_dir, "duckdb-temp"))
)))

read_internal_ids <- function(path) {
  dbGetQuery(con, sprintf(
    "SELECT DISTINCT CAST(source_address AS VARCHAR) AS source_address
     FROM read_parquet('%s') ORDER BY 1",
    sql_path(path)
  ))$source_address
}

cat("Preparing in-memory one-to-one release mappings...\n")
campus_mapping <- build_release_mapping(
  read_internal_ids(input_paths$campus), "unist19", campus_key
)
district_mapping <- build_release_mapping(
  read_internal_ids(input_paths$district), "uou20", district_key
)
if (length(intersect(
  campus_mapping$public_source_address,
  district_mapping$public_source_address
))) {
  stop("Cross-dataset public-identifier collision detected")
}
dbWriteTable(con, "campus_release_mapping", campus_mapping, temporary = TRUE)
dbWriteTable(con, "district_release_mapping", district_mapping, temporary = TRUE)

build_dataset <- function(input_path, output_path, mapping_table) {
  invisible(dbExecute(con, sprintf(
    "COPY (
       SELECT
         i.timestamp,
         m.public_source_address AS source_address,
         CAST(i.sensor_name AS VARCHAR) AS sensor_name,
         CAST(i.rssi_median AS DOUBLE) AS rssi_median,
         CAST(i.rssi_sum AS DOUBLE) AS rssi_sum,
         CAST(i.detections AS BIGINT) AS detections,
         CAST(i.strength_sum AS DOUBLE) AS strength_sum
       FROM read_parquet('%s') AS i
       INNER JOIN %s AS m
         ON CAST(i.source_address AS VARCHAR) = m.internal_source_address
       ORDER BY 1, 2, 3
     ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sql_path(input_path), mapping_table, sql_path(output_path)
  )))
  attach_utc_metadata(output_path)
}

cat("Building campus public-handoff candidate...\n")
build_dataset(input_paths$campus, output_paths$campus, "campus_release_mapping")
cat("Building commercial-district public-handoff candidate...\n")
build_dataset(input_paths$district, output_paths$district, "district_release_mapping")

summarize_output <- function(dataset_id, site, input_path, output_path) {
  summary <- dbGetQuery(con, sprintf(
    "SELECT
       count(*) AS n_records,
       count(DISTINCT source_address) AS n_pseudonyms,
       count(DISTINCT sensor_name) AS n_sensors,
       min(make_timestamp(epoch_us(timestamp))) AS start_utc,
       max(make_timestamp(epoch_us(timestamp))) AS end_utc,
       sum(detections) AS total_detections
     FROM read_parquet('%s')",
    sql_path(output_path)
  ))
  data.frame(
    public_candidate_version = PUBLIC_CANDIDATE_VERSION,
    historical_candidate_version = HISTORICAL_CANDIDATE_VERSION,
    dataset_id = dataset_id,
    site = site,
    file = basename(output_path),
    size_bytes = file.info(output_path)$size,
    sha256 = digest(output_path, algo = "sha256", file = TRUE),
    input_file = basename(input_path),
    input_sha256 = digest(input_path, algo = "sha256", file = TRUE),
    timezone = "UTC",
    local_timezone = LOCAL_TIMEZONE,
    identifier_algorithm = RELEASE_HMAC_ALGORITHM,
    identifier_scheme_version = RELEASE_HMAC_SCHEME_VERSION,
    identifier_scope = "release-dataset",
    identifier_hex_length = RELEASE_IDENTIFIER_HEX_LENGTH,
    summary,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

manifest <- rbind(
  summarize_output(
    "unist19", "UNIST campus", input_paths$campus, output_paths$campus
  ),
  summarize_output(
    "uou20", "Commercial district", input_paths$district, output_paths$district
  )
)
write.csv(manifest, output_paths$manifest, row.names = FALSE, na = "")

report <- c(
  "# Public-handoff candidate build",
  "",
  paste0("Candidate: `", PUBLIC_CANDIDATE_VERSION, "`"),
  "",
  paste0(
    "This isolated candidate replaces each internal historical pseudonym with ",
    "a 32-character release- and dataset-specific keyed pseudonym. Identical ",
    "internal pseudonyms remain identical within one released dataset. The two ",
    "datasets use separate keys and contexts."
  ),
  "",
  paste0(
    "No key, key fingerprint, identifier mapping, packet-level record, or ",
    "one-second source is included in this directory. The transformation does ",
    "not claim that the 2019 or 2020 collectors used HMAC at capture."
  ),
  "",
  paste0(
    "These records remain pseudonymous rather than anonymous because each ",
    "identifier is intentionally consistent within its dataset. Building this ",
    "candidate is not authorization for open release; access and disclosure ",
    "review remain separate release gates."
  ),
  "",
  "Run `verify_public_release_candidate.R` with the same private key files before any handoff."
)
writeLines(report, output_paths$report, useBytes = TRUE)

dbDisconnect(con, shutdown = TRUE)
con <- NULL
duckdb_temp <- file.path(staging_dir, "duckdb-temp")
if (dir.exists(duckdb_temp)) unlink(duckdb_temp, recursive = TRUE, force = TRUE)
if (!file.rename(staging_dir, output_dir)) {
  stop("Failed to install the completed public-handoff candidate")
}
completed <- TRUE
cat("Built isolated candidate: ", basename(output_dir), "\n", sep = "")
cat("No release key or identifier mapping was written.\n")
