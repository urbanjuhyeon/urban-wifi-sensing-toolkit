# Prepare a self-contained, allowlisted public-data package directory from an
# already verified public-handoff candidate. This script does not create or
# read release keys and does not upload data.

suppressPackageStartupMessages({
  library(DBI)
  library(digest)
  library(duckdb)
  library(sf)
})

PACKAGE_VERSION <- "historical-v4-public-package-candidate-1"
PUBLIC_CANDIDATE_VERSION <- "historical-v4-public-candidate-1"
EXPECTED_CANDIDATE_FILES <- sort(c(
  "build_report.md", "public_handoff_manifest.csv", "verification_checks.csv",
  "verification_report.md", "wifi_unist19_20sec_public-candidate.parquet",
  "wifi_uou20_20sec_public-candidate.parquet"
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
EXPECTED_SOURCE_MANIFEST_COLUMNS <- c(
  "public_candidate_version", "historical_candidate_version", "dataset_id",
  "site", "file", "size_bytes", "sha256", "input_file", "input_sha256",
  "timezone", "local_timezone", "identifier_algorithm",
  "identifier_scheme_version", "identifier_scope", "identifier_hex_length",
  "n_records", "n_pseudonyms", "n_sensors", "start_utc", "end_utc",
  "total_detections"
)

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (!length(script_argument)) stop("Run this file with Rscript")
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]), winslash = "/")
base_dir <- normalizePath(file.path(dirname(script_path), "../.."), winslash = "/")

argument_value <- function(name, required = FALSE) {
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

is_within <- function(path, parent) {
  path <- tolower(chartr("\\", "/", normalizePath(path, winslash = "/", mustWork = FALSE)))
  parent <- tolower(chartr("\\", "/", normalizePath(parent, winslash = "/", mustWork = FALSE)))
  identical(path, parent) || startsWith(path, paste0(parent, "/"))
}

candidate_root <- file.path(base_dir, "tmp/public-release-handoff")
package_root <- file.path(base_dir, "tmp/public-data-package")
candidate_value <- argument_value("candidate")
candidate_dir <- normalizePath(
  if (is.null(candidate_value)) {
    file.path(candidate_root, PUBLIC_CANDIDATE_VERSION)
  } else {
    candidate_value
  },
  winslash = "/",
  mustWork = TRUE
)
output_value <- argument_value("output")
output_dir <- normalizePath(
  if (is.null(output_value)) {
    file.path(package_root, PACKAGE_VERSION)
  } else {
    output_value
  },
  winslash = "/",
  mustWork = FALSE
)
if (!is_within(candidate_dir, candidate_root)) {
  stop("Candidate must remain under tmp/public-release-handoff")
}
if (!is_within(output_dir, package_root)) {
  stop("Package output must remain under tmp/public-data-package")
}
if (file.exists(output_dir) || dir.exists(output_dir)) {
  stop("Refusing to overwrite an existing public-data package candidate")
}
dir.create(package_root, recursive = TRUE, showWarnings = FALSE)

candidate_paths <- list(
  campus = file.path(candidate_dir, "wifi_unist19_20sec_public-candidate.parquet"),
  district = file.path(candidate_dir, "wifi_uou20_20sec_public-candidate.parquet"),
  manifest = file.path(candidate_dir, "public_handoff_manifest.csv"),
  build_report = file.path(candidate_dir, "build_report.md"),
  checks = file.path(candidate_dir, "verification_checks.csv"),
  report = file.path(candidate_dir, "verification_report.md")
)
missing <- names(candidate_paths)[!file.exists(unlist(candidate_paths))]
if (length(missing)) stop("Missing verified candidate file(s): ", paste(missing, collapse = ", "))

candidate_entries <- list.files(
  candidate_dir, all.files = TRUE, no.. = TRUE, recursive = TRUE,
  include.dirs = TRUE
)
candidate_files <- sort(list.files(
  candidate_dir, all.files = TRUE, no.. = TRUE, recursive = TRUE,
  include.dirs = FALSE
))
if (!identical(candidate_entries, candidate_files) ||
    !identical(candidate_files, EXPECTED_CANDIDATE_FILES)) {
  stop("Verified public-handoff candidate file allowlist mismatch")
}
candidate_links <- Sys.readlink(unlist(candidate_paths))
if (any(!is.na(candidate_links) & nzchar(candidate_links))) {
  stop("Verified public-handoff candidate contains a symbolic-link file")
}

checks <- read.csv(candidate_paths$checks, stringsAsFactors = FALSE)
if (
  !identical(names(checks), c("check_id", "passed", "evidence")) ||
    !identical(sort(checks$check_id), EXPECTED_SOURCE_CHECK_IDS) ||
    anyNA(checks) || !all(as.logical(checks$passed))
) {
  stop("Public-handoff verification checks are absent or not all true")
}
manifest <- read.csv(candidate_paths$manifest, stringsAsFactors = FALSE)
if (
  !identical(names(manifest), EXPECTED_SOURCE_MANIFEST_COLUMNS) ||
    nrow(manifest) != 2L || anyNA(manifest) ||
    any(manifest$public_candidate_version != PUBLIC_CANDIDATE_VERSION) ||
    !setequal(manifest$dataset_id, c("unist19", "uou20")) ||
    any(manifest$timezone != "UTC") ||
    any(manifest$local_timezone != "Asia/Seoul") ||
    any(manifest$identifier_algorithm != "hmac-sha256") ||
    any(manifest$identifier_scheme_version != 1L) ||
    any(manifest$identifier_scope != "release-dataset") ||
    any(manifest$identifier_hex_length != 32L)
) {
  stop("Public-handoff manifest is outside the expected version contract")
}
for (dataset_id in c("unist19", "uou20")) {
  path <- if (dataset_id == "unist19") candidate_paths$campus else candidate_paths$district
  row <- manifest[manifest$dataset_id == dataset_id, , drop = FALSE]
  if (
    nrow(row) != 1L ||
      !identical(row$file[[1L]], basename(path)) ||
      !identical(row$sha256[[1L]], digest(path, algo = "sha256", file = TRUE)) ||
      !identical(as.numeric(row$size_bytes[[1L]]), file.info(path)$size)
  ) {
    stop("Candidate Parquet checksum no longer matches its verified manifest")
  }
}

staging_dir <- paste0(output_dir, ".building-", Sys.getpid())
if (file.exists(staging_dir) || dir.exists(staging_dir)) {
  stop("Refusing an existing public-data package staging path")
}
dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(staging_dir)) stop("Failed to create package staging directory")
completed <- FALSE
on.exit({
  if (!completed && dir.exists(staging_dir)) {
    unlink(staging_dir, recursive = TRUE, force = TRUE)
  }
}, add = TRUE)

