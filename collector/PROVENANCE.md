# Provenance and scope

This reference implementation was published after the 2019 and 2020
deployments described in the companion urban WiFi sensing study. Earlier
`start.py`-style code is consistent with the collection approach and may have
informed the field setup, but no byte-for-byte field-device image is available
in this release. The maintained code must therefore be described as a
**reference implementation**, not as the exact historical executable.

The repository history preserves the earlier public implementation. Those
earlier commits are retained for provenance only and should not be deployed:
they permitted optional raw-frame storage, retained SSID/destination/AP fields,
used full 64-character SHA-256 output, relied on writable `/home/pi` paths, and
ran a long-lived service as root. Historical timestamps were local wall-clock
text without a UTC offset, whereas the maintained reference writes explicit
UTC `Z` timestamps. Neither convention should be silently attributed to the
other.

Version 1.0 established the first maintained-reference contract. It used an
unkeyed 16-hex SHA-256 prefix after canonicalizing the MAC. That retired format
is documented only to make migration and interpretation explicit; version 1.1
does not write it and never relabels a version 1 database as version 2.

Version 1.1 establishes the current schema-version-2 contract:

- classify the locally administered bit from the six source-address bytes;
- reject invalid, broadcast, and group source addresses;
- normalize the address as lowercase colon-separated text;
- apply the domain-separated `hmac-sha256-128-v1` scheme with an exact 32-byte
  CSPRNG key and an opaque deployment ID;
- store the first 128 HMAC bits as 32 lowercase hexadecimal characters;
- retain the pre-HMAC randomization flag;
- use the same key and deployment ID across sensors only for one approved
  campaign, then rotate both for the next campaign;
- record scheme, scope, and non-secret deployment ID in SQLite metadata but no
  key, key path, fingerprint, or comparison token;
- store no raw address, packet frame, SSID, BSSID, or destination address; and
- write UTC RFC 3339 timestamps and the minimum SQLite fields required by the
  documented aggregation pipeline.

Version 1.0 also made one substantive frame-semantics correction, which version
1.1 retains. For data frames, radiotap RSSI belongs to the over-the-air
transmitter at address 2.
Earlier code could use dpkt's logical `data_frame.src` for FromDS traffic and
therefore pair an address-3 source with an AP transmitter's RSSI. The maintained
reference keeps only direct/IBSS and client-originated ToDS data frames, for
which the stored source is the radio transmitter; it excludes FromDS and WDS
traffic. This correction is not evidence that historical results were
recomputed with the new rule.

Like the earlier `start.py`, the maintained collector creates one database per
service run. It does not claim automatic UTC-calendar-day rotation. Deployment
documentation defines bounded daily sessions when day-level files are needed.

This implementation does not change how historical field data were collected.
There is no evidence that the 2019 or 2020 field images used deployment-scoped
HMAC, and no raw-address recovery step exists to convert their identifiers to
the current scheme. Claims about the reference implementation and released
data must not be rewritten as claims about every historical capture image.
