# Verify a keyless, allowlisted professor-review public-data package. This
# script reads no release key, writes nothing inside the package, and does not
# authorize or perform an upload.

suppressPackageStartupMessages({
  library(arrow)
  library(DBI)
  library(digest)
  library(duckdb)
  library(sf)
})

PACKAGE_VERSION <- "historical-v4-public-package-candidate-1"
PUBLIC_CANDIDATE_VERSION <- "historical-v4-public-candidate-1"
EXPECTED_PARQUET_COLUMNS <- c(
  "timestamp", "source_address", "sensor_name", "rssi_median", "rssi_sum",
  "detections", "strength_sum"
)
EXPECTED_PACKAGE_FILES <- sort(c(
  "DATA_DICTIONARY.md", "MANIFEST.sha256", "README.md", "SOURCE_EVIDENCE.csv",
  "build_report.md", "public_handoff_manifest.csv", "sensor_coordinates.csv",
  "verification_checks.csv", "verification_report.md",
  "wifi_unist19_20sec.parquet", "wifi_uou20_20sec.parquet"
))
EXPECTED_SOURCE_CHECK_IDS <- sort(c(
  "candidate_file_allowlist", "unist19_schema_columns", "unist19_utc_metadata",
  "unist19_row_count", "unist19_identifier_bijection",
  "unist19_public_identifier_contract", "unist19_unique_20second_keys",
  "unist19_exact_nonidentifier_values", "unist19_internal_public_separation",
  "uou20_schema_columns", "uou20_utc_metadata", "uou20_row_count",
  "uou20_identifier_bijection", "uou20_public_identifier_contract",
  "uou20_unique_20second_keys", "uou20_exact_nonidentifier_values",
  "uou20_internal_public_separation", "cross_dataset_identifier_separation",
  "manifest_contract", "manifest_file_integrity"
))

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript", call. = FALSE)
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), winslash = "/")
base_dir <- normalizePath(file.path(dirname(script_path), "../.."), winslash = "/")

argument_value <- function(name, required = FALSE) {
  prefix <- paste0("--", name, "=")
  matches <- commandArgs(TRUE)[startsWith(commandArgs(TRUE), prefix)]
  if (length(matches) > 1L) stop("Duplicate argument: --", name, call. = FALSE)
  if (!length(matches)) {
    if (required) stop("Missing required argument: --", name, "=<path>", call. = FALSE)
    return(NULL)
  }
  value <- substring(matches[[1L]], nchar(prefix) + 1L)
  if (!nzchar(value)) stop("Empty argument: --", name, call. = FALSE)
  value
}

is_within <- function(path, parent) {
  path <- tolower(chartr("\\", "/", normalizePath(path, winslash = "/", mustWork = FALSE)))
  parent <- tolower(chartr("\\", "/", normalizePath(parent, winslash = "/", mustWork = FALSE)))
  identical(path, parent) || startsWith(path, paste0(parent, "/"))
}

package_root <- normalizePath(
  file.path(base_dir, "tmp/public-data-package"), winslash = "/", mustWork = TRUE
)
verification_root <- file.path(base_dir, "tmp/public-data-package-verification")
package_value <- argument_value("package")
package_dir <- normalizePath(
  if (is.null(package_value)) file.path(package_root, PACKAGE_VERSION) else package_value,
  winslash = "/", mustWork = TRUE
)
output_value <- argument_value("output")
output_dir <- normalizePath(
  if (is.null(output_value)) file.path(verification_root, PACKAGE_VERSION) else output_value,
  winslash = "/", mustWork = FALSE
)
if (!is_within(package_dir, package_root) || identical(package_dir, package_root)) {
  stop("Package must remain below tmp/public-data-package", call. = FALSE)
}
if (!is_within(output_dir, verification_root) || identical(output_dir, verification_root)) {
  stop("Verification output must remain below tmp/public-data-package-verification", call. = FALSE)
}
if (file.exists(output_dir) || dir.exists(output_dir)) {
  stop("Refusing to overwrite an existing package-verification output", call. = FALSE)
}

actual_entries <- list.files(
  package_dir, all.files = TRUE, no.. = TRUE, recursive = TRUE,
  include.dirs = TRUE
)
actual_files <- sort(list.files(
  package_dir, all.files = TRUE, no.. = TRUE, recursive = TRUE,
  include.dirs = FALSE
))
if (!identical(actual_entries, actual_files) || !identical(actual_files, EXPECTED_PACKAGE_FILES)) {
  stop("Package file allowlist mismatch or unexpected subdirectory", call. = FALSE)
}
package_paths <- file.path(package_dir, actual_files)
links <- Sys.readlink(package_paths)
if (any(!is.na(links) & nzchar(links))) {
  stop("Package contains a symbolic-link file", call. = FALSE)
}
path_for <- function(name) file.path(package_dir, name)

