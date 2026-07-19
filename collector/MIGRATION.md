# Migration from the legacy collector

The maintained collector must not be installed over the historical
`sensing.service`. That unit ran the collector as root and may still reference
raw-frame, Bluetooth, cloud-upload, or broadly writable paths. The new installer
fails closed when it finds the legacy unit.

1. Stop and disable the old unit without deleting data:

   ```bash
   sudo systemctl stop sensing.service
   sudo systemctl disable sensing.service
   sudo systemctl cat sensing.service
   ```

2. Inventory restricted material before changing anything: historical SQLite
   files, `/home/pi/data`, Samba shares, Dropbox uploader configuration and
   tokens, logs, and any `0777` directories. Follow the approved retention and
   transfer plan. Do not copy these materials into a public repository or the
   reviewer archive.
3. Revoke unused cloud credentials and remove obsolete network shares. Rotate
   any credential that may have been recorded in a screenshot, video, log, or
   shell history.
4. After retaining the evidence required by the approved plan, remove the old
   unit file, run `sudo systemctl daemon-reload`, and verify that
   `systemctl status sensing.service` reports that the unit is not found.
5. Install the maintained collector. Generate one exact 32-byte deployment key
   on a secured provisioning host, copy that same file to every sensor for the
   approved campaign, and configure the same opaque `deployment_id` on all of
   them. Generate a new key and ID for a later campaign, even at the same site.
   Only the opaque sensor code and channel selection vary per Pi. Complete
   `docs/HARDWARE_TEST.md`; the installer does not start capture automatically.

The maintained database is a new privacy and schema boundary. Never merge a
legacy database into it in place.

## Upgrade from maintained version 1.0

Version 1.0 SQLite files contain retired 16-hex unkeyed SHA identifiers. Version
1.1 creates schema-version-2 files containing 32-hex deployment-scoped HMAC
tokens. The eight packet columns are unchanged, but the identifier constraint
and metadata contract are intentionally incompatible. The collector validates
an existing database before writing metadata and refuses a version 1 file; it
does not silently relabel or migrate one.

Stop both services and finish the approved restricted handling of every old
file before upgrading. Do not concatenate old and new rows, call the old tokens
HMACs, or attempt to infer a deployment key for historical data. Keep any
documented old analysis on its original pseudonym boundary. New collection
starts a new SQLite file and uses the current configuration fields:

```json
{
  "sensor_name": "A01",
  "deployment_id": "D2026A",
  "pseudonymization_key_file": "deployment.key"
}
```

That fragment is illustrative; retain the data-directory, queue, batch, and
interface fields from `config.example.json`. The key file contains raw bytes,
not JSON, hex, base64, or a password. It must never be placed in Git, a reviewer
ZIP, a database, a log, or a public release.

For cloned SD cards, clone identical software first, then set the card's opaque
`sensor_name` and channel selection. Provision the same approved deployment ID
and the same key file on every card in that campaign. Replacing an SD card
during the campaign uses the same pair; beginning a later campaign uses a new
pair. Securely erase retired card copies according to the approved schedule.