output_paths <- list(
  campus = file.path(staging_dir, "wifi_unist19_20sec.parquet"),
  district = file.path(staging_dir, "wifi_uou20_20sec.parquet"),
  sensors = file.path(staging_dir, "sensor_coordinates.csv"),
  source_manifest = file.path(staging_dir, "public_handoff_manifest.csv"),
  source_build_report = file.path(staging_dir, "build_report.md"),
  source_checks = file.path(staging_dir, "verification_checks.csv"),
  source_report = file.path(staging_dir, "verification_report.md"),
  source_evidence = file.path(staging_dir, "SOURCE_EVIDENCE.csv"),
  readme = file.path(staging_dir, "README.md"),
  dictionary = file.path(staging_dir, "DATA_DICTIONARY.md"),
  package_manifest = file.path(staging_dir, "MANIFEST.sha256")
)

write_lf_lines <- function(lines, path) {
  connection <- file(path, open = "wb")
  on.exit(close(connection), add = TRUE)
  writeLines(enc2utf8(lines), connection, sep = "\n", useBytes = TRUE)
}

for (name in c("campus", "district")) {
  if (!file.copy(candidate_paths[[name]], output_paths[[name]], overwrite = FALSE)) {
    stop("Failed to copy verified candidate Parquet")
  }
}
copy_pairs <- list(
  manifest = c(candidate_paths$manifest, output_paths$source_manifest),
  build_report = c(candidate_paths$build_report, output_paths$source_build_report),
  checks = c(candidate_paths$checks, output_paths$source_checks),
  report = c(candidate_paths$report, output_paths$source_report)
)
for (name in names(copy_pairs)) {
  pair <- copy_pairs[[name]]
  if (!file.copy(pair[[1L]], pair[[2L]], overwrite = FALSE)) {
    stop("Failed to copy verified source evidence: ", name)
  }
}

sql_path <- function(path) {
  gsub("'", "''", normalizePath(path, winslash = "/", mustWork = TRUE))
}
con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit({
  if (!is.null(con)) dbDisconnect(con, shutdown = TRUE)
}, add = TRUE)

