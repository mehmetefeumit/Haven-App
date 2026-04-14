# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately by emailing the maintainers. Do not open a public issue.

## Known Vulnerabilities

None currently tracked. New advisories are surfaced by the weekly
`cargo audit` CI job; document them here as they appear.

## Network Threat Model

Haven does not implement network-level anonymity. Relay connections originate
from the user's real IP address, which a relay operator can correlate with
the pubkeys it sees publishing events. Users who require IP-level unlinkability
should run Haven behind a VPN.

## Security Architecture

### Database Encryption

Haven uses SQLCipher (encrypted SQLite) for all persistent databases. Encryption keys are stored in the system keyring:

- **macOS**: Keychain
- **Linux**: GNOME Keyring / KDE Wallet / Secret Service
- **Windows**: Credential Manager

| Database | Purpose | Service ID | Key ID |
|----------|---------|------------|--------|
| `haven_mdk.db` | MLS group state (via MDK) | `com.haven.app` | `mdk.db.key.default` |
| `circles.db` | Circle metadata, contacts, memberships | `com.haven.app` | `circles.db.key` |

Both databases use 256-bit AES encryption with raw keys generated from `OsRng`.
Existing unencrypted `circles.db` files are automatically migrated to encrypted
storage on first access via SQLCipher's `sqlcipher_export()` function.

**Linux requirement**: A D-Bus Secret Service provider must be running
(GNOME Keyring, KDE Wallet, or KeePassXC). Without one, circle
operations will be disabled with a descriptive error.

### Test-Utils Feature

The `test-utils` feature enables unencrypted storage for testing purposes. This feature:

- Is gated with `#[cfg(any(test, feature = "test-utils"))]`
- Produces a compile error if enabled in release builds
- Should NEVER be enabled in production

### MLS Security

Haven implements the Marmot Protocol for MLS over Nostr. Key security properties:

1. **Key Separation**: MLS signing keys are separate from Nostr identity keys
2. **Ephemeral Keys**: Each group message uses a new keypair
3. **Forward Secrecy**: Provided by MLS epoch rotation
4. **Memory Safety**: Secrets use `Zeroizing<T>` for automatic memory clearing

## Dependency Auditing

Run security audits regularly:

```bash
# Install cargo-audit
cargo install cargo-audit

# Run audit
cargo audit

# Check for outdated dependencies
cargo outdated
```
