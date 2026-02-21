# Security Policy

We take security seriously. We appreciate your efforts to responsibly disclose vulnerabilities and will make every effort to acknowledge your contributions.

## Table of Contents

- [Reporting a Vulnerability](#reporting-a-vulnerability)
- [What to Include](#what-to-include)
- [Response Timeline](#response-timeline)
- [Disclosure Policy](#disclosure-policy)
- [Scope](#scope)
- [Safe Harbour](#safe-harbour)
- [Recognition](#recognition)
- [Security Updates](#security-updates)
- [Security Best Practices](#security-best-practices)

---

## Reporting a Vulnerability

### Preferred Method: GitHub Security Advisories

The preferred method for reporting security vulnerabilities is through GitHub's Security Advisory feature:

1. Navigate to [Report a Vulnerability](https://github.com/hyperpolymath/docudactyl/security/advisories/new)
2. Click **"Report a vulnerability"**
3. Complete the form with as much detail as possible
4. Submit — we'll receive a private notification

This method ensures:

- End-to-end encryption of your report
- Private discussion space for collaboration
- Coordinated disclosure tooling
- Automatic credit when the advisory is published

### Alternative: Email

If you cannot use GitHub Security Advisories, you may email us directly:

| | |
|---|---|
| **Email** | jonathan.jewell@open.ac.uk |

> **Important:** Do not report security vulnerabilities through public GitHub issues, pull requests, discussions, or social media.

---

## What to Include

A good vulnerability report helps us understand and reproduce the issue quickly.

### Required Information

- **Description**: Clear explanation of the vulnerability
- **Impact**: What an attacker could achieve (confidentiality, integrity, availability)
- **Affected versions**: Which versions/commits are affected
- **Reproduction steps**: Detailed steps to reproduce the issue

### Helpful Additional Information

- **Proof of concept**: Code, scripts, or screenshots demonstrating the vulnerability
- **Attack scenario**: Realistic attack scenario showing exploitability
- **CVSS score**: Your assessment of severity (use [CVSS 3.1 Calculator](https://www.first.org/cvss/calculator/3.1))
- **CWE ID**: Common Weakness Enumeration identifier if known
- **Suggested fix**: If you have ideas for remediation
- **References**: Links to related vulnerabilities, research, or advisories

---

## Response Timeline

We commit to the following response times:

| Stage | Timeframe | Description |
|-------|-----------|-------------|
| **Initial Response** | 48 hours | We acknowledge receipt and confirm we're investigating |
| **Triage** | 7 days | We assess severity, confirm the vulnerability, and estimate timeline |
| **Status Update** | Every 7 days | Regular updates on remediation progress |
| **Resolution** | 90 days | Target for fix development and release (complex issues may take longer) |
| **Disclosure** | 90 days | Public disclosure after fix is available (coordinated with you) |

> **Note:** These are targets, not guarantees. Complex vulnerabilities may require more time. We'll communicate openly about any delays.

---

## Disclosure Policy

We follow **coordinated disclosure** (also known as responsible disclosure):

1. **You report** the vulnerability privately
2. **We acknowledge** and begin investigation
3. **We develop** a fix and prepare a release
4. **We coordinate** disclosure timing with you
5. **We publish** security advisory and fix simultaneously
6. **You may publish** your research after disclosure

### Our Commitments

- We will not take legal action against researchers who follow this policy
- We will work with you to understand and resolve the issue
- We will credit you in the security advisory (unless you prefer anonymity)
- We will notify you before public disclosure
- We will publish advisories with sufficient detail for users to assess risk

### Your Commitments

- Report vulnerabilities promptly after discovery
- Give us reasonable time to address the issue before disclosure
- Do not access, modify, or delete data beyond what's necessary to demonstrate the vulnerability
- Do not degrade service availability (no DoS testing on production)
- Do not share vulnerability details with others until coordinated disclosure

---

## Scope

### In Scope

The following are within scope for security research:

- This repository (`hyperpolymath/docudactyl`) and all its code
- The Zig FFI layer (`ffi/zig/`) — memory safety, buffer handling, null-pointer dereferences
- The C ABI boundary — struct layout correctness, pointer handling
- Chapel HPC orchestration — fault isolation, input validation
- Container images built from `deploy/Containerfile`
- Official releases and packages published from this repository
- Dependencies (report here, we'll coordinate with upstream)

### Out of Scope

The following are **not** in scope:

- Third-party C libraries (Poppler, Tesseract, FFmpeg, etc.) — report directly to them
- Social engineering attacks against maintainers
- Physical security
- Denial of service attacks against production infrastructure
- Issues already reported or publicly known
- Theoretical vulnerabilities without proof of concept

### Qualifying Vulnerabilities

We're particularly interested in:

- Memory safety issues in the Zig FFI layer (buffer overflows, use-after-free, etc.)
- ABI mismatches between Idris2 proofs and actual struct layouts
- Command injection via manifest file paths or configuration
- Unsafe dlopen/dlsym handling (ONNX Runtime, PaddleOCR, CUDA)
- Path traversal in document output paths
- Information disclosure through error messages
- Cryptographic weaknesses in SHA-256 hardware acceleration paths

---

## Safe Harbour

We support security research conducted in good faith.

### Our Promise

If you conduct security research in accordance with this policy:

- We will not initiate legal action against you
- We will not report your activity to law enforcement
- We will work with you in good faith to resolve issues
- We consider your research authorised under the Computer Fraud and Abuse Act (CFAA), UK Computer Misuse Act, and similar laws
- We waive any potential claim against you for circumvention of security controls

### Good Faith Requirements

To qualify for safe harbour, you must:

- Comply with this security policy
- Report vulnerabilities promptly
- Avoid privacy violations (do not access others' data)
- Avoid service degradation (no destructive testing)
- Not exploit vulnerabilities beyond proof-of-concept

---

## Recognition

Researchers who report valid vulnerabilities will be acknowledged in our security advisories (unless they prefer anonymity).

---

## Security Updates

### Receiving Updates

To stay informed about security updates:

- **Watch this repository**: Click "Watch" -> "Custom" -> Select "Security alerts"
- **GitHub Security Advisories**: Published at [Security Advisories](https://github.com/hyperpolymath/docudactyl/security/advisories)

### Supported Versions

| Version | Supported | Notes |
|---------|-----------|-------|
| `main` branch | Yes | Latest development |
| Latest release | Yes | Current stable |
| Older versions | No | Please upgrade |

---

## Security Best Practices

When using Docudactyl, we recommend:

### General

- Keep dependencies up to date
- Use the latest stable release
- Validate manifest files before processing untrusted inputs
- Run in containers with minimal privileges
- Review Slurm job scripts before submission

### For Contributors

- Never commit secrets, credentials, or API keys
- No `@panic` in Zig release builds — return error codes via C ABI
- No `believe_me`, `assert_total`, or `Admitted` in Idris2 proofs
- No `unsafe` blocks in Zig without documented safety justification
- Review dependencies before adding them
- Run `just test-hpc` before pushing

---

## Contact

| Purpose | Contact |
|---------|---------|
| **Security issues** | [Report via GitHub](https://github.com/hyperpolymath/docudactyl/security/advisories/new) or jonathan.jewell@open.ac.uk |
| **General questions** | [GitHub Issues](https://github.com/hyperpolymath/docudactyl/issues) |

---

*Thank you for helping keep Docudactyl and its users safe.*

---

<sub>Last updated: 2026 | Policy version: 1.0.0</sub>