candidate_sensor_names <- function(path) {
  dbGetQuery(con, sprintf(
    "SELECT DISTINCT CAST(sensor_name AS VARCHAR) AS sensor_name
     FROM read_parquet('%s') ORDER BY 1",
    sql_path(path)
  ))$sensor_name
}

campus_sensor_source <- file.path(
  base_dir, "workflow/unist19_main/data/sensors.gpkg"
)
district_sensor_source <- file.path(
  base_dir, "workflow/uou20/output/sensors_coords.csv"
)
district_crs_basis_source <- file.path(base_dir, "scripts/9-2-figure3.R")
source_coordinate_files <- c(
  campus_sensor_source, district_sensor_source, district_crs_basis_source
)
if (any(!file.exists(source_coordinate_files))) {
  stop("A required sensor-coordinate source or CRS-basis script is missing")
}
source_links <- Sys.readlink(source_coordinate_files)
if (any(!is.na(source_links) & nzchar(source_links))) {
  stop("Refusing a symbolic-link sensor-coordinate source")
}

campus_layers <- st_layers(campus_sensor_source)
if (nrow(campus_layers) != 1L || campus_layers$name[[1L]] != "sensors" ||
    campus_layers$geomtype[[1L]] != "Point" ||
    campus_layers$features[[1L]] != 24L) {
  stop("Campus sensor GPKG layer contract changed")
}
campus_sf <- st_read(campus_sensor_source, layer = "sensors", quiet = TRUE)
if (!identical(names(campus_sf), c("sensor_name", attr(campus_sf, "sf_column")))) {
  stop("Campus sensor GPKG contains unexpected fields")
}
if (is.na(st_crs(campus_sf)) || any(st_is_empty(campus_sf)) ||
    any(st_geometry_type(campus_sf) != "POINT")) {
  stop("Campus sensor geometries must be nonempty georeferenced points")
}
campus_sf <- st_transform(campus_sf, 4326)
campus_xy <- st_coordinates(campus_sf)
campus_sensors <- data.frame(
  dataset_id = "unist19",
  site = "UNIST campus",
  sensor_name = as.character(campus_sf$sensor_name),
  longitude = as.numeric(campus_xy[, "X"]),
  latitude = as.numeric(campus_xy[, "Y"]),
  crs_epsg = 4326L,
  stringsAsFactors = FALSE
)

district_source <- read.csv(district_sensor_source, stringsAsFactors = FALSE)
required_district <- c("id_sensor", "x", "y")
if (!all(required_district %in% names(district_source))) {
  stop("Commercial-district sensor metadata lacks id_sensor/x/y")
}
district_crs_basis <- paste(
  readLines(district_crs_basis_source, warn = FALSE, encoding = "UTF-8"),
  collapse = "\n"
)
if (!grepl(
      'st_as_sf(sensors, coords = c("x", "y"), crs = 4326)',
      district_crs_basis, fixed = TRUE
    )) {
  stop("Commercial-district EPSG:4326 basis is absent from its analysis script")
}
district_sensors <- data.frame(
  dataset_id = "uou20",
  site = "Commercial district",
  sensor_name = as.character(district_source$id_sensor),
  longitude = as.numeric(district_source$x),
  latitude = as.numeric(district_source$y),
  crs_epsg = 4326L,
  stringsAsFactors = FALSE
)

sensor_tables <- list(
  unist19 = campus_sensors,
  uou20 = district_sensors
)
public_files <- list(
  unist19 = output_paths$campus,
  uou20 = output_paths$district
)
for (dataset_id in names(sensor_tables)) {
  table <- sensor_tables[[dataset_id]]
  required_names <- candidate_sensor_names(public_files[[dataset_id]])
  if (
    anyNA(table) || any(!is.finite(table$longitude)) || any(!is.finite(table$latitude)) ||
      anyDuplicated(table$sensor_name) ||
      any(!grepl("^[A-Za-z0-9_-]{1,32}$", table$sensor_name)) ||
      any(table$longitude < -180 | table$longitude > 180) ||
      any(table$latitude < -90 | table$latitude > 90) ||
      !setequal(table$sensor_name, required_names)
  ) {
    stop("Sensor-coordinate coverage does not exactly match the public 20-second data")
  }
  sensor_tables[[dataset_id]] <- table[order(table$sensor_name), , drop = FALSE]
}
sensors <- do.call(rbind, sensor_tables)
row.names(sensors) <- NULL
sensor_counts <- table(sensors$dataset_id)
if (nrow(sensors) != 41L ||
    !identical(names(sensor_counts), c("unist19", "uou20")) ||
    !identical(as.integer(sensor_counts), c(24L, 17L))) {
  stop("Combined sensor-coordinate row counts changed")
}
write.csv(
  sensors, output_paths$sensors, row.names = FALSE, na = "", eol = "\n"
)

