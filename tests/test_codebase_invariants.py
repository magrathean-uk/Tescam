"""Tripwire tests for codebase-wide invariants.

These tests scan the shipping Python source tree for patterns that
have a documented sacred-rule reason to stay absent. They are cheap
(pure file walks; no subprocess) and they are the one place a
regression of "we accidentally introduced shell injection" or
"someone called eval on an untrusted string" surfaces immediately.

The Swift side has its own equivalent guard documented in
``docs/improvement/security-audit-2026-05-09.md`` (G3 process-spawn
audit). Those are git-grep checks; this module's job is the Python
half.

Each forbidden pattern carries a justification comment so a future
maintainer can decide whether to delete the rule or update the test
when behaviour legitimately needs to change.
"""
from __future__ import annotations

import re
import unittest
import plistlib
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent
SHIPPING_ROOT = REPO_ROOT / "teslacam_cli"
SWIFT_SHIPPING_ROOT = REPO_ROOT / "TeslaCam"
XCODE_PROJECT_FILE = REPO_ROOT / "TeslaCam.xcodeproj" / "project.pbxproj"
IPAD_INFO_PLIST = SWIFT_SHIPPING_ROOT / "TeslaCam_iPad_Info.plist"


def _shipping_python_files() -> Iterable[Path]:
    """Every .py file under teslacam_cli/, recursively."""
    yield from sorted(SHIPPING_ROOT.rglob("*.py"))


def _shipping_swift_files() -> Iterable[Path]:
    """Every .swift file under TeslaCam/ (excluding the iPad
    target's resources and any nested generated content). Plain
    rglob is fine — TeslaCam/ does not nest derived data; the
    cache isolation work parks build state under .cache/.
    """
    yield from sorted(SWIFT_SHIPPING_ROOT.rglob("*.swift"))


def _grep_lines(pattern: re.Pattern[str], paths: Iterable[Path]) -> list[tuple[Path, int, str]]:
    hits: list[tuple[Path, int, str]] = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for index, line in enumerate(text.splitlines(), start=1):
            if pattern.search(line):
                hits.append((path, index, line.rstrip()))
    return hits


def _format_hits(hits: list[tuple[Path, int, str]]) -> str:
    return "\n".join(f"  {path.relative_to(REPO_ROOT)}:{line}: {body}" for path, line, body in hits)


def _swift_block(source: str, declaration: str) -> str:
    start = source.index(declaration)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"could not find end of Swift block starting at {declaration!r}")