checks <- data.frame(
  check_id = character(), passed = logical(), evidence = character(),
  stringsAsFactors = FALSE
)
add_check <- function(check_id, passed, evidence) {
  checks <<- rbind(
    checks,
    data.frame(
      check_id = check_id, passed = isTRUE(passed),
      evidence = as.character(evidence), stringsAsFactors = FALSE
    )
  )
}
add_check(
  "package_file_allowlist", TRUE,
  paste(length(actual_files), "top-level package files match the fixed allowlist")
)

manifest_lines <- readLines(path_for("MANIFEST.sha256"), warn = FALSE, encoding = "ASCII")
manifest_pattern <- "^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9_.-]*)$"
manifest_valid <- length(manifest_lines) == length(EXPECTED_PACKAGE_FILES) - 1L &&
  all(grepl(manifest_pattern, manifest_lines))
manifest_names <- if (manifest_valid) sub(manifest_pattern, "\\2", manifest_lines) else character()
manifest_hashes <- if (manifest_valid) sub(manifest_pattern, "\\1", manifest_lines) else character()
expected_manifest_names <- setdiff(EXPECTED_PACKAGE_FILES, "MANIFEST.sha256")
manifest_valid <- manifest_valid && !anyDuplicated(manifest_names) &&
  identical(manifest_names, sort(manifest_names, method = "radix")) &&
  identical(
    sort(manifest_names, method = "radix"),
    sort(expected_manifest_names, method = "radix")
  )
if (manifest_valid) {
  names(manifest_hashes) <- manifest_names
  manifest_valid <- all(vapply(
    manifest_names,
    function(name) identical(
      manifest_hashes[[name]], digest(path_for(name), algo = "sha256", file = TRUE)
    ),
    logical(1)
  ))
}
add_check(
  "all_file_sha256_manifest", manifest_valid,
  "MANIFEST.sha256 has one sorted lowercase SHA-256 entry for every other file"
)

source_checks <- read.csv(path_for("verification_checks.csv"), stringsAsFactors = FALSE)
source_checks_valid <- identical(
  names(source_checks), c("check_id", "passed", "evidence")
) && !anyNA(source_checks) && identical(
  sort(source_checks$check_id), EXPECTED_SOURCE_CHECK_IDS
) && all(as.logical(source_checks$passed))
add_check(
  "source_verification_checks", source_checks_valid,
  "all 20 independently generated public-handoff source checks are present and true"
)

source_manifest <- read.csv(
  path_for("public_handoff_manifest.csv"), stringsAsFactors = FALSE
)
required_manifest_columns <- c(
  "public_candidate_version", "historical_candidate_version", "dataset_id",
  "site", "file", "size_bytes", "sha256", "input_file", "input_sha256",
  "timezone", "local_timezone", "identifier_algorithm",
  "identifier_scheme_version", "identifier_scope", "identifier_hex_length",
  "n_records", "n_pseudonyms", "n_sensors", "start_utc", "end_utc",
  "total_detections"
)
source_manifest_valid <- identical(names(source_manifest), required_manifest_columns) &&
  nrow(source_manifest) == 2L && !anyNA(source_manifest) &&
  all(source_manifest$public_candidate_version == PUBLIC_CANDIDATE_VERSION) &&
  setequal(source_manifest$dataset_id, c("unist19", "uou20")) &&
  all(source_manifest$timezone == "UTC") &&
  all(source_manifest$local_timezone == "Asia/Seoul") &&
  all(source_manifest$identifier_algorithm == "hmac-sha256") &&
  all(source_manifest$identifier_scheme_version == 1L) &&
  all(source_manifest$identifier_scope == "release-dataset") &&
  all(source_manifest$identifier_hex_length == 32L)
add_check(
  "source_manifest_contract", source_manifest_valid,
  "source manifest has the exact two-dataset release-specific HMAC contract"
)

