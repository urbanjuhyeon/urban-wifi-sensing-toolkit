# Historical correction and public-handoff audit

The historical-v4 scripts documented in Sections 1--4 below build and verify
an isolated candidate for the two historical 20-second datasets. They do not
modify current public files, upload data, or authorize a release.

## Bundled tutorial archives

`rekey_tutorial_data.py` is the separate release gate for field-derived
tutorial archives that must stay in their own pseudonym space. Its remaining
live scope is the campus GPS-linked location archive (`sample_loc.zip`),
which is keyed apart from the released data so participant GPS traces cannot
be joined to the full dataset. The main campus tutorial sample no longer uses
a separate scope: `scripts/0-8-sample-main-from-release.R` derives it as a
pure filter of the released dataset. Each remaining scope requires a distinct
private 32-byte key stored outside the repository. Every released identifier is the first 128 bits
of a domain-separated HMAC-SHA-256 value, represented as 32 lowercase
hexadecimal characters. The Chapter 3 processing walkthrough is now fully
synthetic and is governed separately by
`scripts/pipeline/build_synthetic_tutorial_archive.py`.

The required sequence is `build` from a preserved legacy source, then `verify`,
`scan`, and finally `apply`. The builder rejects an input that already contains
32-character identifiers, the verifier checks non-identifier invariance and
zero overlap across scopes, and the scanner rejects release-key material. The
`apply` command modifies only its fixed eight-file allowlist. Run
`python scripts/release/rekey_tutorial_data.py --help` for the exact arguments.

This downstream tutorial transformation does not claim that HMAC was used
during the historical field collections.

## Keep the three identifier stages separate

1. **Historical restricted processing.** The 2019 and 2020 workflows retain
   their documented historical restricted identifiers so that provenance can be audited. The
   historical v4 candidate corrects timestamps and commercial-district
   duplicate one-second keys. It is an internal intermediate, not the public
   handoff.
2. **Release-specific keyed re-pseudonymization.** A separate 32-byte private
   key is used for each dataset. Each internal pseudonym is replaced by the
   first 16 bytes (32 lowercase hexadecimal characters) of a domain-separated
   HMAC-SHA-256 value. The replacement is one-to-one within a dataset, so an
   observed pseudonym remains consistent across its rows. The keys and mapping
   are not written to the candidate.
3. **Release decision.** The resulting records remain pseudonymous, not
   anonymous, because their 20-second observations are intentionally
   connectable within each dataset. Access conditions and disclosure review
   therefore remain a separate final gate.

This separation does not claim that HMAC was used during the historical field
collections. The maintained Raspberry Pi collector has its own
deployment-scoped HMAC contract.

## 1. Build and verify the restricted historical v4 intermediate

The campus timestamps were recorded as timezone-naive Korean wall-clock
labels. The builder interprets them as `Asia/Seoul` and stores the corresponding
UTC instants. The commercial-district builder also applies the documented open
RSSI filter, collapses duplicate pseudonym × sensor × one-second keys by median
RSSI, and aggregates the unique seconds into 20-second windows.

From the repository root with R 4.6:

```powershell
& 'C:\Program Files\R\R-4.6.0\bin\Rscript.exe' scripts/release/build_historical_v4_candidate.R
& 'C:\Program Files\R\R-4.6.0\bin\Rscript.exe' scripts/release/verify_historical_v4_candidate.R
```

The default intermediate is
`tmp/historical-v4-audit/historical-v4-candidate-1/`. Its verifier checks the
timezone correction, duplicate handling, row impacts, aggregate impacts, and
file checksums. Restricted one-second input is not copied into that directory.

## 2. Create private release-build keys

Choose an institution-approved, encrypted, author-only directory outside this
repository. Generate a different key for each dataset:

```powershell
python scripts/release/generate_release_key.py --output <private-key-directory>\unist19-release.key
python scripts/release/generate_release_key.py --output <private-key-directory>\uou20-release.key
```

The generator creates exactly 32 random bytes, refuses overwrite and repository
destinations, and requests owner-only permissions where the operating system
supports them. Never commit, upload, email, log, or package these files. Store
them only as long as the approved release-maintenance plan requires.

## 3. Build, verify, and scan the public-handoff candidate

