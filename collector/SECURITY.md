# Security and privacy

## Deployment boundary

Passive WiFi sensing can create pseudonymous longitudinal records. A truncated
HMAC token is not anonymization and does not remove the need for ethics review,
lawful authority, data minimization, access control, retention limits, and
appropriate public notice. Do not deploy this software until those requirements
have been approved for the site and jurisdiction.

The reference collector stores only the fields documented in `README.md`. It
has no command-line option for raw frames, raw MAC addresses, SSIDs, BSSIDs,
destination addresses, Bluetooth discovery, cloud upload, or a remotely
writable file share. Do not add any such feature to a public-space deployment
without a separate threat assessment and explicit approval.

## Host controls

- Keep code and configuration root-owned and non-writable by the service user.
- Generate a deployment key exactly once with the supplied CSPRNG command. Keep
  the installed copy root:`urban-sensing` mode `0640`; never inline it in JSON,
  pass it on a command line, or independently generate one per sensor.
- Treat every SD copy and approved backup as a secret for the entire
  deployment. Do not log, hash for publication, commit, screenshot, or include
  a key in a reviewer snapshot. Rotate both key and opaque deployment ID for a
  later campaign, including a return to the same site.
- If a key is missing, malformed, symlinked, hardlinked, replaced, or exposed,
  stop collection and follow the approved incident/retention plan. Do not
  silently substitute a new key during an active campaign because that breaks
  within-deployment linkage.
- Keep `/var/lib/urban-sensing` mode `0700`; SQLite files are created mode
  `0600`.
- Do not expose the state directory through Samba, Dropbox, or another sync
  service.
- Use the supplied split systemd units: interface preparation is a short root
  task; continuous packet capture runs as the unprivileged `urban-sensing`
  account with only `CAP_NET_RAW`.
- Transfer data through an access-controlled, temporary process and remove the
  sensor copy according to the approved retention schedule.
- Treat the SQLite files as restricted intermediate research data. The public
  reproducibility handoff is the downstream 20-second dataset, not these files.

The service reads the key once before creating the run database or opening a
capture interface. Worker processes receive only the in-memory bytes needed for
HMAC; the writer receives only the non-secret deployment ID and scheme
metadata. Core dumps are disabled and `/etc` is read-only inside the hardened
service, but those controls do not make physical theft of an SD card harmless.

## Reporting a vulnerability

Do not open a public issue containing credentials, identifiable network names,
raw addresses, packet data, or participant information. Contact the repository
maintainer privately and include only the minimum information needed to
reproduce the problem.