evidence <- read.csv(path_for("SOURCE_EVIDENCE.csv"), stringsAsFactors = FALSE)
evidence_valid <- identical(
  names(evidence),
  c("evidence_id", "source_role", "repository_relative_path", "size_bytes", "sha256", "verification")
) && nrow(evidence) == 9L && !anyNA(evidence) &&
  !anyDuplicated(evidence$evidence_id) &&
  all(grepl("^[0-9a-f]{64}$", evidence$sha256)) &&
  all(!grepl("^[A-Za-z]:|^[/\\\\]|(^|[/\\\\])\\.\\.([/\\\\]|$)", evidence$repository_relative_path))
if (evidence_valid) {
  evidence_valid <- all(vapply(seq_len(nrow(evidence)), function(index) {
    source_path <- normalizePath(
      file.path(base_dir, evidence$repository_relative_path[[index]]),
      winslash = "/", mustWork = TRUE
    )
    is_within(source_path, base_dir) &&
      identical(as.numeric(evidence$size_bytes[[index]]), file.info(source_path)$size) &&
      identical(evidence$sha256[[index]], digest(source_path, algo = "sha256", file = TRUE))
  }, logical(1)))
}
add_check(
  "source_evidence_integrity", evidence_valid,
  "nine repository-relative source and coordinate-provenance files match recorded sizes and SHA-256 values"
)

sensor_coordinates <- read.csv(
  path_for("sensor_coordinates.csv"), stringsAsFactors = FALSE
)
sensor_columns <- c(
  "dataset_id", "site", "sensor_name", "longitude", "latitude", "crs_epsg"
)
sensor_base_valid <- identical(names(sensor_coordinates), sensor_columns) &&
  nrow(sensor_coordinates) == 41L && !anyNA(sensor_coordinates) &&
  !anyDuplicated(sensor_coordinates[, c("dataset_id", "sensor_name")]) &&
  setequal(sensor_coordinates$dataset_id, c("unist19", "uou20")) &&
  all(sensor_coordinates$crs_epsg == 4326L) &&
  all(is.finite(sensor_coordinates$longitude)) &&
  all(is.finite(sensor_coordinates$latitude)) &&
  all(sensor_coordinates$longitude >= -180 & sensor_coordinates$longitude <= 180) &&
  all(sensor_coordinates$latitude >= -90 & sensor_coordinates$latitude <= 90) &&
  all(sensor_coordinates$site[sensor_coordinates$dataset_id == "unist19"] ==
        "UNIST campus") &&
  all(sensor_coordinates$site[sensor_coordinates$dataset_id == "uou20"] ==
        "Commercial district")
add_check(
  "sensor_coordinate_contract", sensor_base_valid,
  "41 unique dataset-sensor rows have finite longitude/latitude in EPSG:4326"
)

campus_source <- st_read(
  file.path(base_dir, "workflow/unist19_main/data/sensors.gpkg"),
  layer = "sensors", quiet = TRUE
)
campus_source <- st_transform(campus_source, 4326)
campus_xy <- st_coordinates(campus_source)
district_source <- read.csv(
  file.path(base_dir, "workflow/uou20/output/sensors_coords.csv"),
  stringsAsFactors = FALSE
)
expected_coordinates <- rbind(
  data.frame(
    dataset_id = "unist19", site = "UNIST campus",
    sensor_name = as.character(campus_source$sensor_name),
    longitude = as.numeric(campus_xy[, "X"]),
    latitude = as.numeric(campus_xy[, "Y"]), crs_epsg = 4326L,
    stringsAsFactors = FALSE
  ),
  data.frame(
    dataset_id = "uou20", site = "Commercial district",
    sensor_name = as.character(district_source$id_sensor),
    longitude = as.numeric(district_source$x),
    latitude = as.numeric(district_source$y), crs_epsg = 4326L,
    stringsAsFactors = FALSE
  )
)
order_columns <- c("dataset_id", "sensor_name")
expected_coordinates <- expected_coordinates[
  do.call(order, expected_coordinates[order_columns]), sensor_columns
]
actual_coordinates <- sensor_coordinates[
  do.call(order, sensor_coordinates[order_columns]), sensor_columns
]
coordinate_text_columns <- setdiff(
  sensor_columns, c("longitude", "latitude")
)
coordinate_values_match <- all(vapply(
  coordinate_text_columns,
  function(name) identical(actual_coordinates[[name]], expected_coordinates[[name]]),
  logical(1)
)) && isTRUE(all.equal(
  actual_coordinates$longitude, expected_coordinates$longitude,
  tolerance = 1e-12, check.attributes = FALSE
)) && isTRUE(all.equal(
  actual_coordinates$latitude, expected_coordinates$latitude,
  tolerance = 1e-12, check.attributes = FALSE
))
add_check(
  "sensor_coordinate_source_values", coordinate_values_match,
  "all 41 packaged coordinates independently reproduce the two hashed source files"
)

