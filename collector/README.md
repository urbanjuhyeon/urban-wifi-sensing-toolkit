# Urban WiFi capture reference implementation

This repository is the Raspberry Pi acquisition layer of the *WiFi Sensing for
Urban Analytics* toolkit. It turns live radiotap/802.11 observations into a
privacy-minimized SQLite intermediate. The companion R processing pipeline then
creates cleaned 1-second records, an internal 20-second analysis handoff, and
the five documented urban-analytics metrics. Any public 20-second handoff is a
separate, approved release with release-specific re-pseudonymization.

This is a maintained reference implementation, not a byte-for-byte copy of the
2019 or 2020 field-device images. The historical boundary and substantive
corrections are documented in [PROVENANCE.md](PROVENANCE.md). Do not use this
code to restate unverified details of the historical deployments.

## Release contract

The `packets` table contains exactly eight columns:

| Column | Contract |
|---|---|
| `timestamp` | UTC capture time, RFC 3339 text ending in `Z` |
| `type` | `management` or `data` |
| `subtype` | Parsed 802.11 subtype |
| `strength` | RSSI in dBm |
| `source_address` | 32 lowercase hexadecimal characters from deployment-scoped HMAC-SHA-256 (first 128 bits) |
| `source_address_randomized` | Locally administered bit from the original bytes (`0` or `1`) |
| `channel` | Configured 2.4-GHz channel |
| `sensor_name` | Opaque, validated sensor code |

The identifier scheme is `hmac-sha256-128-v1`, scoped to one deployment. Its
HMAC message is the concatenation below; the two-byte deployment length is an
unsigned big-endian integer:

```text
UTF-8("urban-wifi-capture") || 00 ||
UTF-8("hmac-sha256-128-v1") || 00 || UTF-8("deployment") || 00 ||
uint16_be(length(deployment_id)) || ASCII(deployment_id) || 00 ||
ASCII(lowercase colon-separated MAC)
```

The fixed language-independent test vector uses byte values `0` through `31`
as its non-secret test key, deployment ID `DEPLOYMENT_TEST_2026`, and canonical
MAC `aa:bb:cc:dd:ee:ff`. The expected token is
`e6ef51ca345d85b9eebaf92e2dc5d20e`. This vector is test material only, never a
deployment key.

The collector reads the locally administered bit before HMAC. Raw address
bytes are discarded inside the packet process; only the 32-character token and
the `0`/`1` flag cross the queue boundary. Broadcast, multicast, and invalid
source addresses are rejected. The flag reports one address bit; it is not
proof that an address was or was not randomized.

Within one deployment, the same key, deployment ID, and canonical MAC produce
the same token across every sensor and service restart. `sensor_name`, channel,
timestamp, and session are deliberately absent from the HMAC input. Different
deployment IDs or different keys produce different tokens, including when a
device returns to the same site in a later campaign. This preserves the five
within-deployment metrics while preventing direct identifier joins between
separately keyed deployments. It does not defeat operating-system MAC
randomization: a changed MAC still produces a changed token.

For data frames, radiotap RSSI must be paired with the over-the-air transmitter.
The maintained implementation therefore retains direct/IBSS and
client-originated ToDS data frames, but excludes FromDS and four-address WDS
frames. This corrects the earlier public implementation's possible pairing of
an address-3 logical source with an address-2 transmitter's RSSI.

The collector never stores raw MAC addresses, packet frames, SSIDs, BSSIDs,
destination addresses, Bluetooth observations, or cloud credentials. There is
no option to enable them. A separate `capture_interface_summary` table records
per-interface libpcap receive/drop counters, queue drops, emitted records, and
filtered records so count-based results can be audited.

SQLite metadata records schema version 2, the scheme and deployment scope, and
the non-secret opaque deployment ID. It never records the key, key path, a key
fingerprint, or a key-derived comparison code.

The SQLite file is a restricted, pseudonymized intermediate, not packet-level
public data and not anonymous data. The companion toolkit's internal 20-second
analysis handoff also remains restricted. A proposed 20-second public handoff
requires a separate approval, release-specific re-pseudonymization, and the
privacy review described in [PRIVACY.md](PRIVACY.md).

## Ethics and security gate

Obtain the required ethics, legal, site-owner, and data-security approvals
before passive sensing. Avoid excluded sensitive locations, provide notice when
required, use an approved retention schedule, and keep the sensor dedicated and
updated. HMAC pseudonymization does not make a stable device token anonymous.
Read [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) before installation.

