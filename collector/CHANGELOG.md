# Changelog

## 1.2.9 - 2026-07-15

- Keep SIGINT/SIGTERM handlers lock-free and relay the recorded signal from the
  main loop. This avoids deadlocking when a signal interrupts
  `multiprocessing.Event.wait()` during a systemd stop.

## 1.2.8 - 2026-07-15

- Put libpcap handles into non-blocking mode so quiet capture workers check the
  shared stop event promptly and systemd can complete a graceful stop without
  reaching `TimeoutStopSec`.

## 1.2.7 - 2026-07-15

- Add a read-only `interfaces plan` action that prints the automatically
  selected physical-to-monitor mapping without reporting uncreated monitor
  interfaces as `missing` during configuration.

## 1.2.6 - 2026-07-15

- Bring each new monitor interface up before setting its channel, matching the
  order required by the tested Raspberry Pi WiFi drivers and the earlier
  working `start.py` workflow.

## 1.2.5 - 2026-07-15

- Give the bounded root interface-preparation service the `urban-sensing`
  supplementary group so it can validate the root-managed deployment key
  without weakening the key's `0640` permissions.

## 1.2.4 - 2026-07-15

- Temporarily release automatically selected capture adapters from
  NetworkManager before monitor-mode conversion and return them afterward.
- Run only the bounded interface-preparation oneshot as root so it can use
  NetworkManager's system D-Bus; the long-running packet capture remains the
  unprivileged `urban-sensing` service.

## 1.2.3 - 2026-07-15

- Remove verified local setuptools build artifacts before and after packaging
  so extracting a new archive over an older source tree cannot reinstall stale
  Python modules under the new version number.

## 1.2.2 - 2026-07-15

- Improve monitor-setup rollback while preserving the separate monitor-
  interface workflow used by the earlier `start.py` implementation.

## 1.2.1 - 2026-07-15

- Repair virtual-environment console-script shebangs after the staged atomic
  install and ensure the unprivileged service account can traverse and read the
  root-owned runtime.

## 1.2.0 - 2026-07-15

Runtime-safe interface discovery:

- added automatic capture-adapter selection that excludes the single managed
  wireless interface carrying the default route;
- removed any need to persist Raspberry Pi vendor prefixes, adapter MAC
  addresses, or boot-dependent `wlan` numbers in the default configuration;
- added fail-closed adapter-count checks before any interface is changed;
- added deterministic logical capture-slot labels and delayed interface
  preparation until `network-online.target`; and
- retained the explicit static interface-list format for approved specialist
  deployments that require it.

## 1.1.0 - 2026-07-14

Deployment-scoped pseudonymization boundary:

- replaced the active unkeyed 16-hex SHA format with domain-separated
  `hmac-sha256-128-v1` 32-hex tokens;
- added required opaque `deployment_id` and private
  `pseudonymization_key_file` configuration fields;
- added a CSPRNG key generator and fail-closed exact-length, regular-file,
  hardlink, symlink, ownership, and POSIX-mode validation;
- loaded each key once before capture and kept sensor, time, channel, and
  session out of the HMAC input so within-deployment metrics remain stable;
- bumped SQLite to schema version 2 with dynamic scheme/scope/deployment
  metadata and no key, key path, fingerprint, or comparison token;
- refused old or cross-deployment databases before metadata mutation;
- updated provisioning, migration, hardware, privacy, snapshot, and test
  contracts while explicitly leaving 2019/2020 provenance unchanged.

## 1.0.0 - 2026-07-13

Security and reproducibility rewrite of the public reference collector:

- established the shared 16-character SHA-256 identifier contract;
- retained randomization classification computed before hashing;
- removed raw-frame, SSID, BSSID, destination-address, Bluetooth, Dropbox, and
  Samba-related collection paths;
- reduced SQLite to the eight allowlisted fields used by the aggregation
  documentation and added schema constraints, privacy metadata, and auditable
  per-interface receive/filter/drop summaries;
- corrected data-frame RSSI/source pairing by retaining direct/ToDS
  transmitter frames and excluding FromDS/WDS frames;
- committed partial SQLite batches by maximum age and made multi-process
  shutdown drain all producer queues before the writer exits;
- replaced root/`chmod 777` deployment with split, capability-bounded systemd
  services and private state permissions;
- added fail-closed migration, symlink/path/ownership checks, restart limiting,
  core-dump suppression, and a non-root runtime path boundary;
- removed hard-coded `/home/pi` and repository-name paths;
- pinned and hash-locked runtime and build dependencies;
- added strict configuration validation, hardware-independent tests, a
  synthetic radiotap fixture, CI, and a Raspberry Pi smoke-test checklist;
- added MIT licensing, third-party notices, privacy guidance, security
  guidance, and an explicit historical provenance boundary.
