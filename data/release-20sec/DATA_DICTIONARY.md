# Data dictionary

Both Parquet files contain one row per public pseudonym × sensor × 20-second UTC window.

| Field | Type | Definition |
|---|---|---|
| `timestamp` | timestamp[us, UTC] | Start of the 20-second window, stored as a true UTC instant. Use `Asia/Seoul` explicitly for Korean local calendar analyses. |
| `source_address` | string | 32-character lowercase release- and dataset-specific keyed pseudonym. Equal values identify the same retained internal pseudonym only within this dataset. |
| `sensor_name` | string | Sensor code linked to `sensor_coordinates.csv`. |
| `rssi_median` | double | Median RSSI, in dBm, among accepted one-second values in the window. |
| `rssi_sum` | double | Sum of accepted one-second RSSI values. RSSI values are negative; do not interpret a more negative sum as a stronger signal. |
| `detections` | int64 | Number of contributing unique one-second slots; constrained to 1–20. |

The localization score `strength_sum` (the sum of `100 + RSSI` over contributing seconds) is not shipped because it equals `100 × detections + rssi_sum` exactly on every row; restore it with that formula. The public sample archives in the online documentation follow the same convention. See `SLIM_TRANSFORM.md` for the verified removal record.

`sensor_coordinates.csv` contains `dataset_id`, `site`, `sensor_name`, `longitude`, `latitude`, and `crs_epsg`; all coordinates use EPSG:4326. The 24 campus points retain the source GeoPackage CRS transformation, and the 17 commercial-district points use the workflow's explicit EPSG:4326 assignment.

## Interpretation limits

An observed address is not equivalent to a physical device or a person. Device-managed address changes can split observations, and one person can carry multiple devices. Location, Track, Revisits, and Activities are inferences from retained pseudonymous observations and should be reported as such.
