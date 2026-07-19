# Verify that a public-handoff candidate is exactly a bijective identifier
# relabeling of the approved historical v4 intermediate. This script writes
# aggregate checks only; it never exports an identifier mapping.

suppressPackageStartupMessages({
  library(arrow)
  library(DBI)
  library(digest)
  library(duckdb)
})

PUBLIC_CANDIDATE_VERSION <- "historical-v4-public-candidate-1"
HISTORICAL_CANDIDATE_VERSION <- "historical-v4-candidate-1"
EXPECTED_COLUMNS <- c(
  "timestamp", "source_address", "sensor_name", "rssi_median", "rssi_sum",
  "detections", "strength_sum"
)

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
  mustWork = TRUE
)
input_value <- argument_value("input", required = FALSE)
input_dir <- normalizePath(
  if (is.null(input_value)) {
    file.path(input_root, HISTORICAL_CANDIDATE_VERSION)
  } else {
    input_value
  },
  winslash = "/",
  mustWork = TRUE
)
output_value <- argument_value("candidate", required = FALSE)
output_dir <- normalizePath(
  if (is.null(output_value)) {
    file.path(output_root, PUBLIC_CANDIDATE_VERSION)
  } else {
    output_value
  },
  winslash = "/",
  mustWork = TRUE
)
if (!is_within_path(input_dir, input_root)) {
  stop("Input must remain under tmp/historical-v4-audit")
}
if (!is_within_path(output_dir, output_root)) {
  stop("Candidate must remain under tmp/public-release-handoff")
}

campus_key <- read_release_key(
  argument_value("campus-key-file"), repository_root = base_dir
)
district_key <- read_release_key(
  argument_value("district-key-file"), repository_root = base_dir
)
if (identical(campus_key, district_key)) {
  stop("Each dataset must use a different release key")
}

paths <- list(
  campus_input = file.path(input_dir, "wifi_unist19_20sec_v4-candidate.parquet"),
  district_input = file.path(input_dir, "wifi_uou20_20sec_v4-candidate.parquet"),
  campus_public = file.path(output_dir, "wifi_unist19_20sec_public-candidate.parquet"),
  district_public = file.path(output_dir, "wifi_uou20_20sec_public-candidate.parquet"),
  manifest = file.path(output_dir, "public_handoff_manifest.csv"),
  build_report = file.path(output_dir, "build_report.md"),
  checks = file.path(output_dir, "verification_checks.csv"),
  report = file.path(output_dir, "verification_report.md")
)
required <- paths[c(
  "campus_input", "district_input", "campus_public", "district_public",
  "manifest", "build_report"
)]
missing <- names(required)[!file.exists(unlist(required))]
if (length(missing)) stop("Missing verification input(s): ", paste(missing, collapse = ", "))

allowed_files <- sort(basename(unlist(paths[c(
  "campus_public", "district_public", "manifest", "build_report", "checks", "report"
)])))
actual_files <- sort(list.files(output_dir, recursive = TRUE, include.dirs = FALSE))
unexpected_files <- setdiff(actual_files, allowed_files)

sql_path <- function(path) {
  gsub("'", "''", normalizePath(path, winslash = "/", mustWork = TRUE))
}

temporary_root <- file.path(
  base_dir, "tmp/public-release-verification", paste0("verify-", Sys.getpid())
)
dir.create(temporary_root, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(temporary_root, recursive = TRUE, force = TRUE), add = TRUE)

con <- dbConnect(duckdb(), dbdir = ":memory:")
on.exit({
  if (!is.null(con)) dbDisconnect(con, shutdown = TRUE)
}, add = TRUE)
invisible(dbExecute(con, "SET threads=1"))
invisible(dbExecute(con, sprintf(
  "SET temp_directory='%s'", gsub("'", "''", normalizePath(
    temporary_root, winslash = "/", mustWork = TRUE
  ))
)))

checks <- data.frame(
  check_id = character(), passed = logical(), evidence = character(),
  stringsAsFactors = FALSE
)
add_check <- function(check_id, passed, evidence) {
  checks <<- rbind(
    checks,
    data.frame(
      check_id = check_id,
      passed = isTRUE(passed),
      evidence = as.character(evidence),
      stringsAsFactors = FALSE
    )
  )
}

add_check(
  "candidate_file_allowlist",
  !length(unexpected_files),
  if (length(unexpected_files)) {
    paste("unexpected files:", paste(unexpected_files, collapse = ", "))
  } else {
    "candidate contains only the two Parquet files, manifest, and build/verification reports"
  }
)

read_internal_ids <- function(path) {
  dbGetQuery(con, sprintf(
    "SELECT DISTINCT CAST(source_address AS VARCHAR) AS source_address
     FROM read_parquet('%s') ORDER BY 1",
    sql_path(path)
  ))$source_address
}
campus_mapping <- build_release_mapping(
  read_internal_ids(paths$campus_input), "unist19", campus_key
)
district_mapping <- build_release_mapping(
  read_internal_ids(paths$district_input), "uou20", district_key
)
dbWriteTable(con, "campus_release_mapping", campus_mapping, temporary = TRUE)
dbWriteTable(con, "district_release_mapping", district_mapping, temporary = TRUE)

