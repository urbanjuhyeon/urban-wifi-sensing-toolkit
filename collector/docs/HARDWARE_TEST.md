# Raspberry Pi hardware release gate

Desktop CI cannot prove monitor mode, radiotap RSSI, driver behavior, Linux
capabilities, or sustained writes on the intended Raspberry Pi. Run this gate
on every Raspberry Pi OS family and adapter model before field use. Record only
text pass/fail results and versions—never screenshots or videos containing
credentials, network names, MAC/IP addresses, hostnames, personal paths, or
participant data.

## 1. Governance and host preflight

- [ ] Ethics, legal, site-owner, notice, retention, and data-security approvals
      cover the exact site and dates.
- [ ] The site is not a sensitive setting excluded by the protocol.
- [ ] The Pi is dedicated, updated, access controlled, and not using default
      credentials.
- [ ] `/var/lib/urban-sensing` is not shared by Samba or synchronized to cloud
      storage.
- [ ] `timedatectl show -p NTPSynchronized --value` returns `yes`.
- [ ] `df -h /var/lib/urban-sensing` shows capacity for the bounded session and
      the approved reserve.
- [ ] Every adapter supports monitor mode and supplies radiotap RSSI.
- [ ] Every sensor has the same approved opaque `deployment_id` and a
      byte-for-byte copy of the one campaign key; only `sensor_name` and
      channel selection vary.
- [ ] `/etc/urban-sensing/deployment.key` is one regular 32-byte file, is not a
      symlink or hardlink, and is root:`urban-sensing` mode `0640`.
- [ ] The key was not independently generated on each Pi, printed, checksummed
      into a log, or copied into the configuration.

Record the platform without recording network identifiers:

```bash
cat /etc/os-release
python3 --version
uname -r
/opt/urban-sensing/venv/bin/python -m pip show dpkt pcapy-ng setuptools
```

Raspberry Pi OS uses NetworkManager. Record its current device state and verify
that exactly one managed wireless interface carries the default route. Do not
create a MAC- or `wlan`-specific persistent mapping for the automatic workflow:

```bash
nmcli -f DEVICE,TYPE,STATE device status
ip -j route show default
iw list
```

Do not mark the deployment platform as verified merely because `iw list`
mentions monitor mode; the controlled capture below must also pass.

## 2. Static validation

Use an opaque sensor code and confirm that automatic selection proposes the
expected number of capture adapters without changing them.

```bash
sudo -u urban-sensing /opt/urban-sensing/venv/bin/urban-wifi-capture validate \
  --config /etc/urban-sensing/config.json
sudo -u urban-sensing /opt/urban-sensing/venv/bin/urban-wifi-capture interfaces plan \
  --config /etc/urban-sensing/config.json
sudo /opt/urban-sensing/venv/bin/urban-wifi-capture self-test
sudo systemd-analyze verify \
  /etc/systemd/system/urban-wifi-interfaces.service \
  /etc/systemd/system/urban-wifi-capture.service
sudo systemd-analyze security urban-wifi-capture.service
```

All commands must succeed before an interface is opened. Validation must report
the intended deployment ID and channels without printing the key
or its path. It must reject placeholder sensor/deployment codes, a missing or
non-32-byte key, key/data symlinks, unsafe key/state permissions, and data
directories outside `/var/lib/urban-sensing`.

## 3. Two-minute controlled capture

Use an approved controlled location. Do not use a personal hotspot, home SSID,
or identifiable network as a fixture.

```bash
sudo systemctl start urban-wifi-interfaces.service
sudo systemctl start urban-wifi-capture.service
sudo systemctl status --no-pager urban-wifi-capture.service
```

After two minutes, stop capture before inspecting or copying any file:

```bash
sudo systemctl stop urban-wifi-capture.service
sudo systemctl stop urban-wifi-interfaces.service
sudo journalctl -u urban-wifi-capture.service --since "5 minutes ago" --no-pager
```

Fail if a service restarted, a monitor interface or radiotap check failed, a
writer/producer exited unexpectedly, or the restart limit was reached.

## 4. Select one stopped-session database

The collector creates one database per service run, not one automatically per
calendar day. Select the file created by this test explicitly:

```bash
DB="$(sudo find /var/lib/urban-sensing/data -maxdepth 1 -type f \
  -name 'raw_wifi_*.sqlite3' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
test -n "${DB}"
printf '%s\n' "${DB}"
sudo stat -c '%a %U:%G %n' "${DB}"
```

