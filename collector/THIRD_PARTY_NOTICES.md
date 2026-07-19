# Third-party notices

This repository's own code is MIT-licensed. Runtime dependencies retain their
own licenses:

| Dependency | Pinned version | Role | Upstream license |
|---|---:|---|---|
| `dpkt` | 1.9.8 | Radiotap and IEEE 802.11 parsing | BSD-3-Clause |
| `pcapy-ng` | 2.0.0 | Python bindings for libpcap | Apache-2.0 |

`pcapy-ng 2.0.0` is installed from its hash-pinned PyPI source distribution.
It is compiled locally rather than treated as a pre-verified binary. Publication
therefore requires the Linux 3.9/3.11 build-and-import CI jobs and the real-Pi
hardware checklist to pass; the version pin alone is not a compatibility or
provenance certification.

The operating-system packages `libpcap`, `iw`, and `iproute2` are installed by
the administrator under the licenses supplied by Raspberry Pi OS/Debian. They
are not copied into this repository.

Earlier public commits optionally invoked Bluelog and Dropbox-Uploader. Version
1.0 removes both integrations; neither program nor its source is distributed or
installed by the maintained collector.
