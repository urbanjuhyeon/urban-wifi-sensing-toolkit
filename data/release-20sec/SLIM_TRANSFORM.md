# Slim transform record

Date: 2026-07-17

The `strength_sum` column was removed from both Parquet files because
it equals `100 * detections + rssi_sum` on every row. The identity was
verified exactly (zero deviation) on every row before removal, and the six
remaining columns were verified value-identical after the rewrite. Restore
the column with `strength_sum = 100 * detections + rssi_sum`.

| File | Rows | Identity max deviation | SHA-256 before | SHA-256 after |
|---|---|---|---|---|
| `wifi_unist19_20sec.parquet` | 15,021,058 | 0.0 | `825c2014cdc24e4b45e8ef358de56ab0e9ba771afe2d919d8cb76398515551f1` | `cbaf44cda62bc25f9f1dec94f54cebab7809b525bf204019b79bb0a43f2c8ce6` |
| `wifi_uou20_20sec.parquet` | 5,436,472 | 0.0 | `9a5332bfec515f4028c5a04945eaecd50afac452fda3a8cb23d6c461e4a5cad5` | `0edd2d721bc707581fd8dd274af42dea546a099e189cd54a0808c43036bbf14b` |

Produced by `scripts/release/slim_public_data_package.py`, which refuses
to write unless the identity holds exactly. `MANIFEST.sha256` was
regenerated after the transform.