class ForbiddenPatternTests(unittest.TestCase):
    """Patterns that must never appear in the shipping CLI source.

    Each test pins one rule. If a pattern legitimately has to come
    back (e.g. a documented exception), update the matching rule
    here in the same commit.
    """

    def test_shell_true_is_never_used_in_subprocess_calls(self):
        # Justification: every subprocess invocation in
        # teslacam_cli/process_tools.py builds an argv list and passes
        # it to subprocess.Popen WITHOUT shell=True. Reintroducing
        # shell=True would let user-controlled paths reach shell
        # metacharacters (sacred rule G3).
        pattern = re.compile(r"\bshell\s*=\s*True\b")
        hits = _grep_lines(pattern, _shipping_python_files())
        self.assertEqual(hits, [], f"shell=True must not appear in shipping CLI source:\n{_format_hits(hits)}")

    def test_os_system_is_never_used(self):
        # Justification: same reasoning as shell=True; os.system
        # invokes /bin/sh -c with the input string and inherits
        # injection risk.
        pattern = re.compile(r"\bos\.system\(")
        hits = _grep_lines(pattern, _shipping_python_files())
        self.assertEqual(hits, [], f"os.system() must not appear in shipping CLI source:\n{_format_hits(hits)}")

    def test_dynamic_eval_and_exec_are_never_used(self):
        # Justification: the CLI never needs to evaluate user-supplied
        # code; eval / exec on any string risks remote code execution
        # if the input ever flows from a TeslaCam-derived path or env
        # var. Limit to the literal call form `eval(` / `exec(` so
        # words like "evaluate" and "execute" in comments are fine.
        eval_pattern = re.compile(r"(?<![A-Za-z_])eval\(")
        exec_pattern = re.compile(r"(?<![A-Za-z_])exec\(")
        hits = _grep_lines(eval_pattern, _shipping_python_files()) + _grep_lines(
            exec_pattern, _shipping_python_files()
        )
        self.assertEqual(hits, [], f"eval()/exec() must not appear in shipping CLI source:\n{_format_hits(hits)}")

    def test_dynamic_import_is_never_used(self):
        # Justification: regular `import` statements flow through the
        # well-known module resolution path; __import__ on a runtime
        # string is suspicious in CLI code that does not need plugin
        # loading. If we ever add a real plugin system, document it
        # and update this rule.
        pattern = re.compile(r"(?<![A-Za-z_])__import__\(")
        hits = _grep_lines(pattern, _shipping_python_files())
        self.assertEqual(hits, [], f"__import__() must not appear in shipping CLI source:\n{_format_hits(hits)}")

    def test_break_system_packages_is_never_committed(self):
        # Justification: --break-system-packages bypasses PEP 668
        # protection and is a developer convenience for Linux-managed
        # Python installs. It must never be committed to shipping
        # source — it would leak into pip install commands the CLI
        # might construct (none today, but the rule is cheap to keep).
        pattern = re.compile(r"--break-system-packages")
        hits = _grep_lines(pattern, _shipping_python_files())
        self.assertEqual(
            hits,
            [],
            f"--break-system-packages must not appear in shipping CLI source:\n{_format_hits(hits)}",
        )


