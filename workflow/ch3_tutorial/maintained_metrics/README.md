# Maintained five-metric smoke outputs

These files are the verified output of the fully synthetic, offline workflow
in `scripts/pipeline/run_five_metrics.R`. They show that the maintained
20-second handoff can reach all five metric contracts. They are not estimates
for either historical field deployment and must not be used to reproduce or
support the manuscript's empirical percentages, maps, or substantive findings.
The retained identifiers are 32-character deployment-scoped HMAC-SHA-256
pseudonyms generated from synthetic role labels with the fixture's explicitly
public, test-only key; no MAC address or original-address mapping exists.

## Run from the repository root

```bash
Rscript scripts/pipeline/run_five_metrics.R \
  --input workflow/ch3_tutorial/maintained_pipeline/03_analysis_20second.parquet \
  --sensors workflow/ch3_tutorial/maintained_capture_fixture/synthetic_sensors.csv \
  --fixture-manifest workflow/ch3_tutorial/maintained_capture_fixture/manifest.json \
  --output-dir workflow/ch3_tutorial/maintained_metrics
```

Only base R, `data.table`, and `arrow` are used. The workflow requires no map,
geographic service, API key, or internet connection. Sensor coordinates are
synthetic local Cartesian metres with no geographic origin.

## Calculation contracts

- **Location** selects exactly one sensor for each retained identifier and UTC
  20-second window. The largest `strength_sum` wins; an exact tie is resolved
  by ascending `sensor_name`, so input row order cannot change the result.
- **Count** counts distinct retained identifiers only after Location has
  assigned each identifier-window to one sensor. It therefore cannot
  double-count the same identifier-window at overlapping sensors.
- **Track** orders Location rows, starts a new trajectory only when the
  inactivity gap is strictly greater than 1,800 seconds, and marks an OD
  trajectory only when it contains at least two windows and has different
  first and last sensors.
- **Revisits** uses a separate 7,200-second visit gap. A qualifying trajectory
  has at least two localized windows. It counts distinct dates derived with
  `tz = "Asia/Seoul"` from true UTC timestamps and labels an identifier
  `Single-day observed` or `Multi-day observed`. These labels describe an
  observed identifier, not a person or a known visitor.
- **Activities** uses the 7,200-second visit gap, retains trajectories with at
  least three windows and duration at most 7,200 seconds, starts a new spatial
  cluster when distance from its anchor exceeds 75 m, splits an episode at a
  detection gap greater than or equal to 600 seconds, and classifies duration
  greater than or equal to 300 seconds as a stay.

Every timestamp in an output data file remains an explicit UTC string ending
in `Z`. Local time is introduced only for the Revisits calendar date.

## Files and verified result

| File | Contract | Rows | Synthetic check |
|---|---|---:|---|
| `01_location.csv` | one strongest sensor per identifier-window | 32 | sensor overlap is resolved deterministically |
| `02_count.csv` | distinct localized identifiers by sensor-window | 32 | all 32 localized rows are counted exactly once |
| `03_track_trajectories.csv` | trajectory endpoints and OD flag | 3 | two A01-to-A02 trajectories qualify as OD |
| `03_track_od.csv` | OD summary | 1 | A01-to-A02: two trajectories from one retained identifier |
| `04_revisits.csv` | qualifying trajectories by local date | 2 | the moving identifier is observed on 15 and 16 January 2024 locally |
| `05_activities.csv` | episode and stay classification | 2 | one 420-second A02 episode is a Short stay |
| `manifest.json` | inputs, definitions, parameters, row counts | -- | declares smoke-test scope and UTC/local-calendar boundary |

The packet-level stay scenario spans 420.6 seconds, while the synthetic
20-second handoff represents it from `00:10:00Z` through `00:17:00Z`, a
420-second difference between window starts. This expected 0.6-second edge
loss is a consequence of aggregation, not a change to the 300-second stay
threshold; the episode still qualifies.

## Boundary with the manuscript

The 1,800-second Track gap, 7,200-second commercial-district visit gap, 75 m
distance, 600-second continuity gap, and 300-second stay minimum correspond to
parameters described across the manuscript and online toolkit. The synthetic
workflow additionally makes its quality gates executable: at least two windows
for a Revisits-qualifying trajectory, and at least three windows plus a
7,200-second maximum duration for Activities. Those gates should not be
retroactively attributed to a historical result unless its historical analysis
script applies the same rules.

The outputs establish code-path completeness only. They do not validate sensor
accuracy, infer people from identifiers, make 20-second data anonymous, or
resolve limitations caused by MAC-address randomization.