verify_dataset <- function(
    label, dataset_id, input_path, public_path, mapping, mapping_table) {
  input_columns <- names(arrow::open_dataset(input_path)$schema)
  public_dataset <- arrow::open_dataset(public_path)
  public_columns <- names(public_dataset$schema)
  timestamp_field <- public_dataset$schema$GetFieldByName("timestamp")
  timestamp_timezone <- timestamp_field$type$timezone()
  add_check(
    paste0(dataset_id, "_schema_columns"),
    identical(input_columns, EXPECTED_COLUMNS) &&
      identical(public_columns, EXPECTED_COLUMNS),
    paste("input and public columns:", paste(public_columns, collapse = ", "))
  )
  add_check(
    paste0(dataset_id, "_utc_metadata"),
    identical(timestamp_timezone, "UTC"),
    paste("public timestamp timezone:", timestamp_timezone)
  )

  overview <- dbGetQuery(con, sprintf(
    "SELECT
       (SELECT count(*) FROM read_parquet('%s')) AS input_rows,
       (SELECT count(*) FROM read_parquet('%s')) AS public_rows,
       (SELECT count(DISTINCT source_address) FROM read_parquet('%s')) AS input_ids,
       (SELECT count(DISTINCT source_address) FROM read_parquet('%s')) AS public_ids,
       (SELECT count(*) FROM read_parquet('%s')
          WHERE source_address IS NULL
             OR NOT regexp_full_match(source_address, '[0-9a-f]{32}')) AS invalid_public_ids,
       (SELECT count(*) FROM read_parquet('%s')
          WHERE source_address IS NULL OR sensor_name IS NULL OR timestamp IS NULL
             OR rssi_median IS NULL OR rssi_sum IS NULL OR detections IS NULL
             OR strength_sum IS NULL) AS public_null_rows",
    sql_path(input_path), sql_path(public_path), sql_path(input_path),
    sql_path(public_path), sql_path(public_path), sql_path(public_path)
  ))
  add_check(
    paste0(dataset_id, "_row_count"),
    overview$input_rows[[1L]] == overview$public_rows[[1L]],
    paste(label, "rows:", overview$public_rows[[1L]])
  )
  add_check(
    paste0(dataset_id, "_identifier_bijection"),
    overview$input_ids[[1L]] == overview$public_ids[[1L]] &&
      overview$input_ids[[1L]] == nrow(mapping) &&
      !anyDuplicated(mapping$public_source_address),
    paste(label, "pseudonyms:", overview$public_ids[[1L]])
  )
  add_check(
    paste0(dataset_id, "_public_identifier_contract"),
    overview$invalid_public_ids[[1L]] == 0 &&
      overview$public_null_rows[[1L]] == 0,
    "all public IDs are 32 lowercase hex characters and all required fields are non-null"
  )

  duplicates <- dbGetQuery(con, sprintf(
    "SELECT
       (SELECT count(*) FROM (
          SELECT timestamp, source_address, sensor_name
          FROM read_parquet('%s') GROUP BY 1, 2, 3 HAVING count(*) > 1
        )) AS input_duplicate_keys,
       (SELECT count(*) FROM (
          SELECT timestamp, source_address, sensor_name
          FROM read_parquet('%s') GROUP BY 1, 2, 3 HAVING count(*) > 1
        )) AS public_duplicate_keys",
    sql_path(input_path), sql_path(public_path)
  ))
  add_check(
    paste0(dataset_id, "_unique_20second_keys"),
    duplicates$input_duplicate_keys[[1L]] == 0 &&
      duplicates$public_duplicate_keys[[1L]] == 0,
    "both input and public files have one row per timestamp-pseudonym-sensor key"
  )

  exact <- dbGetQuery(con, sprintf(
    "SELECT
       sum(CASE WHEN p.source_address IS NULL THEN 1 ELSE 0 END) AS missing_rows,
       sum(CASE WHEN p.source_address IS NOT NULL AND (
         i.rssi_median IS DISTINCT FROM p.rssi_median OR
         i.rssi_sum IS DISTINCT FROM p.rssi_sum OR
         i.detections IS DISTINCT FROM p.detections OR
         i.strength_sum IS DISTINCT FROM p.strength_sum
       ) THEN 1 ELSE 0 END) AS changed_value_rows
     FROM read_parquet('%s') AS i
     INNER JOIN %s AS m
       ON CAST(i.source_address AS VARCHAR) = m.internal_source_address
     LEFT JOIN read_parquet('%s') AS p
       ON i.timestamp = p.timestamp
      AND m.public_source_address = CAST(p.source_address AS VARCHAR)
      AND CAST(i.sensor_name AS VARCHAR) = CAST(p.sensor_name AS VARCHAR)",
    sql_path(input_path), mapping_table, sql_path(public_path)
  ))
  add_check(
    paste0(dataset_id, "_exact_nonidentifier_values"),
    exact$missing_rows[[1L]] == 0 && exact$changed_value_rows[[1L]] == 0,
    paste(
      "missing mapped rows:", exact$missing_rows[[1L]],
      "; rows with any changed metric value:", exact$changed_value_rows[[1L]]
    )
  )

  direct_overlap <- dbGetQuery(con, sprintf(
    "SELECT count(*) AS n
     FROM (SELECT DISTINCT source_address FROM read_parquet('%s')) AS i
     INNER JOIN (SELECT DISTINCT source_address FROM read_parquet('%s')) AS p
       USING (source_address)",
    sql_path(input_path), sql_path(public_path)
  ))$n[[1L]]
  add_check(
    paste0(dataset_id, "_internal_public_separation"),
    direct_overlap == 0,
    "no internal pseudonym is reused as a public pseudonym"
  )
}

