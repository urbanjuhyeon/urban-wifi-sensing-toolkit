# Legacy deterministic identifier hashing for restricted historical processing.
#
# This helper reproduces the 16-hex SHA-256 convention used by the 2019--2020
# analysis provenance. It is not the maintained collector contract and it is
# not the final public-handoff contract. New collection uses deployment-scoped
# HMAC; public handoff uses release-specific keyed re-pseudonymization.

LEGACY_IDENTIFIER_HASH_ALGORITHM <- "sha256"
LEGACY_IDENTIFIER_HASH_HEX_LENGTH <- 16L

canonicalize_legacy_identifier <- function(x) {
  tolower(trimws(as.character(x)))
}

legacy_hash_identifier <- function(x) {
  canonical <- canonicalize_legacy_identifier(x)
  vapply(
    canonical,
    function(value) substr(
      digest::digest(
        value,
        algo = LEGACY_IDENTIFIER_HASH_ALGORITHM,
        serialize = FALSE
      ),
      1L,
      LEGACY_IDENTIFIER_HASH_HEX_LENGTH
    ),
    character(1)
  )
}

assert_no_legacy_identifier_hash_collisions <- function(
    raw, hashed = legacy_hash_identifier(raw)) {
  mapping <- unique(data.frame(
    raw = canonicalize_legacy_identifier(raw),
    hashed = as.character(hashed),
    stringsAsFactors = FALSE
  ))
  if (anyDuplicated(mapping$hashed)) {
    stop("Legacy identifier hash collision detected; no output was written")
  }
  invisible(TRUE)
}

is_legacy_identifier_hash <- function(x) {
  grepl(
    sprintf("^[0-9a-f]{%d}$", LEGACY_IDENTIFIER_HASH_HEX_LENGTH),
    canonicalize_legacy_identifier(x)
  )
}

stopifnot(
  legacy_hash_identifier("AA:BB:CC:DD:EE:FF") == "c1582e87c8022218"
)