sql_path <- function(path) {
  gsub("'", "''", normalizePath(path, winslash = "/", mustWork = TRUE))
}
temporary_root <- file.path(
  base_dir, "tmp/public-data-package-verification", paste0("duckdb-", Sys.getpid())
)
dir.create(temporary_root, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(temporary_root, recursive = TRUE, force = TRUE), add = TRUE)
con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit({
  if (!is.null(con)) dbDisconnect(con, shutdown = TRUE)
  if (dir.exists(temporary_root)) {
    unlink(temporary_root, recursive = TRUE, force = TRUE)
  }
}, add = TRUE, after = FALSE)
invisible(dbExecute(con, "SET threads=1"))
invisible(dbExecute(con, sprintf(
  "SET temp_directory='%s'", gsub("'", "''", normalizePath(
    temporary_root, winslash = "/", mustWork = TRUE
  ))
)))

verify_dataset <- function(dataset_id, parquet_name) {
  path <- path_for(parquet_name)
  dataset <- arrow::open_dataset(path)
  schema_ok <- identical(names(dataset$schema), EXPECTED_PARQUET_COLUMNS) &&
    identical(dataset$schema$GetFieldByName("timestamp")$type$timezone(), "UTC")
  add_check(
    paste0(dataset_id, "_parquet_schema"), schema_ok,
    paste("exact seven-column schema with timestamp timezone UTC:", parquet_name)
  )

  summary <- dbGetQuery(con, sprintf(
    "WITH data AS (SELECT * FROM read_parquet('%s'))
     SELECT
       count(*) AS n_records,
       count(DISTINCT source_address) AS n_pseudonyms,
       count(DISTINCT sensor_name) AS n_sensors,
       min(epoch_us(timestamp)) AS start_epoch_us,
       max(epoch_us(timestamp)) AS end_epoch_us,
       sum(detections) AS total_detections,
       count(*) FILTER (WHERE source_address IS NULL OR
         NOT regexp_full_match(CAST(source_address AS VARCHAR), '[0-9a-f]{32}')) AS invalid_ids,
       count(*) FILTER (WHERE timestamp IS NULL OR sensor_name IS NULL OR
         rssi_median IS NULL OR rssi_sum IS NULL OR detections IS NULL OR
         strength_sum IS NULL) AS null_rows,
       count(*) FILTER (WHERE detections < 1 OR detections > 20 OR
         strength_sum IS DISTINCT FROM 100 * detections + rssi_sum) AS invalid_values,
       count(*) FILTER (WHERE epoch_us(timestamp) %% 20000000 != 0) AS unaligned_timestamps
     FROM data",
    sql_path(path)
  ))
  duplicates <- dbGetQuery(con, sprintf(
    "SELECT count(*) AS n FROM (
       SELECT timestamp, source_address, sensor_name
       FROM read_parquet('%s') GROUP BY 1, 2, 3 HAVING count(*) > 1
     )", sql_path(path)
  ))$n[[1L]]
  sensors <- dbGetQuery(con, sprintf(
    "SELECT DISTINCT CAST(sensor_name AS VARCHAR) AS sensor_name
     FROM read_parquet('%s') ORDER BY 1", sql_path(path)
  ))$sensor_name
  manifest_row <- source_manifest[
    source_manifest$dataset_id == dataset_id, , drop = FALSE
  ]
  expected_source_name <- if (dataset_id == "unist19") {
    "wifi_unist19_20sec_public-candidate.parquet"
  } else {
    "wifi_uou20_20sec_public-candidate.parquet"
  }
  data_ok <- nrow(manifest_row) == 1L &&
    identical(manifest_row$file[[1L]], expected_source_name) &&
    identical(manifest_row$sha256[[1L]], digest(path, algo = "sha256", file = TRUE)) &&
    identical(as.numeric(manifest_row$size_bytes[[1L]]), file.info(path)$size) &&
    summary$n_records[[1L]] == manifest_row$n_records[[1L]] &&
    summary$n_pseudonyms[[1L]] == manifest_row$n_pseudonyms[[1L]] &&
    summary$n_sensors[[1L]] == manifest_row$n_sensors[[1L]] &&
    summary$total_detections[[1L]] == manifest_row$total_detections[[1L]] &&
    summary$start_epoch_us[[1L]] ==
      as.numeric(as.POSIXct(manifest_row$start_utc[[1L]], tz = "UTC")) * 1e6 &&
    summary$end_epoch_us[[1L]] ==
      as.numeric(as.POSIXct(manifest_row$end_utc[[1L]], tz = "UTC")) * 1e6 &&
    summary$invalid_ids[[1L]] == 0 && summary$null_rows[[1L]] == 0 &&
    summary$invalid_values[[1L]] == 0 && summary$unaligned_timestamps[[1L]] == 0 &&
    duplicates == 0
  add_check(
    paste0(dataset_id, "_data_contract"), data_ok,
    paste(
      summary$n_records[[1L]], "rows;", summary$n_pseudonyms[[1L]],
      "pseudonyms;", summary$n_sensors[[1L]], "sensors; source checksum retained"
    )
  )
  coordinate_names <- sort(sensor_coordinates[
    sensor_coordinates$dataset_id == dataset_id, "sensor_name"
  ])
  add_check(
    paste0(dataset_id, "_sensor_coverage"), identical(sort(sensors), coordinate_names),
    paste(length(sensors), "Parquet sensor codes have exactly one coordinate row")
  )
}

