# AGENTS.md

Current App Store train: `1.0` (`6`) for macOS and iOS/iPadOS.

Read task-relevant guidance: `README.md` for the overview; `RUNBOOK.md` for build/release work; `docs/domain-contract.md` for shared Swift/Python behavior; `pyproject.toml` for Python packaging; the Xcode project for target membership; `.github/workflows/` only for CI changes.

## Repo map

- `TeslaCam/` - SwiftUI app for macOS + iOS/iPadOS (shared engine), native export, playback, telemetry, and resources. Mobile UI: `docs/architecture-deepening/07-ios-ipados-app.md`.
- `TeslaCamTests/`, `TeslaCamUITests/` - native test targets.
- `teslacam_cli/` - dependency-light Python CLI package.
- `tests/` - Python `unittest` suite.
- `fixtures/domain/cases/` - shared Swift/Python domain fixtures.
- `script/` - local build, test, fixture, and hook helpers.
- `tools/` - local utilities.
- `docs/releases/` - current App Store metadata and ASC handoff.
- `_legacy/` - reference only.

## Commands

- Setup CLI package when needed: `python3 -m pip install -e .`
- Primary CLI: `./teslacam-cli`
- CLI adapters: `python3 teslacam.py`, `./teslacam.sh`
- Full Python tests: `python3 -m unittest discover tests`
- Focused Python tests: `python3 -m unittest tests.test_domain_contract`
- Native macOS lane: `script/test_native.sh`
- Build and run app: `script/build_and_run.sh`
- Regenerate domain fixtures: `python3 script/regen_fixtures.py`
- Whitespace check: `git diff --check`

No dedicated lint, format, or Python typecheck config is present. Do not invent
one. Use `git diff --check` and the focused tests for the affected boundary. Run the full Python or native lane when the change warrants it.

Native commands require either `TESLACAM_BUILD_ENV` or
`/Users/bolyki/dev/source/build-env.sh`. If neither exists, report that setup
blocker instead of trying ad hoc `xcodebuild` commands.

Rules:

- Keep the macOS app and Python CLI docs aligned.
- Treat generated exports, build output, and work directories as derived.
- Use `/Users/bolyki/dev/source/build-env.sh` before native Swift builds, or point `TESLACAM_BUILD_ENV` at a compatible local override.
- Leave `TeslaCam/Resources/LICENSES.md` and other vendor or runtime assets alone unless the task is about licensing or packaging.
- Native export is the shipping app path. Do not reintroduce a CLI-only export assumption into the mac app.
- The iOS/iPadOS UI binds only to existing `AppState` API (no core edits). Register new Swift files in `project.pbxproj` for BOTH the `TeslaCam` (mac) and `TeslaCam iPad` targets, or they will not compile. Keep the manual codec picker and engrave-telemetry toggle. See `docs/architecture-deepening/07-ios-ipados-app.md`.
- `_legacy/` stays reference-only unless the task explicitly targets it.
- `teslacam_legacy_macos.sh` is reference only.
- Keep CLI planning pure; rendering and human output stay behind adapters.
- Keep domain behavior aligned across `docs/domain-contract.md`, fixtures, Python, and Swift tests.
- Keep current release/ASC facts in `docs/releases/`; do not create one-off handoff notes.
- Do not use `--break-system-packages`; prefer a virtual environment or repo-local cache.
- Preserve dirty worktree changes you did not make.

## Telemetry

- Do not add Sentry or external crash telemetry. Keep diagnostics local unless a repo runbook says otherwise.

## Done when

- You inspected current repo state and relevant docs/scripts before editing.
- Commands used in your answer are present in this repo or its CI/scripts.
- App/CLI behavior stays unchanged unless the task explicitly asks otherwise.
- Shared behavior changes update the domain contract, fixtures, and both test surfaces.
- Relevant verification ran, or the exact blocker is listed.
- Generated files, build output, vendor assets, and `_legacy/` stay untouched unless in scope.

Local disposable tests may be run and repaired within the requested task without repeated approval. Keep release, signing, production access and existing owner holds under their documented authority.

## Working guidance — GPT-6 Astra

Based on [OpenAI's Astra prompting guidance](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices), reviewed 2026-09-19. These are working instructions, not a change to model or API settings.

- Complete the authorized task through implementation and relevant verification. Make routine choices yourself; ask only when a missing decision materially changes the result or requires new authority. Prepare reviewable work before requesting any necessary final approval.
- Current user instructions take precedence over repository and skill guidance within system and tool constraints. Preserve explicit exclusions and owner holds. Historical plans and session notes do not grant current authorization. If a file or skill blocks progress, identify its exact path and rule.
- Keep changes small and practical. Inspect current source and Git status, preserve unrelated work, and use existing conventions. Do not add speculative abstractions, dependencies, or unrelated cleanup. Commit, push, deploy, install, and live-service changes require authorization for that action.
- Use the reasoning effort the task needs. Follow explicit project delegation rules; otherwise use subagents only when requested, with bounded independent tasks and distinct file ownership. Batch independent reads; serialize dependent operations and conflicting edits.
- Run meaningful checks for the changed behavior and required project gates. Avoid tests that merely repeat low-impact edits. Broaden or repeat verification only after changes, failures, or unresolved concerns. Distinguish local checks from device, browser, and live-service evidence.
- Write concise, plain, outcome-first updates. State what changed, why, verification, and material gaps. Avoid filler and unnecessary formatting.
- Keep durable instructions in AGENTS.md and maintained product documentation. Do not create duplicate assistant instruction files or disposable plans, transcripts, status reports, and screenshots in source directories unless requested. Preserve source, tests, fixtures, assets, licences, and operational evidence regardless of who created them.