class SwiftForbiddenPatternTests(unittest.TestCase):
    """Patterns that must never appear in shipping Swift source under
    ``TeslaCam/``.

    Each rule matches a sacred-rule reason. If a pattern legitimately
    needs to come back, update the rule in the same commit and explain
    why in the commit message.
    """

    def test_print_is_never_used_in_shipping_swift(self):
        # Justification: G5 logging discipline — the macOS app routes
        # every diagnostic through DebugLogSink (Logger with .private
        # message redaction). A bare `print(` in shipping Swift would
        # leak user-controlled paths to the unified log without
        # redaction. Currently zero hits; lock that.
        pattern = re.compile(r"\bprint\(")
        hits = _grep_lines(pattern, _shipping_swift_files())
        self.assertEqual(
            hits,
            [],
            f"print( must not appear in shipping Swift source — use DebugLogSink instead:\n{_format_hits(hits)}",
        )

    def test_sentry_is_never_referenced_in_shipping_swift(self):
        # Justification: sacred rule 7 — no Sentry, no analytics, no
        # external crash telemetry. The repo CLAUDE.md overrides the
        # global Sentry MCP guidance for this project; diagnostics
        # stay local via the in-app Show Log surface.
        pattern = re.compile(r"\bSentry\b")
        hits = _grep_lines(pattern, _shipping_swift_files())
        self.assertEqual(
            hits,
            [],
            f"Sentry references must not appear in shipping Swift source:\n{_format_hits(hits)}",
        )

    def test_legacy_is_never_referenced_in_shipping_swift(self):
        # Justification: sacred rule 5 — `_legacy/` and
        # `teslacam_legacy_macos.sh` are reference only. Anything in
        # shipping code that imports or path-references `_legacy/`
        # is a contract violation per H6 audit
        # (docs/improvement/hygiene-audit-2026-05-09.md).
        pattern = re.compile(r"_legacy(?:/|\\\\)")
        hits = _grep_lines(pattern, _shipping_swift_files())
        self.assertEqual(
            hits,
            [],
            f"_legacy/ references must not appear in shipping Swift source:\n{_format_hits(hits)}",
        )

    def test_ios_target_supports_portrait_and_landscape(self):
        # Justification: the iOS app is a proper portrait-first phone/pad app with
        # a dedicated vertical workspace (IOSPhoneWorkspace) plus a landscape review
        # workspace, so portrait and both landscape orientations are all unlocked.
        text = XCODE_PROJECT_FILE.read_text(encoding="utf-8")
        orientation_lines = [
            line.strip()
            for line in text.splitlines()
            if "INFOPLIST_KEY_UISupportedInterfaceOrientations" in line
        ]
        self.assertTrue(orientation_lines, "expected supported-orientation build settings in project file")
        orientation_text = "\n".join(orientation_lines)
        self.assertIn("UIInterfaceOrientationPortrait", orientation_text)
        self.assertIn("UIInterfaceOrientationLandscapeLeft", orientation_text)
        self.assertIn("UIInterfaceOrientationLandscapeRight", orientation_text)
        self.assertIn('TARGETED_DEVICE_FAMILY = "1,2";', text)

    def test_ios_target_registers_folder_documents(self):
        # Justification: Files handoff and SwiftUI import both need the
        # iOS app registered for folder documents, otherwise a TeslaCam
        # folder in Downloads can open to a no-op app launch.
        text = XCODE_PROJECT_FILE.read_text(encoding="utf-8")
        self.assertIn("INFOPLIST_FILE = TeslaCam/TeslaCam_iPad_Info.plist;", text)
        with IPAD_INFO_PLIST.open("rb") as fh:
            plist = plistlib.load(fh)
        document_types = plist.get("CFBundleDocumentTypes", [])
        flattened_types = {
            content_type
            for document_type in document_types
            for content_type in document_type.get("LSItemContentTypes", [])
        }
        self.assertIn("public.folder", flattened_types)
        self.assertIn("public.directory", flattened_types)
        self.assertTrue(plist.get("UISupportsDocumentBrowser"))
        self.assertTrue(plist.get("LSSupportsOpeningDocumentsInPlace"))

    def test_ipad_dashboard_has_no_static_top_app_title(self):
        # Justification: the iPad dashboard uses the footage grid as
        # the app identity. A static top title wastes vertical space.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        self.assertNotIn("TeslaCam CCTV", source)

    def test_content_view_routes_to_separate_platform_views(self):
        # Justification: macOS and iOS share the engine, not the view tree.
        # ContentView stays thin so iOS can be a native touch workspace
        # without inheriting desktop-only density decisions.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        content_view = _swift_block(source, "struct ContentView: View")
        self.assertIn("MacContentView(state: state)", content_view)
        self.assertIn("IOSContentView(state: state)", content_view)
        self.assertNotIn("MacLoadedWorkspace(", content_view)
        self.assertNotIn("IOSReviewWorkspace(", content_view)
        self.assertIn("private struct MacContentView", source)
        self.assertIn("private struct IOSContentView", source)
        # Status bar is hidden only in landscape (compact height). In portrait it
        # stays visible so the system reserves the Dynamic Island region and
        # content is inset below it.
        self.assertIn(".statusBarHidden(verticalSizeClass == .compact)", source)
        self.assertNotIn(".statusBarHidden(true)", source)
        self.assertNotIn("private struct IPadLoadedScreen", source)

    def test_ios_loaded_workspace_is_native_touch_tree(self):
        # Justification: iOS needs its own editor surface with stage,
        # timeline, touch dock, and clipped metadata moved to a sheet.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        workspace_source = _swift_block(source, "private struct IOSWorkspace")
        self.assertIn("PreviewPanelCard(", workspace_source)
        self.assertIn("scrubberSection", workspace_source)
        self.assertIn("cameraSection", workspace_source)
        self.assertIn("exportSection", workspace_source)
        # It is the adaptive native surface, not the mac timeline dock.
        self.assertNotIn("TimelineExportCard(", workspace_source)
        self.assertIn("private struct IOSWorkspace", source)

    def test_ios_landscape_workspace_respects_safe_area(self):
        # Justification: iPhone/iPad landscape must keep every control clear of the
        # Dynamic Island / notch / home indicator. The workspace stays inside the
        # safe area (SwiftUI insets it automatically); only the scene background
        # bleeds edge-to-edge.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        ios_content = _swift_block(source, "private struct IOSContentView")
        self.assertIn(".background(TeslaCamSceneBackground())", ios_content)
        # The workspace gets the already-inset `proxy.size` and never ignores the
        # safe area itself — only the scene background bleeds behind it.
        self.assertNotIn(".ignoresSafeArea", ios_content)

    def test_ios_is_portrait_first_without_orientation_lock(self):
        # Justification: iPhone/iPad must be a proper portrait-first app, not a
        # landscape-only tool. The "Rotate Device" lock screen is gone; portrait
        # routes to a dedicated vertical workspace with a pinned export CTA, and
        # portrait is unlocked at the OS level.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        self.assertIn("private struct IOSWorkspace", source)
        self.assertNotIn("IPadLandscapeLockScreen", source)
        self.assertNotIn("Rotate Device", source)
        ios_content = _swift_block(source, "private struct IOSContentView")
        self.assertIn("IOSWorkspace(", ios_content)
        # The portrait workspace pins the export CTA above the home indicator.
        self.assertIn(".safeAreaInset(edge: .bottom", source)
        # Portrait orientation is declared at the OS level.
        plist = (SWIFT_SHIPPING_ROOT / "TeslaCam_iPad_Info.plist").read_text(encoding="utf-8")
        self.assertIn("UIInterfaceOrientationPortrait", plist)

    def test_ipad_timeline_track_has_enough_vertical_room(self):
        # Justification: the shared mac-style timeline keeps labels
        # below the track and a compact control dock below that.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private var timelineDock")
        end = source.index("private var transportButtonCluster", start)
        timeline_source = source[start:end]
        self.assertIn(".frame(height: 36)", timeline_source)
        self.assertIn("recordedTickFractions", timeline_source)

    def test_ios_wide_layout_uses_split_columns(self):
        # Justification: landscape / iPad fills the width with a filling player
        # column and a vertically-scrolling control column — NOT a horizontally
        # scrolling control row that pushes buttons (e.g. Export) off-screen.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        workspace = _swift_block(source, "private struct IOSWorkspace")
        self.assertIn("wideBody", workspace)
        self.assertIn("compactBody", workspace)
        self.assertNotIn("ScrollView(.horizontal", workspace)
        ios_content = _swift_block(source, "private struct IOSContentView")
        self.assertIn("horizontalSizeClass == .regular || proxy.size.width > proxy.size.height", ios_content)

    def test_engrave_telemetry_is_opt_in_and_defaults_off(self):
        # Justification: telemetry burn-in should remain explicit even when the
        # default export stays a regular encoded 2x2 grid.
        view_source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        self.assertIn('isOn: $state.exportOverlayOptions.telemetryHUD', view_source)
        self.assertIn('"engrave-telemetry-toggle"', view_source)
        state_source = (SWIFT_SHIPPING_ROOT / "AppState.swift").read_text(encoding="utf-8")
        self.assertIn("telemetryHUD: false", state_source)
        self.assertNotIn("telemetryHUD: true,", state_source)

    def test_export_controls_keep_manual_trim_inputs_and_live_codec_choice(self):
        # Justification: both platform docks must allow direct IN/OUT entry
        # and keep the codec control interactive.
        view_source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        self.assertIn('trimInputField("In"', view_source)
        self.assertIn('trimInputField("Out"', view_source)
        self.assertIn('trimField("In"', view_source)
        self.assertIn('trimField("Out"', view_source)
        self.assertIn("applyTrimStartInput", view_source)
        self.assertIn("applyTrimEndInput", view_source)
        self.assertIn("selection: exportPresetBinding", view_source)

    def test_timeline_track_hides_telemetry_event_markers(self):
        # Justification: telemetry markers appeared only after scrubbing and
        # made the compact timeline look inconsistent. Keep the main seeker
        # clean; telemetry still belongs in clip/export information.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private struct TimelineSelectionTrack")
        end = source.index("private struct TimelineGapBand", start)
        timeline_source = source[start:end]
        self.assertNotIn("let eventMarkers: [TelemetryEventMarker]", timeline_source)
        self.assertNotIn("let eventMarkerOffsetSeconds: Double", timeline_source)
        self.assertNotIn("eventMarkers.prefix(120)", timeline_source)
        self.assertNotIn("markerColor(for: marker.kind)", timeline_source)

    def test_export_hud_draws_top_left_without_flipped_text_context(self):
        # Justification: exported HUD text must be upright and placed in the
        # requested top-left video corner, not burned upside down at the bottom.
        source = (SWIFT_SHIPPING_ROOT / "NativeExportController.swift").read_text(encoding="utf-8")
        start = source.index("static func drawTelemetryOverlay")
        end = source.index("static func drawPrivacyMask", start)
        overlay_source = source[start:end]
        self.assertIn("canvasSize.height - 26 - panelHeight", overlay_source)
        self.assertIn("panel.maxY - 40", overlay_source)
        self.assertIn('NSGraphicsContext(cgContext: context, flipped: false)', source)
        self.assertNotIn('NSGraphicsContext(cgContext: context, flipped: true)', source)

    def test_native_writer_uses_supported_encoder_specification_key(self):
        # Justification: AVAssetWriter rejects the raw
        # "AVVideoEncoderSpecification" key at runtime; use the SDK key where
        # the SDK exposes it and never ship the crashing raw key.
        source = (SWIFT_SHIPPING_ROOT / "NativeExportController.swift").read_text(encoding="utf-8")
        self.assertIn("private static func hardwareEncoderSpecification()", source)
        self.assertIn("settings[AVVideoEncoderSpecificationKey]", source)
        self.assertNotIn('"AVVideoEncoderSpecification"', source)
        self.assertIn("#if !targetEnvironment(simulator)", source)

    def test_native_export_decodes_serially(self):
        # Justification: AVAssetReader/VideoToolbox decode can collapse on
        # timestamp-irregular Tesla clips when multiple camera readers run
        # concurrently. Keep native exports deterministic on every platform.
        source = (SWIFT_SHIPPING_ROOT / "NativeExportController.swift").read_text(encoding="utf-8")
        start = source.index("nonisolated private final class MetalExportCompositor")
        end = source.index("nonisolated private final class TimelineFrameComposer", start)
        compositor_source = source[start:end]
        self.assertIn('static var decodeModeDescription: String {\n    "serial"\n  }', compositor_source)
        self.assertIn("for (index, item) in decoderRequests.enumerated()", compositor_source)
        self.assertNotIn("withTaskGroup", compositor_source)
        self.assertIn("decode=\\(MetalExportCompositor.decodeModeDescription)", source)

    def test_export_action_label_uses_effective_preset(self):
        # Justification: if overlays, reports, privacy masking, or
        # camera cuts require rendered video, the action label must not
        # still claim an original-track passthrough export.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        matches = re.findall(r'private var exportButtonTitle: String', source)
        self.assertEqual(len(matches), 2)
        self.assertIn('"Export video"', source)
        self.assertNotIn("state.exportPreset == .originalTracksMOV ? \"Export Original Tracks\"", source)
        self.assertNotIn("\"Export Original Tracks\"", source)

    def test_ios_workspace_does_not_keep_removed_rail_dashboard_components(self):
        # Justification: the iOS app has a native footage editor tree.
        # Old side rails, map pages, and inspector panels are dead weight.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        stale_symbols = [
            "IPadWorkspaceMode",
            "ScopeBar",
            "IPadVideoStage",
            "IPadTimelineDock",
            "IPadRangeOptionsPanel",
            "IPadMapPage",
            "IPadEventRail",
            "IPadLayoutToolbar",
            "IPadTelemetryRail",
            "IPadExportOptionsPanel",
            "IPadExportStatusPanel",
            "ExportActionCard",
            "TimelinePreviewBars",
        ]
        for symbol in stale_symbols:
            self.assertNotIn(symbol, source)

    def test_ipad_dashboard_tracks_dark_material_reference(self):
        # Justification: the iOS dashboard keeps the matte CCTV direction,
        # but owns its native layout instead of reusing the mac dock.
        content = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        utils = (SWIFT_SHIPPING_ROOT / "Utils.swift").read_text(encoding="utf-8")
        self.assertIn("preferredTeslaCamColorScheme()", content)
        self.assertIn("IOSWorkspace", content)
        self.assertIn("PreviewPanelCard", content)
        self.assertIn("DemoVideoWallPlaceholder", content)
        self.assertIn("currentPreviewNaturalSizes", content)
        self.assertIn("Color(red: 0.045, green: 0.047, blue: 0.055)", utils)
        self.assertIn("Color.white.opacity(0.94)", utils)
        self.assertIn("environment(\\.colorScheme, .dark)", utils)
        self.assertNotIn(".glassEffect(", utils)
        self.assertNotIn("ultraThinMaterial", utils)
        self.assertNotIn("Color(red: 0.965, green: 0.955, blue: 0.935)", utils)
        self.assertNotIn("DemoRoadSceneView", content)
        self.assertNotIn("mountainLayer", content)

    def test_ios_loaded_workspace_has_no_browse_map_scope_bar(self):
        # Justification: the loaded iOS workspace should be the native
        # review/export surface, not a separate Browse/Map dashboard.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        loaded_source = _swift_block(source, "private struct IOSWorkspace")
        self.assertNotIn("IPadWorkspaceMode", loaded_source)
        self.assertNotIn("workspaceMode", loaded_source)
        self.assertNotIn("IPadMapPage", loaded_source)

    def test_ipad_panel_headers_are_single_line_without_subtitles(self):
        # Justification: section subtitles like "3 shown", "Live HUD",
        # and "HUD · output · queue" add noise in the dense CCTV
        # workspace. Panel headers should be one compact label row.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private struct PanelHeader")
        end = source.index("private struct MetricTile", start)
        panel_header_source = source[start:end]
        self.assertNotIn("detail", panel_header_source)
        self.assertNotIn("VStack(alignment: .leading", panel_header_source)
        self.assertNotIn("monoSmall", panel_header_source)
        self.assertNotRegex(source, r"PanelHeader\(\s*\n(?:[^\n]*\n){0,5}\s*detail\s*:")

    def test_preview_panel_uses_grid_preview_without_extra_hud_text(self):
        # Justification: speed/camera stats belong in clip information
        # or the export overlay. The main preview should be a clean
        # grid-first review surface.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private struct PreviewPanelCard")
        end = source.index("private struct TimelineExportCard", start)
        preview_source = source[start:end]
        self.assertIn("cameraOrder: state.gridPreviewCameras", preview_source)
        self.assertIn("previewLayoutMode: effectivePreviewLayoutMode", preview_source)
        self.assertIn("return .grid", preview_source)
        self.assertNotIn("playbackUI.telemetryText", preview_source)
        self.assertNotIn("IPadStageTelemetryOverlay", preview_source)

    def test_shared_timeline_range_uses_mac_quick_ranges(self):
        # Justification: the iOS dock follows the mac quick range set
        # instead of carrying a separate iPad-only 30m row.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private struct MacRangeGrid")
        end = source.index("private struct ExportOverlayCard", start)
        timeline_source = source[start:end]
        self.assertIn('Label("All", systemImage:', timeline_source)
        self.assertIn('state.setCurrentMinuteRange()', timeline_source)
        self.assertIn('state.setRecentRange(minutes: 5)', timeline_source)
        self.assertIn('state.setRecentRange(minutes: 15)', timeline_source)
        self.assertNotIn('state.setRecentRange(minutes: 30)', timeline_source)

    def test_ipad_demo_wall_uses_camera_aspects_without_stretching(self):
        # Justification: demo mode is the design surface. Its camera wall
        # must respect camera aspect classes instead of stretching cameras
        # into arbitrary tall cells.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private struct DemoVideoWallPlaceholder")
        end = source.index("private struct DemoVideoWallTile", start)
        wall_source = source[start:end]
        self.assertIn("effectiveNaturalSizes", wall_source)
        self.assertIn("normalizedAspectRatio", wall_source)
        self.assertIn("16.0 / 9.0", wall_source)
        self.assertIn("4.0 / 3.0", wall_source)
        self.assertIn("shouldShowCameraLabels", wall_source)
        self.assertIn("size.height >= 260", wall_source)
        self.assertIn("contentMode: .fill", wall_source)
        self.assertIn("usesCompactPhonePreview", wall_source)
        self.assertNotIn("LazyVGrid", wall_source)

    def test_phone_four_camera_preview_uses_grid(self):
        # Justification: the phone preview shows four cameras as a 2x2 grid (six as
        # 3x2), never a single horizontal strip.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private struct PreviewPanelCard")
        end = source.index("private struct TimelineExportCard", start)
        preview_source = source[start:end]
        self.assertIn("return .grid", preview_source)
        self.assertNotIn("return .horizontal", preview_source)
        # The demo wall lays out 2 columns for <=4 cameras, 3 for six — not a row.
        wall_start = source.index("private struct DemoVideoWallPlaceholder")
        wall_source = source[wall_start:wall_start + 3000]
        self.assertIn("let columns = displayCameras.count > 4 ? 3 : 2", wall_source)

    def test_phone_demo_wall_hides_camera_titles(self):
        # Justification: iPhone landscape needs the camera picture first;
        # labels consume too much height on the compact preview grid.
        source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        start = source.index("private struct DemoVideoWallTile")
        end = source.index("#endif", start)
        tile_source = source[start:end]
        self.assertIn("let showLabels: Bool", tile_source)
        self.assertIn("if showLabels", tile_source)

    def test_metal_preview_grid_uses_known_camera_natural_sizes(self):
        # Justification: real preview should size HW4/HW3 grid cells from
        # clip dimensions when available. Otherwise 16:9 HW4 footage can
        # be placed inside a stale 4:3 preview grid.
        metal = (SWIFT_SHIPPING_ROOT / "MetalRenderer.swift").read_text(encoding="utf-8")
        ipad_view = (SWIFT_SHIPPING_ROOT / "MetalPlayerView_iPad.swift").read_text(encoding="utf-8")
        mac_view = (SWIFT_SHIPPING_ROOT / "MetalPlayerView.swift").read_text(encoding="utf-8")
        self.assertIn("var naturalSizes: [Camera: CGSize]", metal)
        self.assertIn("naturalSizes: naturalSizes", metal)
        self.assertIn("var naturalSizes: [Camera: CGSize]", ipad_view)
        self.assertIn("var naturalSizes: [Camera: CGSize]", mac_view)

    def test_ios_theme_uses_native_grouped_semantics(self):
        # Justification: the Teslatlas v6 visual family is system-adaptive on
        # iPhone and iPad. Hard-coded white-on-near-black colours make the app
        # ignore light appearance and diverge from that shared design language.
        source = (SWIFT_SHIPPING_ROOT / "Utils.swift").read_text(encoding="utf-8")
        ios_colours = source[source.index("#if os(iOS)"):source.index("#else", source.index("#if os(iOS)"))]
        self.assertIn("Color(uiColor: .systemGroupedBackground)", ios_colours)
        self.assertIn("Color(uiColor: .secondarySystemGroupedBackground)", ios_colours)
        self.assertIn("Color(uiColor: .label)", ios_colours)
        self.assertIn("Color(uiColor: .secondaryLabel)", ios_colours)
        self.assertNotIn("Color.white.opacity(0.94)", ios_colours)

    def test_theme_uses_teslatlas_card_geometry(self):
        # Justification: a 10pt continuous card with a quiet half-point border
        # is the shared Teslatlas/Tescam surface primitive.
        source = (SWIFT_SHIPPING_ROOT / "Utils.swift").read_text(encoding="utf-8")
        self.assertIn("static let cardCorner: CGFloat = 10", source)
        self.assertIn("lineWidth: 0.5", source)

    def test_ios_does_not_force_dark_appearance(self):
        # Justification: iOS follows the user's system appearance. macOS keeps
        # its intentionally dark review workspace.
        source = (SWIFT_SHIPPING_ROOT / "Utils.swift").read_text(encoding="utf-8")
        helper = _swift_block(source, "func preferredTeslaCamColorScheme()")
        self.assertIn("#if os(macOS)", helper)
        self.assertIn("environment(\\.colorScheme, .dark)", helper)
        self.assertIn("#else", helper)

    def test_app_store_capture_defines_five_stable_scenes(self):
        # Justification: the ASC artwork must be repeatable from real sample-mode
        # UI on every platform rather than assembled from stale ad-hoc captures.
        source = (REPO_ROOT / "TeslaCamUITests" / "TeslaCamUITests.swift").read_text(encoding="utf-8")
        self.assertIn("testAppStoreScreenshots", source)
        for scene in ("01-overview", "02-playback", "03-cameras", "04-timeline", "05-export"):
            self.assertIn(scene, source)
        self.assertIn("TESLACAM_SCREENSHOT_DIR", source)
        self.assertIn("app.windows.firstMatch.screenshot()", source)
        mac_source = (SWIFT_SHIPPING_ROOT / "Main.swift").read_text(encoding="utf-8")
        self.assertIn("width: 1440, height: 900", mac_source)
        content_source = (SWIFT_SHIPPING_ROOT / "ContentView.swift").read_text(encoding="utf-8")
        self.assertIn('TeslaCamPageHeader(title: "Tescam"', content_source)
        self.assertIn("TESLACAM_SCREENSHOT_SCENE", content_source)
        self.assertIn('.id("screenshot-export")', content_source)
        self.assertIn("proxy.scrollTo", content_source)