```powershell
& 'C:\Program Files\R\R-4.6.0\bin\Rscript.exe' scripts/release/build_public_release_candidate.R `
  --campus-key-file=<private-key-directory>\unist19-release.key `
  --district-key-file=<private-key-directory>\uou20-release.key

& 'C:\Program Files\R\R-4.6.0\bin\Rscript.exe' scripts/release/verify_public_release_candidate.R `
  --campus-key-file=<private-key-directory>\unist19-release.key `
  --district-key-file=<private-key-directory>\uou20-release.key

python scripts/release/scan_public_release_secrets.py `
  --candidate tmp/public-release-handoff/historical-v4-public-candidate-1 `
  --key-file <private-key-directory>\unist19-release.key `
  --key-file <private-key-directory>\uou20-release.key
```

The builder first verifies the historical candidate checksums. It computes the
two identifier mappings in memory, writes only the seven-column 20-second
files, and refuses an existing output directory. The verifier independently
recomputes the mappings and requires:

- identical row and pseudonym counts before and after replacement;
- one row per timestamp × pseudonym × sensor key;
- valid 32-character lowercase public pseudonyms;
- zero missing mapped rows and zero changes to timestamp, sensor, RSSI,
  detection, or strength values;
- no overlap between internal and public pseudonyms;
- no overlap between the two datasets' public pseudonyms; and
- matching manifest sizes and SHA-256 file checksums.

The final byte-level scanner enforces the six-file allowlist and checks every
candidate file for key bytes, encoded key values, key paths, private mapping
field names, and colon-delimited MAC-like values. It reports only filenames and
finding classes, never secrets or matching records.

The default output is
`tmp/public-release-handoff/historical-v4-public-candidate-1/`. It is still a
candidate. Copying or uploading it requires a separately approved access and
disclosure decision.

## 4. Prepare and verify the professor-review data package

After the public-handoff candidate has passed its key-aware verifier and
scanner, the package builder consumes only that verified directory. It does
not accept or read a release key:

```powershell
& 'C:\Program Files\R\R-4.6.0\bin\Rscript.exe' scripts/release/prepare_public_data_package.R `
  --candidate=tmp/public-release-handoff/historical-v4-public-candidate-1 `
  --output=tmp/public-data-package/historical-v4-public-package-candidate-1

& 'C:\Program Files\R\R-4.6.0\bin\Rscript.exe' scripts/release/verify_public_data_package.R `
  --package=tmp/public-data-package/historical-v4-public-package-candidate-1 `
  --output=tmp/public-data-package-verification/historical-v4-public-package-candidate-1
```

The fixed, top-level-only package contains the two complete public-candidate
Parquet files, all 41 sensor coordinates in EPSG:4326, a README, a data
dictionary, the source build and verification evidence, coordinate-source
hash evidence, and `MANIFEST.sha256` for every other file. The independent
verifier checks all 20.5 million rows, exact source checksums, UTC and schema
contracts, one-to-one sensor-coordinate coverage, source evidence, and the
absence of an invented license, DOI, upload, or access decision.

Build and verify the deterministic stored ZIP, then scan both the folder and
archive bytes:

```powershell
python scripts/release/build_public_data_zip.py `
  --package tmp/public-data-package/historical-v4-public-package-candidate-1 `
  --output tmp/public-data-package/historical-v4-public-package-candidate-1.zip

python scripts/release/verify_public_data_zip.py `
  --package tmp/public-data-package/historical-v4-public-package-candidate-1 `
  --archive tmp/public-data-package/historical-v4-public-package-candidate-1.zip

python scripts/release/scan_public_data_package.py `
  --package tmp/public-data-package/historical-v4-public-package-candidate-1 `
  --archive tmp/public-data-package/historical-v4-public-package-candidate-1.zip
```

The ZIP uses a sorted allowlist, fixed timestamp and permissions, and stored
entries, so identical package bytes produce an identical archive. The final
scanner is intentionally keyless: it detects private mapping fields, key
field/file markers, raw-capture fields, and colon-delimited MAC-like values.
The earlier source-candidate scan remains the authoritative check for the two
actual release keys, and its verification evidence is included in the package.

Neither the package folder nor ZIP is an approved release. Do not distribute
either artifact until the license, citation, DOI, access terms, and disclosure
decision have been supplied through the appropriate institutional process.

## 5. Remove the derivable strength_sum column from the shipped copy

The shipped package omits `strength_sum` because it equals
`100 * detections + rssi_sum` on every row, matching the public sample
archives that already ship without the column.

```powershell
python scripts/release/slim_public_data_package.py --package data/release-20sec
```

The script refuses to write unless the identity holds exactly on every row,
verifies that the six remaining columns are value-identical after the
rewrite, regenerates `MANIFEST.sha256`, and records the evidence in
`SLIM_TRANSFORM.md`. The stage-3 and stage-4 verifiers above continue to
validate the seven-column pipeline candidate; this transform applies only to
the shipped copy of the package.
