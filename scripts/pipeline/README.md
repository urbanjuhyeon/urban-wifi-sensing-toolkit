# Maintained capture-to-20-second pipeline

This directory is the maintained processing path for databases produced by the
privacy-minimized capture toolkit. It is separate from the historical `0-*`
reconstruction scripts and does not reinterpret or silently rewrite either
historical public dataset.

The input `packets` table must have exactly these eight `NOT NULL` columns, in
this order:

```text
timestamp, type, subtype, strength, source_address,
source_address_randomized, channel, sensor_name
```

The maintained synthetic example is intentionally a minimal `packets`-only
fixture. A real collector schema v2 database can also contain
`capture_metadata` and `capture_interface_summary` for operational auditing.
Those tables are absent from the fixture because no hardware capture occurred;
the generator does not fabricate interface statistics or packet-loss counters.
The processing scripts use the `packets` table and therefore accept a genuine
collector database that contains the additional operational tables.

`source_address` contains the collector's 32-character lowercase hexadecimal
HMAC pseudonym (`hmac-sha256-128-v1`), not a MAC address. Sensors in one
deployment use the same deployment identifier and secret key, so the same
observed address has the same pseudonym across those sensors and across dates.
A different deployment identifier or key produces a different pseudonym. This
pipeline validates the output shape and never hashes it again; it cannot prove
the provenance of an arbitrary 32-character value. `source_address_randomized`
is the locally administered bit that capture read before HMAC processing; it
must be `0` or `1`. Timestamps must be explicit UTC strings ending in `Z`.
Local wall-clock timestamps are rejected.

## Dependencies

R 4.2 or later with `DBI`, `RSQLite`, `data.table`, and `bit64` is required.
`arrow` is required for the default Parquet outputs. CSV is supported only as
an explicit compatibility fallback and cannot retain UTC/int64 physical schema
metadata.

```r
install.packages(c("DBI", "RSQLite", "data.table", "bit64", "arrow"))
```

## Run all stages

From the repository root:

```bash
Rscript scripts/pipeline/run_pipeline.R \
  --input workflow/ch3_tutorial/maintained_capture_fixture/maintained_capture.sqlite3 \
  --output-dir workflow/ch3_tutorial/maintained_pipeline
```

The command writes and then verifies:

1. `01_aggregated_1second.parquet`: one row per source × sensor × UTC
   second, with median RSSI and raw packet count;
2. `02_cleaned_1second.parquet`: deterministic one-second deduplication,
   removal of `source_address_randomized == 1`, and removal of an identifier
   when any sensor-specific continuous session is **longer than** two hours;
3. `03_analysis_20second.parquet`: one row per source × sensor × UTC-aligned
   20-second window.

If duplicate one-second keys are supplied to the cleaning stage, their RSSI
medians are combined by a deterministic median and their raw packet counts are
summed before any filter is applied. The output retains exactly one row per
source × sensor × UTC second.

The default cleaning thresholds are explicit command-line parameters:

```bash
Rscript scripts/pipeline/run_pipeline.R \
  --input capture.sqlite3 \
  --output-dir output \
  --rssi-min -80 \
  --rssi-max -30 \
  --exclude-subtypes beacon,probe-response \
  --session-gap-seconds 300 \
  --stationary-seconds 7200
```

A gap strictly greater than 300 seconds starts a new session. A source is
classified as stationary only when a session duration is strictly greater than
7,200 seconds. The thresholds are analytical choices, not properties of the
capture hardware, and should be reported with any released result.

The 20-second schema is:

```text
timestamp UTC, source_address string, sensor_name string,
rssi_median DOUBLE, rssi_sum DOUBLE, detections INT64, strength_sum DOUBLE
```

`detections` counts distinct one-second slots and is therefore in `[1, 20]`.
The verifier enforces
`strength_sum = 100 * detections + rssi_sum` and exactly reconstructs the
20-second table from the cleaned one-second input.

To use CSV only when Arrow cannot be installed, add `--format csv`. The same
value and key checks run, but CSV cannot prove physical Parquet types.

## Timezone rule

Every pipeline timestamp remains true UTC. No stage derives local dates or
hours. Downstream Korean calendar fields must name the timezone explicitly;
never relabel a local wall-clock value as UTC. For example:

```r
timestamp_utc <- as.POSIXct(timestamp, tz = "UTC")
local_date <- as.Date(format(timestamp_utc, tz = "Asia/Seoul"))
local_hour <- as.integer(format(timestamp_utc, "%H", tz = "Asia/Seoul"))
```

The 20-second file is an **internal analysis handoff**. It retains the
deployment-scoped pseudonym produced by the collector. Aggregation and
pseudonymization do not make it anonymous and do not authorize release. A
device-level public release requires a separately approved, release- and
dataset-specific keyed re-pseudonymization step, together with the study's
privacy, governance, and disclosure review. The release builder must replace
the internal pseudonym; it must not publish the deployment key or an
internal-to-public identifier mapping.

## Offline five-metric smoke workflow

After the verified 20-second handoff, run the small, fully synthetic metric
workflow without a basemap, API key, or network connection:

```bash
Rscript scripts/pipeline/run_five_metrics.R \
  --input workflow/ch3_tutorial/maintained_pipeline/03_analysis_20second.parquet \
  --sensors workflow/ch3_tutorial/maintained_capture_fixture/synthetic_sensors.csv \
  --fixture-manifest workflow/ch3_tutorial/maintained_capture_fixture/manifest.json \
  --output-dir workflow/ch3_tutorial/maintained_metrics
```

This entry point uses base R plus `data.table` and `arrow`. It builds and then
verifies Location, Count, Track, Revisits, and Activities. Its purpose is to
prove that the common 20-second schema can reach all five calculation
contracts; it does not reproduce the campus or commercial-district findings.
The checked outputs and complete definitions are documented in
`workflow/ch3_tutorial/maintained_metrics/README.md`.

The smoke defaults keep the demonstrations' two inactivity scales separate:
Track starts a new trajectory after a gap strictly greater than 1,800 seconds,
whereas the visit-based Revisits and Activities path uses a gap strictly
greater than 7,200 seconds. Revisits counts explicit `Asia/Seoul` calendar
dates only among trajectories with at least two localized windows. Activities
also applies the declared 75 m anchor distance, 600-second episode-continuity
gap, and 300-second minimum stay duration. All stored and exported timestamps
remain UTC strings ending in `Z`.

`source_address` is retained as the schema field name, but the workflow calls
its values **retained pseudonymous identifiers**. They must not be described as
people, visitors, or known devices. The synthetic fixture applies real HMAC to
scenario-role labels using a deliberately public, fixed, test-only key. The
manifest prints that key so nobody can mistake it for a secret suitable for
field collection. No MAC address is used as an input, and no original-address
mapping exists.
