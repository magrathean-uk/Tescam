# iOS / iPadOS App

Goal: ship a proper portrait-first iPhone + iPad app from the **same core** as the
macOS app, with a native touch UI, correct Dynamic Island / safe-area handling, and
the Teslatlas visual language: no changes to the shared engine.

Read first:
- `TeslaCam/ContentView.swift`: the whole cross-platform view tree.
- `TeslaCam/PortraitComponents.swift`: iOS-only Teslatlas-flavoured building blocks.
- `TeslaCam/Utils.swift`: `TeslaCamTheme` design tokens + `TeslaCamSceneBackground`.
- `TeslaCam/IPadMain.swift`: the iOS `@main` scene.
- `TeslaCam/Main.swift`: the macOS AppKit entry (unchanged).
- `TeslaCam/TeslaCam_iPad_Info.plist` + `TeslaCam.xcodeproj/project.pbxproj`: orientation.

## Shape

Two app targets, two entry points, one shared core:

- **macOS**: `Main.swift` (`NSApplication` + `AppDelegate`) → `ContentView` → `MacContentView`.
- **iOS / iPadOS**: `IPadMain.swift` (`@main struct TeslaCamIPadApp: App`) → `ContentView` → `IOSContentView`.
- Both share `AppState` and the engine (`Indexer`, `PlaybackController`, `NativeExportController`,
  `MetalRenderer`, `TelemetryProcessor`, `Models`). The iOS UI binds to the existing `AppState`
  surface only: it adds **no** core API.

`ContentView` stays thin and forks by `#if os(iOS)` / `#if os(macOS)`; the two platforms
share the engine, not the view tree.

## iOS layout: one adaptive workspace

`IOSContentView` routes: indexing → `IndexingScreen`, empty → `OnboardingScreen`, else the
single adaptive **`IOSWorkspace`**. `isWide = proxy.size.width > proxy.size.height` picks:

- **`compactBody` (portrait / narrow)**: a vertical `ScrollView`: page header → player card
  (aspect-sized) → transport → timeline scrubber → export range → cameras → export options.
  The **Export video** CTA is pinned above the home indicator via `.safeAreaInset(edge: .bottom)`.
- **`wideBody` (landscape / iPad)**: an `HStack`: a **filling player** on the left (all cameras,
  biggest possible) and a scrollable **control column** on the right (transport pinned at the top,
  sections below, Export CTA pinned at the base).

The old landscape-only dock (`IOSReviewWorkspace` / `IOSControlDock` / `IOSWorkspaceMetrics` /
`IOSClipSummaryBar` / `IOSClipDetailsSheet`) and the `IPadLandscapeLockScreen` "Rotate Device"
screen were **deleted**. Do not reintroduce a horizontally-scrolling control row: it pushed the
Export button off-screen and left dead space.

## Safe area / Dynamic Island

- `IOSContentView` is `GeometryReader { … }.background(TeslaCamSceneBackground())` with **no**
  `ignoresSafeArea` on the reader. `proxy.size` is therefore already the usable, island-free size;
  hand it straight to the workspace. The scene background bleeds under the Island via its **own**
  `ignoresSafeArea`.
- Do **not** put the bleeding background as a `ZStack` sibling: a `ZStack` containing an
  `ignoresSafeArea()` child grows to full-screen and drags any `maxWidth/maxHeight: .infinity`
  content edge-to-edge, under the Island. And do **not** put `ignoresSafeArea()` on the
  GeometryReader: it zeroes `proxy.safeAreaInsets`.
- `statusBarHidden` is landscape-only (`verticalSizeClass == .compact`); portrait keeps it so the
  system reserves the Island region.
- **Not done, on purpose:** reclaiming the mirrored landscape safe-area strip on the non-Island
  short edge. iOS mirrors the Island inset onto both short edges and does not expose which physical
  edge the Island is on, so any heuristic risks sliding content under it. Left as the OS-reserved
  margin.

## Design system

- `TeslaCamTheme` (Utils.swift) keeps TeslaCam's dark OLED identity and adds Teslatlas-parity tokens:
  accent nudged to `rgb(0.24,0.54,0.93)`, rounded metric type, 48pt CTA height, 560pt content column,
  a progress spectrum, and iOS corner radii (14/12/10).
- `PortraitComponents.swift` (iOS-only) ports the Teslatlas building blocks onto those tokens:
  `TeslaCamPageHeader`, `TeslaCamPillPicker`, `TeslaCamSectionCard`, `TeslaCamCTAButtonStyle`, and a
  Reduce-Motion-aware `teslaCamReveal` entrance. It is registered in `project.pbxproj` for **both**
  app targets: the project references sources explicitly, so a new `.swift` file will not compile
  until it is wired the way `Utils.swift` is.

## Preview grid

`PreviewPanelCard` always uses `previewLayoutMode = .grid`; the arrangement comes from
`CameraLayoutPlan.build(...)` (Models.swift), the **same plan the export uses**, so preview matches
the exported file:
- HW3 / 4 cameras → **2×2** (front, back / left-repeater, right-repeater).
- HW4 / 6 cameras → **3×2** (front, back, left / right, left-pillar, right-pillar).

The demo placeholder (no footage) mirrors this: `columns = count > 4 ? 3 : 2`.

## Export controls + HUD

- Manual export controls are preserved on iOS: the codec picker binds `state.exportPreset`
  (`setExportPreset`), and the **Engrave telemetry** switch binds `exportOverlayOptions.telemetryHUD`
  (default off). `TeslaCam/NativeExportController.swift` is the current export implementation and
  `docs/domain-contract.md` owns the shared preset contract.
- **Export HUD flip fix:** the engraved telemetry HUD text rendered upside-down only on iOS.
  `ExportOverlayDrawing.drawText` had an iOS-only branch that flipped the CoreText coordinate system
  (`translateBy(y: canvasHeight)` + `scaleBy(1,-1)`). The pixel-buffer context is already y-up: the
  same space as the panel fill and the macOS AppKit path: so the flip was removed. (Known minor gap:
  `drawSymbol` still has no iOS branch, so HUD icons are absent on iOS export.)

## Orientation

Portrait is unlocked in `TeslaCam_iPad_Info.plist` (`UISupportedInterfaceOrientations` +
`~ipad`) **and** the `INFOPLIST_KEY_UISupportedInterfaceOrientations` in both pbxproj build
configs. They must agree.

## Guardrails

- No core edits: the iOS UI binds only to existing `AppState` API.
- Keep the manual codec picker and the engrave-telemetry toggle; don't revert to an automatic-only design.
- Register new Swift files in `project.pbxproj` for both `TeslaCam` (mac) and `TeslaCam iPad` targets.
- `tests/test_codebase_invariants.py` pins the iOS layout facts (single adaptive `IOSWorkspace`,
  split-column wide layout, portrait-first orientation, 2×2 preview, safe-area discipline, upright
  HUD). Update those invariants in the same change when the layout legitimately changes.
