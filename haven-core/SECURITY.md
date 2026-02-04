# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately by emailing the maintainers. Do not open a public issue.

## Known Vulnerabilities

### ring 0.16.20 in Tor Dependency Chain

**Status**: Acknowledged, awaiting upstream fix
**Severity**: High
**CVEs**: RUSTSEC-2025-0009, RUSTSEC-2025-0010

#### Description

The `ring` cryptographic library version 0.16.20 has two known vulnerabilities:

1. **RUSTSEC-2025-0009 (AES Panic)**: AES functions may panic when overflow checking is enabled, potentially causing denial of service.

2. **RUSTSEC-2025-0010 (Unmaintained)**: Versions prior to 0.17 no longer receive security updates.

#### Affected Components

This vulnerability exists in the Tor integration dependency chain:

```
nostr-sdk 0.44.1
  └── nostr-relay-pool 0.44.0
      └── async-wsocket 0.13.1
          └── arti-client 0.28.0
              └── tor-rtcompat 0.28.0
                  └── x509-signature 0.5.0
                      └── ring 0.16.20 (VULNERABLE)
```

#### Impact

- **Scope**: Only affects code paths using Tor for relay connections
- **Risk**: Potential panic in AES operations during Tor circuit establishment
- **Data at Risk**: None - this is a denial of service issue, not data exposure

#### Mitigation

1. **Current**: The vulnerability only affects the Tor code path. Direct relay connections (without Tor) use a separate, patched `ring 0.17.x`.

2. **Planned**: Monitor upstream projects for updates:
   - `async-wsocket` needs to update to newer `arti-client`
   - `arti-client` 0.39+ uses patched `ring` versions

3. **Timeline**: Dependent on upstream releases. Check monthly for updates.

#### Verification

To check if the vulnerability is resolved after updating dependencies:

```bash
cargo audit
cargo tree -i ring@0.16.20  # Should return "not found" when fixed
```

## Security Architecture

### Database Encryption

Haven uses SQLCipher (encrypted SQLite) for storing sensitive MLS state. The encryption key is stored in the system keyring:

- **macOS**: Keychain
- **Linux**: GNOME Keyring / KDE Wallet / Secret Service
- **Windows**: Credential Manager

Service identifier: `haven`
Key identifier: `haven-mls-db`

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
