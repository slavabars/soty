# Security policy

[Русский](SECURITY.md) · **English**

This repository holds the project description, the relay installers and the official release binaries. The app source is [soty-app](https://github.com/slavabars/soty-app) and the relay source is [soty-relay](https://github.com/slavabars/soty-relay).

**Please do not open a public issue for a security problem.**

## Reporting

Preferred: GitHub private vulnerability reporting: <https://github.com/slavabars/soty/security/advisories/new>

Alternative: email **security@soty.su**.

Include the affected version (`X.Y.Z+N`), platform, impact and reproduction steps. Never paste message content, keys or seeds.

## In scope

- the installers and deploy scripts (`scripts/`) doing something unsafe: downloading without a checksum, overwriting `host.db`, running as root unnecessarily, following a redirect to a non-GitHub host;
- a release artifact that does not match the published SHA-256;
- an official APK signed by an unexpected certificate;
- a compromised or spoofed release.

## Out of scope

- vulnerabilities in the app or relay code — report those in the matching repository;
- a relay you operate yourself being flooded;
- metadata a relay inherently sees.

## Response

Acknowledgement within 7 days, an assessment within 14, a fix and a release as soon as practical. Please allow time to ship before publishing details.