class TestSurfaceTests(unittest.TestCase):
    """Sanity checks on the test surface itself.

    These guard against the tripwire pattern silently passing because
    the file walk found nothing — e.g. if the path constants drift to
    point at an empty directory.
    """

    def test_shipping_root_exists_and_has_python_files(self):
        self.assertTrue(SHIPPING_ROOT.is_dir(), f"{SHIPPING_ROOT} must be a directory")
        files = list(_shipping_python_files())
        self.assertGreaterEqual(len(files), 5, "expected at least a handful of .py files under teslacam_cli/")

    def test_swift_shipping_root_exists_and_has_swift_files(self):
        self.assertTrue(SWIFT_SHIPPING_ROOT.is_dir(), f"{SWIFT_SHIPPING_ROOT} must be a directory")
        files = list(_shipping_swift_files())
        self.assertGreaterEqual(len(files), 5, "expected at least a handful of .swift files under TeslaCam/")

    def test_grep_helper_actually_finds_real_lines(self):
        # If `_grep_lines` quietly returns [] for everything, the
        # forbidden-pattern tests would pass vacuously. Pin one
        # known-present token (the relative-import form used across
        # the shipping CLI) to prove the walker reads files for real.
        pattern = re.compile(r"^from \.")
        hits = _grep_lines(pattern, _shipping_python_files())
        self.assertGreater(
            len(hits),
            0,
            "_grep_lines must surface real matches; failing here means the walker is broken",
        )


if __name__ == "__main__":
    unittest.main()