## Target platform—not yet a hardware certification

- Raspberry Pi OS Bullseye or Bookworm;
- Python 3.9 on Bullseye or Python 3.11 on Bookworm;
- one or more adapters that support monitor mode **and radiotap RSSI**;
- `libpcap`, `iw`, and `iproute2`; and
- synchronized system time.

Bookworm uses NetworkManager by default. The dedicated capture adapters must be
marked unmanaged before direct `ip`/`iw` configuration; the exact preflight is
in [docs/HARDWARE_TEST.md](docs/HARDWARE_TEST.md). The CI release gate is
configured to build the full dependency set on Linux with Python 3.9 and 3.11;
that gate must pass before publication. Bullseye/Bookworm and each adapter model
remain unverified until the checklist passes on the real Pi.

Runtime dependencies are locked to `dpkt 1.9.8` and `pcapy-ng 2.0.0`, with
download hashes in `requirements.txt`. `pcapy-ng` is compiled from source, so a
compiler and libpcap headers are required. The build backend is separately
locked in `requirements-build.txt`.

## Retrieve the code

For anonymous peer review, use the supplied allowlist-built archive:

```bash
sudo apt-get update
sudo apt-get install -y unzip
unzip urban-wifi-capture-anonymous.zip
cd capture-scripts
```

For a published repository checkout, substitute the release URL supplied with
the accepted toolkit:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone <capture-repository-url> capture-scripts
cd capture-scripts
```

Do not substitute an older public branch: it may contain the historical root
service or obsolete collection options.

## Migrate or install without starting capture

If the machine has a legacy `sensing.service`, stop here and follow
[MIGRATION.md](MIGRATION.md). The installer deliberately refuses to overwrite
that root service or to modify an active maintained service.

Review the installer, then run:

```bash
sudo bash install.sh
```

The installer retries transient APT downloads and applies bounded HTTP/HTTPS
timeouts. If APT still reports `Failed to fetch` from an unreachable package
mirror, repair or replace the mirror configured by Raspberry Pi OS, then run
the same installer command again. The installer does not silently change the
device's package source to a location-specific mirror.

The installer uses hash-locked Python dependencies and creates:

- root-owned code under `/opt/urban-sensing`;
- root-owned configuration at `/etc/urban-sensing/config.json` (`0640`);
- a protected location for a separately provisioned deployment key;
- the non-login `urban-sensing` service account;
- `/var/lib/urban-sensing/data` owned by that account (`0700`); and
- split, capability-bounded systemd units.

It does **not** generate a key, enable capture, or start capture. Generating a
different key independently on each Pi would break cross-sensor metrics.

## Provision one deployment boundary

Define a deployment as one approved collection campaign over a bounded place
and period. Use an opaque code such as `D2026A`, not a place, institution,
researcher, or participant name. A restart, SD-card replacement, or sensor swap
during that campaign keeps the same deployment ID and key. A later campaign,
including a return to the same site, gets a new ID and a newly generated key.

Run the generator exactly once on a secured provisioning host after installing
the package:

```bash
sudo /opt/urban-sensing/venv/bin/urban-wifi-capture generate-key \
  --output /etc/urban-sensing/deployment.key