repository_relative_path <- function(path) {
  normalized <- normalizePath(path, winslash = "/", mustWork = TRUE)
  if (!is_within(normalized, base_dir) || identical(normalized, base_dir)) {
    stop("Source evidence path must remain inside the repository")
  }
  substring(normalized, nchar(base_dir) + 2L)
}
evidence_paths <- c(
  candidate_campus_parquet = candidate_paths$campus,
  candidate_district_parquet = candidate_paths$district,
  candidate_manifest = candidate_paths$manifest,
  candidate_build_report = candidate_paths$build_report,
  candidate_verification_checks = candidate_paths$checks,
  candidate_verification_report = candidate_paths$report,
  campus_sensor_coordinates = campus_sensor_source,
  district_sensor_coordinates = district_sensor_source,
  district_coordinate_crs_basis = district_crs_basis_source
)
evidence_roles <- c(
  "verified public campus Parquet copied byte-for-byte",
  "verified public commercial-district Parquet copied byte-for-byte",
  "public-handoff source manifest copied byte-for-byte",
  "public-handoff source build report copied byte-for-byte",
  "public-handoff verification checks copied byte-for-byte",
  "public-handoff verification report copied byte-for-byte",
  "campus sensor points transformed from their declared CRS to EPSG:4326",
  "commercial-district sensor longitude/latitude source",
  "analysis code declaring district x/y coordinates as EPSG:4326"
)
evidence_verification <- c(
  "SHA-256 and size match the public-handoff manifest",
  "SHA-256 and size match the public-handoff manifest",
  "exact two-dataset manifest contract and both Parquet checksums verified",
  "candidate status and no-key/no-mapping boundary retained",
  "exact 20-check allowlist present and all checks are true",
  "source verification result is PASS",
  "one Point layer, 24 nonempty sensors, exact public-data sensor coverage",
  "17 finite unique sensors, exact public-data sensor coverage",
  "contains explicit st_as_sf(..., crs = 4326) assignment"
)
source_evidence <- data.frame(
  evidence_id = names(evidence_paths),
  source_role = evidence_roles,
  repository_relative_path = vapply(
    evidence_paths, repository_relative_path, character(1)
  ),
  size_bytes = as.numeric(file.info(evidence_paths)$size),
  sha256 = vapply(
    evidence_paths, digest, character(1), algo = "sha256", file = TRUE,
    USE.NAMES = FALSE
  ),
  verification = evidence_verification,
  stringsAsFactors = FALSE,
  check.names = FALSE
)
if (anyNA(source_evidence) || anyDuplicated(source_evidence$evidence_id)) {
  stop("Source-evidence construction failed")
}
write.csv(
  source_evidence, output_paths$source_evidence,
  row.names = FALSE, na = "", eol = "\n"
)

campus_row <- manifest[manifest$dataset_id == "unist19", , drop = FALSE]
district_row <- manifest[manifest$dataset_id == "uou20", , drop = FALSE]
readme <- c(
  "# Historical 20-second public-data package candidate",
  "",
  paste0("Package version: `", PACKAGE_VERSION, "`"),
  "",
  paste0(
    "This author-side candidate contains the complete 20-second campus and ",
    "commercial-district datasets plus the sensor coordinates required for ",
    "spatial metrics. It contains no packet-level field data, restricted ",
    "one-second input, release key, or internal-to-public identifier mapping."
  ),
  "",
  paste0(
    "Each 32-character `source_address` is a release- and dataset-specific ",
    "pseudonym that remains consistent within its dataset. It is not a MAC ",
    "address or a person identifier, and the records are pseudonymous rather ",
    "than anonymous."
  ),
  "",
  paste0(
    "The 2019 and 2020 field collectors are not claimed to have used the ",
    "maintained HMAC capture scheme. Public pseudonyms were assigned in a ",
    "separate, verified downstream handoff."
  ),
  "",
  "## Contents",
  "",
  paste0("- `wifi_unist19_20sec.parquet`: ", campus_row$n_records, " rows; ", campus_row$n_pseudonyms, " pseudonyms; ", campus_row$n_sensors, " sensors."),
  paste0("- `wifi_uou20_20sec.parquet`: ", district_row$n_records, " rows; ", district_row$n_pseudonyms, " pseudonyms; ", district_row$n_sensors, " sensors."),
  "- `sensor_coordinates.csv`: WGS 84 coordinates for exactly the sensor codes used by both files.",
  "- `DATA_DICTIONARY.md`: field definitions and interpretation limits.",
  "- `public_handoff_manifest.csv`, `build_report.md`, `verification_checks.csv`, and `verification_report.md`: byte-for-byte source public-handoff evidence.",
  "- `SOURCE_EVIDENCE.csv`: repository-relative source paths, sizes, SHA-256 values, and coordinate-provenance checks used for this build.",
  "- `MANIFEST.sha256`: SHA-256 checksum for every other package file.",
  "",
  "## Status",
  "",
  paste0(
    "This directory is a release candidate, not evidence that an upload or ",
    "access decision has occurred. Supply the approved data license, citation, ",
    "repository DOI, and access statement before distribution."
  ),
  "",
  paste0(
    "The package builder and verifier consume the already verified public ",
    "Parquet files without reading a release key. This package has not been ",
    "uploaded."
  )
)
write_lf_lines(readme, output_paths$readme)

