# Shared contract for release-specific keyed re-pseudonymization.
#
# This is a public-handoff layer. It does not describe how the 2019 or 2020
# observations were pseudonymized at capture, and it must not be imported by
# the maintained Raspberry Pi collector.

RELEASE_HMAC_ALGORITHM <- "hmac-sha256"
RELEASE_HMAC_SCHEME_VERSION <- "1"
RELEASE_HMAC_DOMAIN <- charToRaw("urban-wifi-release/device-identifier/v1")
RELEASE_IDENTIFIER_HEX_LENGTH <- 32L
RELEASE_KEY_BYTES <- 32L

is_within_path <- function(path, parent) {
  path <- tolower(chartr(
    "\\", "/", normalizePath(path, winslash = "/", mustWork = FALSE)
  ))
  parent <- tolower(chartr(
    "\\", "/", normalizePath(parent, winslash = "/", mustWork = FALSE)
  ))
  identical(path, parent) || startsWith(path, paste0(parent, "/"))
}

validate_release_dataset_id <- function(dataset_id) {
  if (
    length(dataset_id) != 1L || is.na(dataset_id) ||
      !grepl("^[a-z0-9][a-z0-9._-]{2,63}$", dataset_id)
  ) {
    stop("Release dataset ID must be 3--64 lowercase ASCII characters")
  }
  dataset_id
}

read_release_key <- function(path, repository_root) {
  if (length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("A release key file path is required")
  }
  if (!file.exists(path)) stop("Release key file does not exist")
  link_target <- Sys.readlink(path)
  if (!is.na(link_target) && nzchar(link_target)) {
    stop("Refusing a symlinked release key file")
  }
  info <- file.info(path)
  if (is.na(info$isdir) || info$isdir) {
    stop("Release key path must be a regular file")
  }
  key_path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  if (is_within_path(key_path, repository_root)) {
    stop("Release key files must be stored outside the repository")
  }
  if (is.na(info$size) || info$size != RELEASE_KEY_BYTES) {
    stop("Release key file must contain exactly 32 raw bytes")
  }
  connection <- file(key_path, open = "rb")
  on.exit(close(connection), add = TRUE)
  key <- readBin(connection, what = "raw", n = RELEASE_KEY_BYTES + 1L)
  if (length(key) != RELEASE_KEY_BYTES) {
    stop("Release key file must contain exactly 32 raw bytes")
  }
  key
}

release_hmac_message <- function(dataset_id, internal_identifier) {
  dataset_id <- validate_release_dataset_id(dataset_id)
  if (
    length(internal_identifier) != 1L || is.na(internal_identifier) ||
      !grepl("^[0-9a-f]{16,64}$", internal_identifier)
  ) {
    stop("Internal identifier is outside the accepted lowercase-hex contract")
  }
  c(
    RELEASE_HMAC_DOMAIN,
    as.raw(0),
    charToRaw(dataset_id),
    as.raw(0),
    charToRaw(internal_identifier)
  )
}

release_pseudonym <- function(internal_identifier, dataset_id, key) {
  if (!is.raw(key) || length(key) != RELEASE_KEY_BYTES) {
    stop("Release key must be exactly 32 raw bytes")
  }
  digest <- digest::hmac(
    key = key,
    object = release_hmac_message(dataset_id, internal_identifier),
    algo = "sha256",
    serialize = FALSE,
    raw = FALSE
  )
  substr(digest, 1L, RELEASE_IDENTIFIER_HEX_LENGTH)
}

build_release_mapping <- function(internal_identifiers, dataset_id, key) {
  internal_identifiers <- sort(unique(as.character(internal_identifiers)))
  if (
    !length(internal_identifiers) ||
      anyNA(internal_identifiers) ||
      any(!grepl("^[0-9a-f]{16,64}$", internal_identifiers))
  ) {
    stop("Input contains an invalid internal identifier")
  }
  public_identifiers <- vapply(
    internal_identifiers,
    release_pseudonym,
    dataset_id = dataset_id,
    key = key,
    FUN.VALUE = character(1),
    USE.NAMES = FALSE
  )
  if (anyDuplicated(public_identifiers)) {
    stop("Release-identifier collision detected; no output is safe to write")
  }
  data.frame(
    internal_source_address = internal_identifiers,
    public_source_address = public_identifiers,
    stringsAsFactors = FALSE
  )
}

assert_release_hmac_contract <- function() {
  # Cross-language vector also checked in the Python release tests.
  key <- charToRaw("01234567890123456789012345678901")
  expected <- "cb101f2c0e29decfdc0d873233589247"
  actual <- release_pseudonym("abcdef0123456789", "unist19", key)
  if (!identical(actual, expected)) {
    stop("Release HMAC implementation failed its fixed cross-language vector")
  }
  invisible(TRUE)
}

assert_release_hmac_contract()