verify_dataset("unist19", "wifi_unist19_20sec.parquet")
verify_dataset("uou20", "wifi_uou20_20sec.parquet")

readme_text <- paste(readLines(path_for("README.md"), warn = FALSE), collapse = "\n")
dictionary_text <- paste(
  readLines(path_for("DATA_DICTIONARY.md"), warn = FALSE), collapse = "\n"
)
text_files <- actual_files[grepl("\\.(md|csv)$", actual_files, ignore.case = TRUE)]
documentation_text <- paste(vapply(text_files, function(name) {
  paste(readLines(path_for(name), warn = FALSE), collapse = "\n")
}, character(1)), collapse = "\n")
status_ok <- grepl("release candidate", readme_text, fixed = TRUE) &&
  grepl("not evidence that an upload or access decision has occurred", readme_text, fixed = TRUE) &&
  grepl("Supply the approved data license", readme_text, fixed = TRUE) &&
  !grepl("10\\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+", documentation_text, perl = TRUE) &&
  !grepl(
    "CC[- ]BY|Creative Commons Attribution|MIT License|GNU General Public License|Apache License",
    documentation_text, ignore.case = TRUE, perl = TRUE
  ) && !grepl("https?://", documentation_text, ignore.case = TRUE, perl = TRUE)
add_check(
  "candidate_status_without_invented_terms", status_ok,
  "README marks candidate status and leaves license, citation, DOI, and access terms for approval"
)

dbDisconnect(con, shutdown = TRUE)
con <- NULL
if (dir.exists(temporary_root)) {
  unlink(temporary_root, recursive = TRUE, force = TRUE)
}
if (dir.exists(temporary_root)) {
  stop("Failed to remove DuckDB verification temporary directory", call. = FALSE)
}
passed <- all(checks$passed)
dir.create(verification_root, recursive = TRUE, showWarnings = FALSE)
staging_dir <- paste0(output_dir, ".building-", Sys.getpid())
if (file.exists(staging_dir) || dir.exists(staging_dir)) {
  stop("Refusing an existing verification staging directory", call. = FALSE)
}
dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)
on.exit(if (dir.exists(staging_dir)) unlink(staging_dir, recursive = TRUE, force = TRUE), add = TRUE)
write.csv(checks, file.path(staging_dir, "verification_checks.csv"), row.names = FALSE, na = "")
report <- c(
  "# Public-data package verification",
  "",
  paste0("Package: `", basename(package_dir), "`"),
  "",
  paste0("Result: **", if (passed) "PASS" else "FAIL", "**"),
  "",
  paste0(sum(checks$passed), " of ", nrow(checks), " checks passed."),
  "",
  paste0(
    "The package was verified without a release key. All allowlisted files, ",
    "source-evidence hashes, public Parquet contracts, sensor-coordinate ",
    "coverage, and candidate-status statements were checked."
  ),
  "",
  "This verification does not grant a license, mint a DOI, authorize access, or upload data."
)
writeLines(report, file.path(staging_dir, "verification_report.md"), useBytes = TRUE)
if (!file.rename(staging_dir, output_dir)) {
  stop("Failed to install package-verification output", call. = FALSE)
}
if (!passed) stop("Public-data package verification failed", call. = FALSE)
cat("Public-data package verified: ", nrow(checks), " checks passed.\n", sep = "")
