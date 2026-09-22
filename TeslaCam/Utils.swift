import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

enum TeslaCamBuildFlags {
#if DEBUG
  static let showsDebugTools = true
#else
  static let showsDebugTools = false
#endif
}

enum TeslaCamFormatters {
  private static func makeFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = format
    return formatter
  }

  static let fullDateTime = makeFormatter("yyyy-MM-dd HH:mm:ss")
  static let shortDate = makeFormatter("MMM d, yyyy")
  static let timelineSameDay = makeFormatter("HH:mm")
  static let timelineTwoDay = makeFormatter("d/MM/yy-HH:mm")
  static let timelineMultiDay = makeFormatter("d/MM/yy")
  static let selectedRange = makeFormatter("d/MM/yy-HH:mm:ss")
  static let eventTimestamp = makeFormatter("yyyy-MM-dd'T'HH:mm:ss")
}

func formatDateTime(_ date: Date) -> String {
  TeslaCamFormatters.fullDateTime.string(from: date)
}

func formatShortDate(_ date: Date) -> String {
  TeslaCamFormatters.shortDate.string(from: date)
}

func formatHMS(_ seconds: Double) -> String {
  let total = max(0, Int(seconds.rounded()))
  let h = total / 3600
  let m = (total % 3600) / 60
  let s = total % 60
  return String(format: "%02d:%02d:%02d", h, m, s)
}

func parseHMS(_ text: String) -> Double? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  let rawParts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
  guard (1...3).contains(rawParts.count) else { return nil }

  let parts = rawParts.compactMap { Int($0) }
  guard parts.count == rawParts.count, parts.allSatisfy({ $0 >= 0 }) else { return nil }

  switch parts.count {
  case 1:
    return Double(parts[0])
  case 2:
    return Double(parts[0] * 60 + parts[1])
  case 3:
    return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
  default:
    return nil
  }
}

func floorToMinute(_ date: Date) -> Date {
  let calendar = Calendar.current
  let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
  return calendar.date(from: comps) ?? date
}

func ceilToMinute(_ date: Date) -> Date {
  let floored = floorToMinute(date)
  if floored == date {
    return date
  }
  return floored.addingTimeInterval(60)
}

nonisolated extension Array {
  subscript(safe index: Int) -> Element? {
    guard index >= 0 && index < count else { return nil }
    return self[index]
  }
}