sudo chown root:urban-sensing /etc/urban-sensing/deployment.key
sudo chmod 0640 /etc/urban-sensing/deployment.key
```

The command uses the operating system CSPRNG, writes exactly 32 raw bytes with
mode `0600`, and refuses an existing path or symlink. The following ownership
commands make the installed copy root-managed and group-readable by the service.
Do not type a key into JSON or a command line, and do not use a 64-character hex
string, base64 text, a password, the sensor name, or the deployment ID as the
key. Copy the same file through the approved offline provisioning route to all
Pis in this deployment, then protect every copy as root:`urban-sensing` mode
`0640`. Verify copies against the secured master with a non-printing byte
comparison; do not publish or retain a checksum/fingerprint.

Every Pi runs identical collector code. Its configuration differs only where
operation requires it: all Pis share `deployment_id` and key bytes, while each
has its own opaque `sensor_name` and selected channel list. Losing the only approved
key backup during a deployment breaks continuity; exposing one card's key can
affect the whole deployment. Follow the approved retention plan and securely
remove the key from every card after the restricted validation period.

## Configure and validate

Edit every placeholder. Use an opaque sensor code such as `A01`. Set the same
opaque `deployment_id` and relative `pseudonymization_key_file` on all cards.
The key path is resolved against the directory containing `config.json`.

The default automatic interface mode stores channels, not MAC addresses or
boot-dependent `wlan` names. At runtime it requires exactly one managed wireless
default-route interface, preserves that interface for administration, and uses
all remaining managed wireless interfaces for capture. The candidate count must
equal the channel count before any interface is changed. For example:

```json
"interfaces": {
  "mode": "auto",
  "channels": [1, 6, 11]
}
```

Use a one-element channel list for one external adapter. The earlier explicit
interface-array format remains supported for separately reviewed specialist
setups, but it is not the default tutorial workflow.

Automatic mode creates a separate monitor interface (`ucap0`, `ucap1`, and so
on) from each selected dedicated adapter, matching the earlier `start.py`
hardware workflow without saving boot-dependent physical names. On
NetworkManager-based Raspberry Pi OS releases, the bounded interface oneshot
temporarily marks only those selected capture adapters unmanaged before monitor
creation and returns them to NetworkManager on stop. The default-route adapter
is never released.

```bash
sudoedit /etc/urban-sensing/config.json
sudo -u urban-sensing /opt/urban-sensing/venv/bin/urban-wifi-capture validate \
  --config /etc/urban-sensing/config.json
sudo -u urban-sensing /opt/urban-sensing/venv/bin/urban-wifi-capture interfaces plan \
  --config /etc/urban-sensing/config.json
sudo /opt/urban-sensing/venv/bin/urban-wifi-capture self-test
```

`validate` checks strict JSON types, interface-selection mode, channels,
the `/var/lib/urban-sensing` path boundary, and key length/type/ownership/mode
and symlinks. Missing, short, long, encoded, newline-terminated, hardlinked,
symlinked, or unsafely permissioned keys fail closed before an interface opens.
`interfaces plan` performs the fail-closed runtime selection and prints the
proposed mapping without changing an interface. Use `interfaces status` only
after preparation to report whether each planned monitor interface is present.
The self-test opens no network interface, uses only an explicit non-secret test
key and a temporary generated key, and writes only a temporary synthetic row.

This collector does not perform public-handoff re-pseudonymization. If an
approved public handoff replaces internal HMAC pseudonyms with
release-specific keyed pseudonyms, that is a separate downstream one-to-one
transformation. Keeping one replacement per identifier preserves Location,
Count, Track, Revisits, and Activities within that release; assigning a fresh
value per row would destroy those metrics.

## Controlled hardware test and collection

Complete [docs/HARDWARE_TEST.md](docs/HARDWARE_TEST.md) before field use. Once
the approved preflight passes:

```bash
sudo systemctl enable --now urban-wifi-interfaces.service
sudo systemctl enable --now urban-wifi-capture.service
sudo systemctl status --no-pager urban-wifi-capture.service
```

Stop the capture before transfer, upgrade, or the end of each deployment
session:

```bash
sudo systemctl stop urban-wifi-capture.service
sudo systemctl stop urban-wifi-interfaces.service
```

One SQLite file is created per service run, matching the earlier `start.py`
session-file behavior. The reference collector does not claim automatic
calendar-day rotation. For multi-day work, define approved daily sessions,
stop and verify each file, check free disk space, and transfer it before the
next session. A restart-rate limit prevents a bad adapter from creating files
indefinitely, but this is not a retention or capacity policy.

Never run the `capture` subcommand directly with `sudo`; root capture is
rejected. Never copy a database while the service is running. The hardware
check includes the WAL checkpoint, schema, loss counters, and permission checks
required before an approved transfer.

## Development checks

Desktop tests require the package and `dpkt`, but not capture hardware or root:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --require-hashes -r requirements-build.txt
python -m pip install --require-hashes -r requirements-unit.txt
python -m pip install --no-deps --no-build-isolation .
python -m unittest discover -s tests -v
python code/start.py self-test
```

Linux CI additionally compiles and imports `pcapy-ng`, runs ShellCheck,
verifies both systemd units, audits dependencies, scans for secrets, and builds
the deterministic text-only reviewer archive. None of those checks replaces
the two-minute Pi/adapter test.

## License

Repository code is MIT-licensed. Dependencies retain their upstream licenses;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
