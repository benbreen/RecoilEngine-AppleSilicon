# Security policy

## Reporting a vulnerability

If you find a security problem in **this port** (the engine build, the
launcher, the packaging, or the build pipeline), please use GitHub's
[private vulnerability reporting](../../security/advisories/new) on this
repository rather than a public issue. Best-effort response — this is an
unofficial community project, not a company.

If you believe **game content** (anything downloaded from BAR's content
network) is malicious, report it to the
[Beyond All Reason project](https://github.com/beyond-all-reason/Beyond-All-Reason)
— they control that content; this project does not host, vet, or modify it.

## What this project ships

Only what is in this repository: the engine binaries built from this source,
the bundled driver stack built from pinned upstream Mesa plus the committed
patches, and the launcher. Every release is Developer ID signed and notarized
by Apple, with SHA-256 checksums published alongside. **Download only from
this repository's Releases page and verify the checksums** — no other
distribution channel is ours.
