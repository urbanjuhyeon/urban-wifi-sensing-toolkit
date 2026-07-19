# Historical 20-second public-data package candidate

Package version: `historical-v4-public-package-candidate-1`

This author-side candidate contains the complete 20-second campus and commercial-district datasets plus the sensor coordinates required for spatial metrics. It contains no packet-level field data, restricted one-second input, release key, or internal-to-public identifier mapping.

Each 32-character `source_address` is a release- and dataset-specific pseudonym that remains consistent within its dataset. It is not a MAC address or a person identifier, and the records are pseudonymous rather than anonymous.

The 2019 and 2020 field collectors are not claimed to have used the maintained HMAC capture scheme. Public pseudonyms were assigned in a separate, verified downstream handoff.

## Contents

- `wifi_unist19_20sec.parquet`: 15021058 rows; 25603 pseudonyms; 24 sensors.
- `wifi_uou20_20sec.parquet`: 5436472 rows; 75224 pseudonyms; 17 sensors.
- `sensor_coordinates.csv`: WGS 84 coordinates for exactly the sensor codes used by both files.
- `DATA_DICTIONARY.md`: field definitions and interpretation limits.
- `public_handoff_manifest.csv`, `build_report.md`, `verification_checks.csv`, and `verification_report.md`: byte-for-byte source public-handoff evidence.
- `SOURCE_EVIDENCE.csv`: repository-relative source paths, sizes, SHA-256 values, and coordinate-provenance checks used for this build.
- `SLIM_TRANSFORM.md`: verified removal record for the derivable `strength_sum` column; restore it as `100 × detections + rssi_sum`.
- `MANIFEST.sha256`: SHA-256 checksum for every other package file.

## Status

This directory is a release candidate, not evidence that an upload has occurred. License decision (2026-07-19): the datasets in this directory are released under CC BY 4.0 (see `LICENSE` in this directory); repository code and documentation remain under the MIT License. The Zenodo record DOI and article citation are still pending; record them here at upload time.

The package builder and verifier consume the already verified public Parquet files without reading a release key. This package has not been uploaded.
