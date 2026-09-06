# WiFi Sensing for Urban Analytics: An Open-Source R Toolkit

This repository documents a reproducible pipeline for turning privacy-minimized
passive WiFi observations into five urban-analysis outputs: Location, Count,
Track, Revisits, and Activities.

The rendered online documentation is available at
[urbanjuhyeon.github.io/urban-wifi-sensing-toolkit](https://urbanjuhyeon.github.io/urban-wifi-sensing-toolkit/).

The version 1.4.0 snapshot of the code, data, and documentation is archived at
[Zenodo](https://doi.org/10.5281/zenodo.21442379). This repository and the online
book provide the maintained code and documentation. Citation metadata are in
`CITATION.cff`.

## Pipeline boundary

The maintained pipeline separates collection, restricted processing, and
public handoff:

1. A Raspberry Pi collector stores an allowlisted eight-column SQLite schema.
   Before storage, each observed source address is replaced with the first 128
   bits of a deployment-scoped, domain-separated HMAC-SHA-256 value, encoded as
   32 lowercase hexadecimal characters. Every sensor in one campaign uses the
   same approved deployment ID and key; a later campaign uses a new deployment
   ID and key.
2. Restricted processing collapses unaggregated detection records to one-second records,
   applies the documented cleaning rules, and aggregates retained records to
   20-second pseudonym × sensor windows.
3. A separately controlled release build replaces internal pseudonyms with
   32-character, release- and dataset-specific HMAC-SHA-256 pseudonyms. It does
   not publish keys, mappings, packet-level field data, or restricted one-second
   inputs.

The identifiers remain consistent within their intended scope so that movement
and revisit metrics can be computed. They are therefore **pseudonymous, not
anonymous**. The code does not attempt to reverse device-managed MAC address
randomization or infer personal identity.

## Safe executable example

The executable processing tutorial begins at the maintained collector's SQLite
storage boundary with the entirely synthetic fixture at
`workflow/ch3_tutorial/maintained_capture_fixture/`. It contains virtual sensor
coordinates and no field-derived network address, SSID, BSSID, packet payload,
or geographic location. The scripts in `scripts/pipeline/` reproduce:

```text
synthetic SQLite → one second → cleaning → 20 seconds → five metric smoke tests
```

Run the maintained processing route from the repository root. The examples use
the portable executable name `Rscript`; place it on `PATH` or substitute the
appropriate local executable path. Each command is on one line and uses no
shell-specific continuation syntax:

```bash
Rscript scripts/pipeline/run_pipeline.R --input workflow/ch3_tutorial/maintained_capture_fixture/maintained_capture.sqlite3 --output-dir workflow/ch3_tutorial/maintained_pipeline
Rscript scripts/pipeline/run_five_metrics.R --input workflow/ch3_tutorial/maintained_pipeline/03_analysis_20second.parquet --sensors workflow/ch3_tutorial/maintained_capture_fixture/synthetic_sensors.csv --fixture-manifest workflow/ch3_tutorial/maintained_capture_fixture/manifest.json --output-dir workflow/ch3_tutorial/maintained_metrics
```

Chapter 3 of `docs/` explains each boundary and command. Historical data
correction and release-candidate scripts are isolated in `scripts/release/`;
their README explains the required private-key and verification procedure.

## Data map

All field-derived data in this repository come from one source and appear at
three depths:

| Tier | What | Where | Used by |
|---|---|---|---|
| Synthetic fixture | fully synthetic capture, no personal data | `workflow/ch3_tutorial/` | processing walkthrough (book Ch. 3) |
| One-week sample | one local week filtered from the released campus dataset | `docs/downloads/sample_main.zip` | metric tutorials (book Ch. 4) |
| Release datasets | full 20-second campus (15.0M rows) and commercial-district (5.4M rows) data | `data/release-20sec/` | case study (book Ch. 5) and the manuscript |

`scripts/0-8-sample-main-from-release.R` derives the sample from the release;
pseudonyms, schema, and values are identical, so sample observations can be
followed into the full data. The one exception is the GPS validation subset
(`docs/downloads/sample_loc.zip`, book Ch. 4.2): its identifiers are keyed
separately so participant GPS traces cannot be joined to the released data.

All release identifiers are 32-character, release- and dataset-specific
HMAC-SHA-256 pseudonyms assigned in a verified downstream handoff. They do
not change the provenance of the 2019 or 2020 capture method, and the
maintained HMAC collector must not be described as the historical capture
method.

## Requirements

- R 4.2 or later for the maintained synthetic pipeline; the historical release scripts were verified with R 4.6
- Python 3 for fixture, key-generation, and security tests
- Quarto for the online documentation

## License

Repository source code and original documentation are licensed under the MIT
License as stated in `LICENSE`. The released datasets under
`data/release-20sec/` are licensed under Creative Commons Attribution 4.0
International (CC BY 4.0) as stated in `data/release-20sec/LICENSE`.
Third-party imagery, basemaps, and other incorporated materials remain subject
to their respective terms.
