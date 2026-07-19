# =============================================================================
# Package public tutorial samples from already HMAC-protected release inputs
#
# Required arguments:
#   --main-hmac-parquet=<verified 32-hex campus Parquet>
#   --location-hmac-parquet=<verified 32-hex location Parquet>
#   --location-hmac-gps=<verified 32-hex location GPS CSV>
#
# This script is deliberately not an HMAC transformer. The canonical HMAC
# candidate build, verification, secret scan, and apply gate is implemented in
# scripts/release/rekey_tutorial_data.py. Restricted historical intermediates
# are never accepted here as implicit defaults.
# =============================================================================

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(zip)
})

script_path <- if (requireNamespace("rstudioapi", quietly = TRUE) &&
                   rstudioapi::isAvailable()) {
  rstudioapi::getSourceEditorContext()$path
} else {
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
}
base_dir <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/")

main_dir <- file.path(base_dir, "workflow/unist19_main/data")
loc_dir <- file.path(base_dir, "workflow/unist19_loc/data")

args <- commandArgs(trailingOnly = TRUE)

required_path_option <- function(name) {
  prefix <- paste0(name, "=")
  matches <- args[startsWith(args, prefix)]
  if (length(matches) != 1L) {
    stop("Supply exactly one ", name, "=<path> argument")
  }
  value <- substring(matches, nchar(prefix) + 1L)
  if (!nzchar(value)) stop(name, " must not be empty")
  normalizePath(value, winslash = "/", mustWork = TRUE)
}

main_public <- required_path_option("--main-hmac-parquet")
location_wifi <- required_path_option("--location-hmac-parquet")
location_gps <- required_path_option("--location-hmac-gps")

assert_public_hmac_values <- function(values, label) {
  values <- unique(as.character(values))
  invalid <- is.na(values) | !grepl("^[0-9a-f]{32}$", values)
  if (length(values) == 0L || any(invalid)) {
    stop(label, " must contain only non-missing 32-character lowercase ",
         "HMAC-SHA-256 pseudonyms")
  }
  values
}

public_hmac_ids_parquet <- function(path, label) {
  dataset <- open_dataset(path, format = "parquet")
  if (!("source_address" %in% dataset$schema$names)) {
    stop(label, " has no source_address column")
  }
  values <- dataset |>
    select(source_address) |>
    distinct() |>
    collect() |>
    pull(source_address)
  assert_public_hmac_values(values, label)
}

public_hmac_ids_csv <- function(path, label) {
  table <- read.csv(path, colClasses = "character", check.names = FALSE)
  if (!("source_address" %in% names(table))) {
    stop(label, " has no source_address column")
  }
  assert_public_hmac_values(table$source_address, label)
}

invisible(public_hmac_ids_parquet(main_public, "Campus public input"))
location_wifi_ids <- public_hmac_ids_parquet(
  location_wifi, "Location WiFi public input"
)
location_gps_ids <- public_hmac_ids_csv(location_gps, "Location GPS public input")
if (!setequal(location_wifi_ids, location_gps_ids)) {
  stop("Location WiFi and GPS public inputs do not use the same HMAC identifiers")
}

work_dir <- tempfile("public-tutorial-package-")
dir.create(work_dir, recursive = TRUE)
on.exit(unlink(work_dir, recursive = TRUE), add = TRUE)
main_sample <- file.path(work_dir, "wifi.parquet")

sample_start <- as.POSIXct("2019-10-28 00:00:00", tz = "UTC")
sample_end <- as.POSIXct("2019-11-04 00:00:00", tz = "UTC")
sample_table <- open_dataset(main_public) |>
  filter(timestamp >= sample_start, timestamp < sample_end) |>
  collect()
write_parquet(sample_table, main_sample, compression = "zstd")
invisible(public_hmac_ids_parquet(main_sample, "Campus one-week public sample"))

sample_time <- read_parquet(main_sample, col_select = "timestamp")[["timestamp"]]
if (!identical(attr(sample_time, "tzone"), "UTC")) {
  stop("Campus sample lost UTC timestamp metadata")
}

make_zip <- function(zip_path, files, archive_names) {
  if (!all(file.exists(files))) {
    stop("Missing sample input(s): ", paste(files[!file.exists(files)], collapse = ", "))
  }
  stage <- tempfile("wifi-sample-")
  dir.create(stage, recursive = TRUE)
  on.exit(unlink(stage, recursive = TRUE), add = TRUE)
  staged <- file.path(stage, archive_names)
  if (!all(file.copy(files, staged, overwrite = TRUE))) {
    stop("Failed to stage sample archive")
  }
  # ZIP metadata otherwise inherits changing source-file modification times,
  # making byte-identical releases impossible even when contents are unchanged.
  Sys.setFileTime(staged, as.POSIXct("2000-01-01 00:00:00", tz = "UTC"))
  if (file.exists(zip_path)) unlink(zip_path)
  zipr(zip_path, staged, root = stage, include_directories = FALSE)
  invisible(zip_path)
}

make_zip(
  file.path(work_dir, "sample_main.zip"),
  c(main_sample, file.path(main_dir, "sensors.gpkg"), file.path(main_dir, "poi.gpkg")),
  c("wifi.parquet", "sensors.gpkg", "poi.gpkg")
)

make_zip(
  file.path(work_dir, "sample_loc.zip"),
  c(location_wifi, location_gps, file.path(loc_dir, "sensors.gpkg")),
  c("wifi.parquet", "gps.csv", "sensors.gpkg")
)

install_candidates <- function(candidates, targets) {
  new_paths <- paste0(targets, ".new")
  backup_paths <- paste0(targets, ".bak")
  if (any(file.exists(c(new_paths, backup_paths)))) {
    stop("Refusing stale .new or .bak sample archive beside a public target")
  }
  if (!all(file.copy(candidates, new_paths, overwrite = FALSE))) {
    unlink(new_paths)
    stop("Failed to stage public sample archives beside their targets")
  }

  had_original <- file.exists(targets)
  installed <- rep(FALSE, length(targets))
  committed <- FALSE
  on.exit({
    if (!committed) {
      unlink(targets[installed & file.exists(targets)])
      for (index in which(had_original & file.exists(backup_paths))) {
        file.rename(backup_paths[index], targets[index])
      }
      unlink(new_paths[file.exists(new_paths)])
    }
  }, add = TRUE)

  for (index in which(had_original)) {
    if (!file.rename(targets[index], backup_paths[index])) {
      stop("Failed to back up public archive before replacement: ", targets[index])
    }
  }
  for (index in seq_along(targets)) {
    if (!file.rename(new_paths[index], targets[index])) {
      stop("Failed to install public archive: ", targets[index])
    }
    installed[index] <- TRUE
  }
  committed <- TRUE
  unlink(backup_paths[file.exists(backup_paths)])
}

targets <- c(
  file.path(main_dir, "sample_main.zip"),
  file.path(loc_dir, "sample_loc.zip")
)
install_candidates(
  c(file.path(work_dir, "sample_main.zip"), file.path(work_dir, "sample_loc.zip")),
  targets
)

cat("Packaged:\n",
    targets[1], "\n",
    targets[2], "\n")
