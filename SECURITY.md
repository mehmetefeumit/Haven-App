# Security Policy

## Reporting a vulnerability

Report it privately through GitHub: the repository's **Security** tab →
**Report a vulnerability**. Please do not open a public issue, pull request or
discussion for it. The form exists only once the owner has enabled private
vulnerability reporting for the repository; if you cannot see it, open a public
issue that asks for a private contact and contains no detail of the problem.

Useful in a report: the affected version or commit, what an attacker needs
(a relay, a circle member, a crafted event, local access), and the steps or
proof that show the impact.

## Supported versions

Only the latest release receives fixes. Haven is pre-1.0 beta software and has
not had a third-party security audit (see the README).

## Verifying what you install

- **Android:** every release APK is signed by one key. Its certificate's SHA-256
  is published in the README under "Signing Certificate SHA-256", and the
  release pipeline refuses to sign with any other key. Compare it with
  `apksigner verify --print-certs <apk>`. Each APK on the Releases page has a
  `<apk>.sha256` sidecar for checking the download itself.
- **GitHub Release notes** list every known advisory the release ships
  acknowledged, with the date each acknowledgement expires.

## Threat model and dependency policy

[`haven-core/SECURITY.md`](haven-core/SECURITY.md) holds the threat model, the
security architecture, the known and resolved advisories, what is and is not
scanned for vulnerable dependencies, and the repository settings the owner is
responsible for.