verify_dataset(
  "UNIST campus", "unist19", paths$campus_input, paths$campus_public,
  campus_mapping, "campus_release_mapping"
)
verify_dataset(
  "Commercial district", "uou20", paths$district_input, paths$district_public,
  district_mapping, "district_release_mapping"
)

cross_dataset_overlap <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n
   FROM (SELECT DISTINCT source_address FROM read_parquet('%s')) AS c
   INNER JOIN (SELECT DISTINCT source_address FROM read_parquet('%s')) AS d
     USING (source_address)",
  sql_path(paths$campus_public), sql_path(paths$district_public)
))$n[[1L]]
add_check(
  "cross_dataset_identifier_separation",
  cross_dataset_overlap == 0,
  "the campus and district public identifier sets do not overlap"
)

manifest <- read.csv(paths$manifest, stringsAsFactors = FALSE)
forbidden_manifest_columns <- grep(
  "(^key$|key_path|fingerprint|mapping|internal_source)",
  names(manifest),
  ignore.case = TRUE,
  value = TRUE
)
manifest_contract <- nrow(manifest) == 2L &&
  all(manifest$public_candidate_version == PUBLIC_CANDIDATE_VERSION) &&
  all(manifest$historical_candidate_version == HISTORICAL_CANDIDATE_VERSION) &&
  setequal(manifest$dataset_id, c("unist19", "uou20")) &&
  all(manifest$timezone == "UTC") &&
  all(manifest$identifier_algorithm == RELEASE_HMAC_ALGORITHM) &&
  all(manifest$identifier_scheme_version == RELEASE_HMAC_SCHEME_VERSION) &&
  all(manifest$identifier_scope == "release-dataset") &&
  all(manifest$identifier_hex_length == RELEASE_IDENTIFIER_HEX_LENGTH) &&
  !length(forbidden_manifest_columns)
add_check(
  "manifest_contract",
  manifest_contract,
  "manifest records versioned release-specific HMAC metadata without key or mapping fields"
)

manifest_files <- c(
  unist19 = paths$campus_public,
  uou20 = paths$district_public
)
manifest_hash_ok <- TRUE
for (dataset_id in names(manifest_files)) {
  row <- manifest[manifest$dataset_id == dataset_id, , drop = FALSE]
  manifest_hash_ok <- manifest_hash_ok && nrow(row) == 1L &&
    identical(row$sha256[[1L]], digest(
      manifest_files[[dataset_id]], algo = "sha256", file = TRUE
    )) &&
    identical(as.numeric(row$size_bytes[[1L]]), file.info(
      manifest_files[[dataset_id]]
    )$size)
}
add_check(
  "manifest_file_integrity",
  manifest_hash_ok,
  "both public Parquet sizes and SHA-256 file checksums match the manifest"
)

write.csv(checks, paths$checks, row.names = FALSE, na = "")
passed <- all(checks$passed)
report <- c(
  "# Public-handoff verification",
  "",
  paste0("Candidate: `", PUBLIC_CANDIDATE_VERSION, "`"),
  "",
  paste0("Result: **", if (passed) "PASS" else "FAIL", "**"),
  "",
  paste0(sum(checks$passed), " of ", nrow(checks), " checks passed."),
  "",
  paste0(
    "The verifier recomputed the private mapping in memory and established a ",
    "one-to-one relabeling. Every timestamp, sensor, RSSI summary, detection ",
    "count, and strength value was preserved exactly. The mapping and keys ",
    "were not written."
  ),
  "",
  paste0(
    "This proves computational invariance under identifier relabeling; it does ",
    "not make the trajectories anonymous and does not itself authorize open ",
    "release."
  )
)
writeLines(report, paths$report, useBytes = TRUE)

dbDisconnect(con, shutdown = TRUE)
con <- NULL
if (!passed) stop("Public-handoff verification failed; inspect verification_checks.csv")
cat("Public-handoff candidate verified: ", nrow(checks), " checks passed.\n", sep = "")
