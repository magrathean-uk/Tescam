# Contributing

Tescam is proprietary. Public source visibility does not grant permission to clone, modify or redistribute it. Read [LICENSE](LICENSE) before working with the repository. For permission or licensing enquiries, use [contact@magrathean.uk](mailto:contact@magrathean.uk).

## Reports and suggestions

Use [SUPPORT.md](SUPPORT.md) for product questions and ordinary bug reports. Send security findings through [SECURITY.md](SECURITY.md). Do not include private footage, location data, credentials or unredacted logs in public reports.

## Authorised development

Keep changes focused and preserve unrelated work. Explain the problem, the resulting behaviour and the checks that support it. Include any remaining device or user-flow validation gap.

Follow [RUNBOOK.md](RUNBOOK.md) for setup and validation. Shared app/CLI behaviour changes need matching updates to [the domain contract](docs/domain-contract.md), shared fixtures and both test surfaces. The app exports natively; the CLI uses FFmpeg. Keep that distinction in code and documentation.

For mobile UI work, use the existing `AppState` API, register new Swift files in both app targets and preserve the codec picker and telemetry toggle. Details are in [the iOS/iPadOS guide](docs/architecture-deepening/07-ios-ipados-app.md).

Do not commit recordings, exports, build output, credentials or signing material. Preserve third-party notices and record the source and licence of any proposed dependency or asset. An accepted technical change does not itself establish permission to redistribute third-party material.

Keep current release facts under `docs/releases/`. Builds and tests do not authorise signing, uploading or publishing. Agent-specific instructions are in [AGENTS.md](AGENTS.md).
