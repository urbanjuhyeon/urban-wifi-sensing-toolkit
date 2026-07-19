# Public-handoff candidate build

Candidate: `historical-v4-public-candidate-1`

This isolated candidate replaces each internal historical pseudonym with a 32-character release- and dataset-specific keyed pseudonym. Identical internal pseudonyms remain identical within one released dataset. The two datasets use separate keys and contexts.

No key, key fingerprint, identifier mapping, packet-level record, or one-second source is included in this directory. The transformation does not claim that the 2019 or 2020 collectors used HMAC at capture.

These records remain pseudonymous rather than anonymous because each identifier is intentionally consistent within its dataset. Building this candidate is not authorization for open release; access and disclosure review remain separate release gates.

Run `verify_public_release_candidate.R` with the same private key files before any handoff.