#if canImport(SwiftUI)
enum TeslaCamTheme {
  enum Colors {
    #if os(iOS)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let backgroundGlow = Color.accentColor.opacity(0.08)
    static let backgroundWarmGlow = Color(uiColor: .systemOrange).opacity(0.035)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceElevated = Color(uiColor: .tertiarySystemGroupedBackground)
    static let chromeBar = Color(uiColor: .secondarySystemBackground).opacity(0.92)
    static let stroke = Color(uiColor: .separator).opacity(0.55)
    static let accent = Color(uiColor: .systemBlue)
    static let accentSoft = Color(uiColor: .systemBlue).opacity(0.14)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let gapFill = Color(uiColor: .systemRed).opacity(0.10)
    static let gapAccent = Color(uiColor: .systemRed)
    static let overlayScrim = Color.black.opacity(0.78)
    static let overlaySurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let overlaySurfaceStrong = Color(uiColor: .secondarySystemGroupedBackground)
    static let controlKnob = Color(uiColor: .systemBackground)
    static let controlKnobStroke = Color(uiColor: .separator)
    #else
    static let background = Color(red: 0.045, green: 0.047, blue: 0.055)
    static let backgroundGlow = Color(red: 0.22, green: 0.45, blue: 0.92).opacity(0.16)
    static let backgroundWarmGlow = Color(red: 0.93, green: 0.38, blue: 0.28).opacity(0.08)
    static let surface = Color.white.opacity(0.04)
    static let surfaceElevated = Color.white.opacity(0.065)
    static let chromeBar = Color.white.opacity(0.055)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.24, green: 0.54, blue: 0.93)
    static let accentSoft = accent.opacity(0.22)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.48)
    static let gapFill = Color(red: 0.17, green: 0.12, blue: 0.12)
    static let gapAccent = Color(red: 0.93, green: 0.38, blue: 0.28)
    static let overlayScrim = Color.black.opacity(0.78)
    static let overlaySurface = Color.white.opacity(0.08)
    static let overlaySurfaceStrong = Color(red: 0.035, green: 0.036, blue: 0.042)
    static let controlKnob = Color.white.opacity(0.88)
    static let controlKnobStroke = Color.white.opacity(0.2)
    #endif

    // Teslatlas-derived progress spectrum (shared across platforms).
    static let progressBarStart = Color(red: 0.294, green: 0.549, blue: 1.0)
    static let progressBarMid = Color(red: 0.490, green: 0.361, blue: 1.0)
    static let progressBlue = Color(red: 0.431, green: 0.663, blue: 1.0)
  }

  enum Metrics {
    #if os(iOS)
    static let controlHeight: CGFloat = 32
    static let compactControlHeight: CGFloat = 32
    #else
    static let controlHeight: CGFloat = 32
    static let compactControlHeight: CGFloat = 32
    #endif
    /// Standard chrome strip height (toolbars, status bars).
    static let toolbarHeight: CGFloat = 52

    #if os(iOS)
    static let cardCorner: CGFloat = 10
    static let controlCorner: CGFloat = 10
    static let compactCorner: CGFloat = 10
    #else
    static let cardCorner: CGFloat = 10
    static let controlCorner: CGFloat = 7
    static let compactCorner: CGFloat = 7
    #endif

    /// Full-width primary CTA height (Teslatlas parity, 48pt).
    static let primaryButtonHeight: CGFloat = 48
    /// Minimum comfortable touch target on iOS (Apple HIG, 44pt).
    static let touchTarget: CGFloat = 44

    /// Padding inside a primary content card (e.g. TimelineExportCard, PreviewPanelCard).
    static let cardPadding: CGFloat = 20
    /// Padding inside a secondary / compact card.
    static let cardPaddingCompact: CGFloat = 14
    /// Padding inside a small inline chip (chips, info banners).
    static let chipPaddingHorizontal: CGFloat = 10
    static let chipPaddingVertical: CGFloat = 6

    /// Outer screen-edge padding for top-level content.
    static let contentPadding: CGFloat = 24
  }

  /// 4pt grid. Use semantic helpers (`cardGap`, `rowGap`, `inlineGap`) by preference.
  enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24

    /// Gap between sibling cards in a vertical stack (or between major sections of a screen).
    static let cardGap: CGFloat = 16
    /// Gap between rows of content inside a card.
    static let rowGap: CGFloat = 12
    /// Gap between inline elements in an HStack (icon + text, button group, etc.).
    static let inlineGap: CGFloat = 8
    /// Tight gap for closely-coupled inline elements (icon+label inside a chip).
    static let tightGap: CGFloat = 6

    /// Outer screen-edge padding (matches `Metrics.contentPadding`).
    static let screen: CGFloat = 24
    /// Outer screen-edge padding on compact width (iPhone), Teslatlas parity.
    static let screenCompact: CGFloat = 16
    /// Vertical separation between major page sections.
    static let section: CGFloat = 32
  }

  enum Layout {
    static let toolbarHeight: CGFloat = Metrics.toolbarHeight
    static let narrowPanelWidth: CGFloat = 470
    static let overlayCardWidth: CGFloat = 580
    static let overlayContentWidth: CGFloat = 520
    static let duplicateSheetWidth: CGFloat = 460
    /// Readable centered content column for full-screen flows (iPad / large phones).
    static let contentMaxWidth: CGFloat = 560
  }

  enum Typography {
    static let heroTitle = Font.system(size: 30, weight: .bold)
    /// Teslatlas-parity in-scroll page title (34 bold).
    static let pageTitle = Font.system(size: 34, weight: .bold)
    /// Card / section title (17 semibold).
    static let cardTitle = Font.system(size: 17, weight: .semibold)
    /// Large rounded metric value (26 semibold rounded).
    static let metricValueRounded = Font.system(size: 26, weight: .semibold, design: .rounded)
    /// Hero rounded metric (30 bold rounded).
    static let heroMetricRounded = Font.system(size: 30, weight: .bold, design: .rounded)
    static let panelTitle = Font.system(size: 22, weight: .bold)
    static let panelSubtitle = Font.system(size: 15)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 14)
    static let bodySmall = Font.system(size: 13)
    /// Eyebrow / overline label (uppercased small caps style).
    static let label = Font.system(size: 11, weight: .semibold)
    static let monoDetail = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let numericBody = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let numericLarge = Font.system(size: 18, weight: .semibold, design: .monospaced)
    static let metricValue = Font.system(size: 13, weight: .semibold, design: .monospaced)
  }
}

enum SurfaceRole: CaseIterable {
  case panel
  case overlay
  case control
  case selected

  var fill: Color {
    switch self {
    case .panel:
      return TeslaCamTheme.Colors.surface
    case .overlay:
      return TeslaCamTheme.Colors.overlaySurfaceStrong
    case .control:
      return TeslaCamTheme.Colors.surfaceElevated
    case .selected:
      return TeslaCamTheme.Colors.accentSoft
    }
  }

  var stroke: Color {
    switch self {
    case .selected:
      return TeslaCamTheme.Colors.accent.opacity(0.52)
    default:
      return TeslaCamTheme.Colors.stroke
    }
  }

