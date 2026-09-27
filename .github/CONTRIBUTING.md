# Contributing

Tescam is free software under the GNU General Public License, version 3 only ([LICENSE](../LICENSE)). Pull requests are welcome on the terms below. Questions: [contact@magrathean.uk](mailto:contact@magrathean.uk).

## Reports and suggestions

Use [SUPPORT.md](SUPPORT.md) for product questions and ordinary bug reports. Send security findings through [SECURITY.md](SECURITY.md). Do not include private footage, location data, credentials or unredacted logs in public reports.

## Making a change

Keep changes focused and preserve unrelated work. Explain the problem, the resulting behaviour and the checks that support it. Include any remaining device or user-flow validation gap.

Follow [the runbook](../docs/development/runbook.md) for setup and validation. Shared app/CLI behaviour changes need matching updates to [the domain contract](../docs/architecture/domain-contract.md), shared fixtures and both test surfaces. The app exports natively; the CLI uses FFmpeg. Keep that distinction in code and documentation.

For mobile UI work, use the existing `AppState` API, register new Swift files in both app targets and preserve the codec picker and telemetry toggle. Details are in [the iOS/iPadOS guide](../docs/architecture/ios-ipados-app.md).

Do not commit recordings, exports, build output, credentials or signing material. Preserve third-party notices and record the source and licence of any proposed dependency or asset. Do not add material whose licence is incompatible with GPL-3.0-only.

Keep current release facts under `docs/development/`. Builds and tests do not authorise signing, uploading or publishing. Agent-specific instructions are in [AGENTS.md](../AGENTS.md).

## Licensing of contributions

MAGRATHEAN UK LTD ("Magrathean") also distributes Tescam through the Apple App Store, whose
terms are not compatible with the GPL. So that accepted contributions can ship in that build,
by submitting a contribution you:

1. license it under GPL-3.0-only, the licence of this repository;
2. also grant Magrathean a perpetual, worldwide, non-exclusive, royalty-free and irrevocable
   licence to use, modify and distribute your contribution as part of Tescam under other
   terms, including those of app stores; and
3. confirm that the contribution is your own work, or that you otherwise have the right to
   grant these licences.

Sign off every commit (`git commit -s`). You keep the copyright in your contribution.
