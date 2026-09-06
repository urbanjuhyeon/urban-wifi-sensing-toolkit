# Download archives

## Field-derived tutorial archives

- `sample_main.zip`: the one-week campus tutorial sample, a pure filter of
  the released campus dataset (`data/release-20sec/wifi_unist19_20sec.parquet`,
  local week 2019-10-28 through 2019-11-03, Asia/Seoul). Pseudonyms, schema,
  and values are identical to the release, so anything observed in the sample
  can be followed into the full data. Derived by
  `scripts/0-8-sample-main-from-release.R`.
- `sample_loc.zip`: the GPS validation subset for the Location chapter. Its
  identifiers use a separate private HMAC key so that participant GPS traces
  cannot be joined to the released dataset; the WiFi and GPS files share one
  pseudonym space within this archive only.

The 2019 field-derived data were re-pseudonymized downstream; this does not
claim that the maintained collector or deployment-scoped HMAC was used at
capture. These time-linked records remain pseudonymous, not anonymous.

The GPS-scope key and identifier mappings are not included. Downloaded
archive bytes can be checked against `sample-archives.sha256`, which lists
exactly these field-derived archives.

## Capture-software archive

`urban-wifi-capture.zip` is a deterministically generated,
text-only snapshot used by Chapters 2.1--2.3. It contains the
maintained Raspberry Pi collector, installer, systemd units, tests, and
governance files.

The archive contains no deployment key, database, packet capture, image,
video, credential, Git history, or author-identifying repository URL. Verify
it before extraction with `urban-wifi-capture.sha256`.

The canonical source is tracked in `collector/`. The internal
`MANIFEST.sha256`, collector ZIP, and outer checksum are generated artifacts.
From the repository root, regenerate them with:

```bash
python scripts/docs/build_capture_archive.py --archive docs/downloads/urban-wifi-capture.zip --checksum docs/downloads/urban-wifi-capture.sha256
```

Verify that the committed artifacts match two fresh in-memory builds from the
canonical source with:

```bash
python scripts/docs/build_capture_archive.py --archive docs/downloads/urban-wifi-capture.zip --checksum docs/downloads/urban-wifi-capture.sha256 --check
```

The check fails if the source member allowlist, normalized contents, archive
metadata, internal manifest, ZIP bytes, or outer checksum drift.

This is a maintained reference implementation for new deployments. It is not
the source image executed during the 2019 or 2020 field collections, and its
documented HMAC safeguards must not be attributed retroactively to those
historical devices. For a new deployment, the maintained collector stores the
first 128 bits of a deployment-scoped HMAC-SHA-256 value as 32 lowercase
hexadecimal characters; it never writes the observed source address to disk.

## Synthetic processing tutorial

`urban-wifi-synthetic-pipeline.zip` is the deterministic, allowlisted archive
for the offline SQLite-to-one-second-to-20-second tutorial and its five metric
smoke tests. It contains only the fully synthetic fixture, virtual sensor
coordinates, checked intermediate and metric outputs, the required R scripts,
the fixture generator, tests, and an internal `MANIFEST.sha256`.

This archive is the sole Chapter 3 packet-table and processing walkthrough.
The retired field-derived `sample_raw.zip` and `sample_aggregated.zip` are not
part of the public downloads or the field-derived checksum manifest.

The synthetic archive contains no field records, raw MAC addresses, deployment
or release keys, identifier mapping, geographic coordinates, author identity,
or Git history. Its fixed public test-only key is documented in the synthetic
fixture manifest and must never be used for field collection. Verify the ZIP
with `urban-wifi-synthetic-pipeline.sha256` before extraction.