Do not use a wildcard as the SQLite argument: retries may have produced more
than one file, and validating the wrong file can conceal a failed run.

## 5. Integrity, schema, and privacy contract

With both services stopped, checkpoint WAL and run the following read-only
checks:

```bash
sudo -u urban-sensing sqlite3 "${DB}" 'PRAGMA wal_checkpoint(TRUNCATE);'
sudo -u urban-sensing sqlite3 "${DB}" 'PRAGMA integrity_check;'
sudo -u urban-sensing sqlite3 "${DB}" 'PRAGMA table_info(packets);'
sudo -u urban-sensing sqlite3 "${DB}" \
  'SELECT key,value FROM capture_metadata ORDER BY key;'
sudo -u urban-sensing sqlite3 "${DB}" \
  "SELECT count(*) AS invalid_rows FROM packets
   WHERE length(source_address) <> 32
      OR source_address <> lower(source_address)
      OR source_address GLOB '*[^0-9a-f]*'
      OR source_address_randomized NOT IN (0,1)
      OR timestamp NOT GLOB '????-??-??T??:??:??*Z';"
sudo -u urban-sensing sqlite3 "${DB}" \
  'SELECT channel,count(*) AS rows FROM packets GROUP BY channel ORDER BY channel;'
```

Pass only when:

- the database is `600`, owned by `urban-sensing`, and integrity is `ok`;
- `packets` has exactly the documented eight columns;
- `raw_frames_stored`, `raw_addresses_stored`, `ssid_stored`, `bssid_stored`,
  `destination_address_stored`, and `bluetooth_stored` are `false`;
- `cloud_upload_enabled` is `false`;
- the identifier algorithm/length and pre-HMAC randomization rule match the
  README;
- `identifier_scheme = hmac-sha256-128-v1`, `identifier_scope = deployment`,
  and `deployment_id` matches the approved opaque campaign code;
- metadata contains no key, key path, key fingerprint, or comparison token;
- the invalid-row query returns zero; and
- every configured channel has records in the controlled test interval.

## 6. Observation-loss audit

```bash
sudo -u urban-sensing sqlite3 -header -column "${DB}" \
  'SELECT interface,channel,pcap_received,pcap_dropped,interface_dropped,
          queue_dropped,records_emitted,records_filtered,completed_at
   FROM capture_interface_summary ORDER BY channel,interface;'
sudo -u urban-sensing sqlite3 -header -column "${DB}" \
  'SELECT (SELECT count(*) FROM packets) AS packet_rows,
          (SELECT coalesce(sum(records_emitted),0)
             FROM capture_interface_summary) AS emitted_rows,
          (SELECT count(*) FROM packets) =
          (SELECT coalesce(sum(records_emitted),0)
             FROM capture_interface_summary) AS rows_match;'
```

Every configured interface must have exactly one summary row, positive
`pcap_received`, positive `records_emitted`, and `completed_at` ending in `Z`.
For the controlled release test, require `pcap_dropped = 0`,
`interface_dropped = 0`, and `queue_dropped = 0`. Any nonzero loss invalidates
the test until capacity, driver, or workload is investigated and the protocol's
explicit threshold is approved. A high `records_filtered` count is not queue
loss, but zero emitted records can indicate incompatible frames or an unsuitable
test environment.
The row-accounting query must report `rows_match = 1`; otherwise records were
lost between accepted producer output and the stopped SQLite database.

## 7. Shutdown, transfer, and evidence

- [ ] Both services are inactive and monitor interfaces are removed.
- [ ] No `-wal` or `-shm` file remains after the checkpoint.
- [ ] The stopped database is transferred only through the approved restricted
      route; it is never placed in the public repository or reviewer ZIP.
- [ ] The sensor copy is retained or deleted according to the approved schedule.
- [ ] The release log records date, OS/kernel/Python/dependency versions,
      adapter models, opaque deployment/sensor codes, row counts, per-channel
      counts, loss counters, service status, and checker outputs.
- [ ] The release log contains no credentials, raw identifiers, SSIDs, IPs,
      hostnames, personal paths, key values or fingerprints, screenshots, or
      packet samples.

Verify the sidecar condition rather than relying on a visual directory listing:

```bash
SIDECAR="$(sudo find /var/lib/urban-sensing/data -maxdepth 1 -type f \
  -name "$(basename "${DB}")-*" -print -quit)"
test -z "${SIDECAR}"
```

For a multi-day deployment, repeat this stop/checkpoint/audit/transfer sequence
for each approved daily session and verify free space before the next start.
