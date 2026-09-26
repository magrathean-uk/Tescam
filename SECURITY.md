# Security Policy

## Reporting a vulnerability

Send a report to `contact@magrathean.uk` with the subject `SECURITY: Tescam`. Do not publish credentials, private keys, database dumps, signing certificates, personal recordings, or exploit details.

Include the affected version or commit, platform, reproduction steps, impact, and redacted evidence. This policy does not state a response-time commitment.

## System and scope

This policy covers the native macOS, iPhone, and iPad app, the Python CLI, and repository-maintained build and release support. Relevant findings include unauthorized access to selected files, exposure of recordings or parsed telemetry, unsafe handling of malformed media or telemetry, unintended disclosure through logs or exports, and an unexpected external communication or telemetry path.

The app processes user-selected TeslaCam recordings. On macOS it uses security-scoped bookmarks to restore selected folders. The privacy manifest declares no tracking and no collected data types. It declares use of UserDefaults, file timestamps, disk space, and boot-time APIs. iPad exports are written to app temporary storage before a user chooses a share destination.

Telemetry may include location and vehicle data. Telemetry engraving is off by default, and exports or shares can still disclose data that the user elects to include.

## Security properties

- Access to recordings and export destinations must remain limited to user-authorized paths and platform sandbox permissions.
- Corrupt or malformed input must not cause an unsafe file operation or disclose data.
- Diagnostics must remain local and redact user-controlled message content in system logs.
- The shipping app must not add Sentry, analytics, or external crash telemetry.
- A change to external network behavior, privacy declarations, entitlement scope, export sharing, or persisted bookmark handling requires focused review.

## Scope & Safe Harbour

Magrathean UK Ltd. will not pursue a good-faith researcher for security disclosures that:
- Target non-production test systems or researcher-owned environments;
- Avoid persistence, destructive changes, denial of service, and access to personal or customer data;
- Report promptly and permit reasonable time for remediation;
- Do not condition non-disclosure on financial compensation.

## Excluded Conduct

No safe harbour covers phishing, credential stuffing, accessing private production infrastructure, large-scale scanning, denial of service, or unlawful conduct.

## Limitations

This document describes repository policy, not a security audit or a guarantee about user-provided recordings, operating-system services, or destinations chosen through a share sheet. User handling of recordings remains subject to the terms in `LICENSE`.