  var glassTint: Color? {
    switch self {
    case .selected:
      return TeslaCamTheme.Colors.accent.opacity(0.18)
    case .overlay:
      #if os(iOS)
      return Color.white.opacity(0.30)
      #else
      return Color.black.opacity(0.18)
      #endif
    case .control:
      return TeslaCamTheme.Colors.surfaceElevated
    case .panel:
      return nil
    }
  }
}

enum CompactControlSize: CaseIterable {
  case icon
  case chip
  case command

  var visualWidth: CGFloat {
    switch self {
    case .icon:
      return TeslaCamTheme.Metrics.compactControlHeight
    case .chip:
      return 64
    case .command:
      return 152
    }
  }

  var visualHeight: CGFloat {
    switch self {
    case .icon:
      return TeslaCamTheme.Metrics.compactControlHeight
    case .chip:
      return TeslaCamTheme.Metrics.compactControlHeight
    case .command:
      return TeslaCamTheme.Metrics.compactControlHeight
    }
  }

  var hitTargetWidth: CGFloat { 44 }
  var hitTargetHeight: CGFloat { 44 }

  var maxWidth: CGFloat {
    switch self {
    case .icon:
      return TeslaCamTheme.Metrics.compactControlHeight
    case .chip:
      return 96
    case .command:
      return 152
    }
  }
}

struct TeslaCamSceneBackground: View {
  var body: some View {
    TeslaCamTheme.Colors.background
      .overlay(
        LinearGradient(
          colors: [TeslaCamTheme.Colors.surface.opacity(0.42), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .overlay(alignment: .topLeading) {
        Rectangle()
          .fill(TeslaCamTheme.Colors.backgroundGlow)
          .frame(width: 520, height: 520)
          .blur(radius: 80)
          .offset(x: -180, y: -220)
      }
      .overlay(alignment: .bottomTrailing) {
        Rectangle()
          .fill(TeslaCamTheme.Colors.backgroundWarmGlow)
          .frame(width: 460, height: 460)
          .blur(radius: 90)
          .offset(x: 180, y: 180)
      }
      .ignoresSafeArea()
  }
}

private struct TeslaCamCardModifier: ViewModifier {
  let fill: Color
  let radius: CGFloat

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 0.5)
      )
  }
}

private struct GlassSurfaceModifier: ViewModifier {
  let role: SurfaceRole
  let radius: CGFloat
  let interactive: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    content
      .background(role.fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(role.stroke, lineWidth: 0.5)
      )
  }
}

extension View {
  func glassSurface(
    role: SurfaceRole = .panel,
    radius: CGFloat = TeslaCamTheme.Metrics.cardCorner,
    interactive: Bool = false
  ) -> some View {
    modifier(GlassSurfaceModifier(role: role, radius: radius, interactive: interactive))
  }

  func teslaCamCard(
    fill: Color = TeslaCamTheme.Colors.surface,
    radius: CGFloat = TeslaCamTheme.Metrics.cardCorner
  ) -> some View {
    modifier(TeslaCamCardModifier(fill: fill, radius: radius))
  }

  func compactButtonStyle(
    role: SurfaceRole = .control,
    size: CompactControlSize = .chip
  ) -> some View {
    buttonStyle(CompactButtonStyle(role: role, size: size))
  }

  @ViewBuilder
  func preferredTeslaCamColorScheme() -> some View {
    #if os(macOS)
    environment(\.colorScheme, .dark)
    #else
    self
    #endif
  }
}

struct GlassEffectGroup<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: () -> Content

  init(spacing: CGFloat = TeslaCamTheme.Spacing.m, @ViewBuilder content: @escaping () -> Content) {
    self.spacing = spacing
    self.content = content
  }

  @ViewBuilder
  var body: some View {
    #if os(iOS)
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) {
        content()
      }
    } else {
      content()
    }
    #else
    content()
    #endif
  }
}

struct CompactButtonStyle: ButtonStyle {
  let role: SurfaceRole
  let size: CompactControlSize

  func makeBody(configuration: Configuration) -> some View {
    ZStack {
      configuration.label
        .font(TeslaCamTheme.Typography.label)
        .foregroundStyle(TeslaCamTheme.Colors.textPrimary.opacity(configuration.isPressed ? 0.72 : 0.96))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .padding(.horizontal, size == .icon ? 0 : TeslaCamTheme.Spacing.s)
        .frame(width: size == .icon ? size.visualWidth : nil)
        .frame(minWidth: size == .icon ? nil : size.visualWidth)
        .frame(maxWidth: size.maxWidth)
        .frame(height: size.visualHeight)
        .glassSurface(
          role: role,
          radius: TeslaCamTheme.Metrics.compactCorner,
          interactive: true
        )
    }
    .frame(minWidth: size.hitTargetWidth, minHeight: size.hitTargetHeight)
    .opacity(configuration.isPressed ? 0.82 : 1)
    .contentShape(Rectangle())
  }
}
#endif