dictionary <- c(
  "# Data dictionary",
  "",
  "Both Parquet files contain one row per public pseudonym × sensor × 20-second UTC window.",
  "",
  "| Field | Type | Definition |",
  "|---|---|---|",
  "| `timestamp` | timestamp[us, UTC] | Start of the 20-second window, stored as a true UTC instant. Use `Asia/Seoul` explicitly for Korean local calendar analyses. |",
  "| `source_address` | string | 32-character lowercase release- and dataset-specific keyed pseudonym. Equal values identify the same retained internal pseudonym only within this dataset. |",
  "| `sensor_name` | string | Sensor code linked to `sensor_coordinates.csv`. |",
  "| `rssi_median` | double | Median RSSI, in dBm, among accepted one-second values in the window. |",
  "| `rssi_sum` | double | Sum of accepted one-second RSSI values. RSSI values are negative; do not interpret a more negative sum as a stronger signal. |",
  "| `detections` | int64 | Number of contributing unique one-second slots; constrained to 1–20. |",
  "| `strength_sum` | double | Sum of `100 + RSSI` over contributing seconds; exactly `100 × detections + rssi_sum`. Larger values support stronger-sensor ranking within a pseudonym-window. |",
  "",
  "`sensor_coordinates.csv` contains `dataset_id`, `site`, `sensor_name`, `longitude`, `latitude`, and `crs_epsg`; all coordinates use EPSG:4326. The 24 campus points retain the source GeoPackage CRS transformation, and the 17 commercial-district points use the workflow's explicit EPSG:4326 assignment.",
  "",
  "## Interpretation limits",
  "",
  paste0(
    "An observed address is not equivalent to a physical device or a person. ",
    "Device-managed address changes can split observations, and one person can ",
    "carry multiple devices. Location, Track, Revisits, and Activities are ",
    "inferences from retained pseudonymous observations and should be reported ",
    "as such."
  )
)
write_lf_lines(dictionary, output_paths$dictionary)

dbDisconnect(con, shutdown = TRUE)
con <- NULL

manifest_inputs <- unlist(output_paths[setdiff(names(output_paths), "package_manifest")])
manifest_inputs <- manifest_inputs[order(basename(manifest_inputs), method = "radix")]
manifest_lines <- vapply(
  manifest_inputs,
  function(path) paste0(digest(path, algo = "sha256", file = TRUE), "  ", basename(path)),
  character(1),
  USE.NAMES = FALSE
)
write_lf_lines(manifest_lines, output_paths$package_manifest)

expected_package_files <- sort(basename(unlist(output_paths)))
actual_package_files <- sort(list.files(
  staging_dir, all.files = TRUE, no.. = TRUE, recursive = TRUE,
  include.dirs = FALSE
))
actual_package_entries <- list.files(
  staging_dir, all.files = TRUE, no.. = TRUE, recursive = TRUE,
  include.dirs = TRUE
)
if (!identical(actual_package_files, expected_package_files) ||
    !identical(actual_package_entries, actual_package_files)) {
  stop("Completed package differs from its fixed top-level file allowlist")
}
output_links <- Sys.readlink(file.path(staging_dir, actual_package_files))
if (any(!is.na(output_links) & nzchar(output_links))) {
  stop("Completed package contains a symbolic-link file")
}

if (!file.rename(staging_dir, output_dir)) {
  stop("Failed to install the completed public-data package candidate")
}
completed <- TRUE
cat("Prepared public-data package candidate: ", basename(output_dir), "\n", sep = "")
