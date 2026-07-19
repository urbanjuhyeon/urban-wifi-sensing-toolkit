# Privacy contract

## Purpose limitation

The collector exists to produce aggregate urban pedestrian measures. It is not
an identity, advertising, network-security, or device-fingerprinting tool. The
software deliberately does not attempt to defeat MAC address randomization or
link a randomized address to another identifier.

## Processing boundary

Before capture, the parent process loads one exact 32-byte key from the
configured private regular file. The key is loaded once so every interface in
the process uses the same immutable bytes. It is never accepted as a command
line value, printed, logged, put on the record queue, written to SQLite, or
included in the reviewer snapshot.

Within the libpcap callback, the collector reads the source address only long
enough to:

1. validate that it is a six-octet unicast source;
2. read the locally administered bit;
3. format it as lowercase colon-separated text; and
4. compute the `hmac-sha256-128-v1` deployment token and retain its first 128
   bits as 32 lowercase hexadecimal characters.

The HMAC input is domain-separated by scheme/version and includes the exact
opaque deployment ID plus canonical MAC. It does not include sensor, time,
channel, or session. Only the resulting token, the pre-HMAC flag, UTC timestamp,
frame class, RSSI, configured channel, and sensor name enter the interprocess
queue. The raw frame object is then discarded. Database `CHECK` constraints
independently enforce the identifier and flag formats.

## Within- and between-deployment continuity

All sensors in one approved deployment use the same deployment ID and the same
key. The same observed MAC therefore receives the same pseudonym across sensors
and restarts during that deployment. That within-deployment equality is
required for Location, Count, Track, Revisits, and Activities. A later
deployment uses a new random key and a new opaque ID, so even the same observed
MAC at the same place receives a different pseudonym. Keys must not be reused
merely because the place is the same.

This boundary does not solve MAC randomization and does not erase distinctive
space-time patterns. A key compromise exposes the pseudonymization boundary for
that deployment, so every SD copy is restricted and keys follow an approved
creation, distribution, backup, retention, and destruction schedule.

## Interpretation

The HMAC token is a pseudonymous device identifier, not a person identifier and not
anonymous data. A device can emit more than one address, an address can change,
and a device is not necessarily carried by one person. Downstream reports must
use aggregate language and retain these measurement limitations.

## Release boundary

Local SQLite files are restricted intermediate data. They must not be included
in Git, documentation, screenshots, examples, Figshare, or another public
archive. The public research handoff is the downstream 20-second dataset after
approved filtering, aggregation, and disclosure-risk review.

Public-handoff re-pseudonymization is not part of sensor collection or metric
computation. An approved release process may replace each internal HMAC
pseudonym with one release-specific keyed pseudonym as an additional separation
layer. The replacement must be one-to-one within the release if all five
metrics are to remain computable. A public pseudonym does not make a distinctive
trajectory anonymous, and the release key, any mapping, and the internal IDs
must remain restricted.

The 2019 and 2020 historical deployments predate this maintained HMAC scheme.
Nothing in this contract claims that their collectors used deployment keys or
that historical identifiers can be retroactively converted to this scheme.
