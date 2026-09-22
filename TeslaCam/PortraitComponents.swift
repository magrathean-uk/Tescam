#if os(iOS)
import SwiftUI

// MARK: - Motion tokens (Teslatlas-derived, Reduce-Motion aware)

enum TeslaCamMotion {
  /// Snappy selection changes (pill picker, toggles).
  static let pill: Animation = .snappy(duration: 0.25)
  /// Content reveal / section entrance.
  static let reveal: Animation = .snappy(duration: 0.35)
  /// Numeric text transitions.
  static let numeric: Animation = .snappy(duration: 0.28)
  /// Button press feedback.
  static let press: Animation = .easeInOut(duration: 0.15)
}

// MARK: - Staggered reveal (section entrance)

private struct StaggeredRevealModifier<Trigger: Hashable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isVisible = false

  let index: Int
  let trigger: Trigger
  let baseDelay: Double
  let offsetY: CGFloat
  let disabled: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : offsetY)
      .onAppear { revealIn() }
      .onChange(of: trigger) { _, _ in
        isVisible = false
        revealIn()
      }
  }

  private func revealIn() {
    guard !reduceMotion, !disabled else {
      isVisible = true
      return
    }
    let delay = max(0, baseDelay * Double(index))
    withAnimation(TeslaCamMotion.reveal.delay(delay)) {
      isVisible = true
    }
  }
}

extension View {
  /// Fades + lifts a view in, staggered by `index`. No-op under Reduce Motion.
  func teslaCamReveal<Trigger: Hashable>(
    index: Int,
    trigger: Trigger,
    baseDelay: Double = 0.045,
    offsetY: CGFloat = 10,
    disabled: Bool = false
  ) -> some View {
    modifier(StaggeredRevealModifier(index: index, trigger: trigger, baseDelay: baseDelay, offsetY: offsetY, disabled: disabled))
  }
}

// MARK: - Full-width primary CTA (Teslatlas PrimaryButtonStyle parity)

struct TeslaCamCTAButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var tint: Color = TeslaCamTheme.Colors.accent

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(TeslaCamTheme.Typography.cardTitle)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(maxWidth: .infinity)
      .frame(height: TeslaCamTheme.Metrics.primaryButtonHeight)
      .foregroundStyle(.white)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
          .fill(tint.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.45))
      )
      .opacity(isEnabled ? 1 : 0.75)
      .contentShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous))
      .animation(reduceMotion ? nil : TeslaCamMotion.press, value: configuration.isPressed)
  }
}

// MARK: - In-scroll page header (no floating nav title)

struct TeslaCamPageHeader: View {
  let title: String
  var subtitle: String? = nil
  var subtitleSystemImage: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(TeslaCamTheme.Typography.pageTitle)
        .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityAddTraits(.isHeader)

      if let subtitle, !subtitle.isEmpty {
        HStack(spacing: 6) {
          if let subtitleSystemImage {
            Image(systemName: subtitleSystemImage)
              .font(.system(size: 11, weight: .semibold))
          }
          Text(subtitle)
            .font(TeslaCamTheme.Typography.bodySmall)
        }
        .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Sliding-pill segmented picker

struct TeslaCamPillOption<Value: Hashable> {
  let value: Value
  let label: String

  init(_ value: Value, _ label: String) {
    self.value = value
    self.label = label
  }
}

struct TeslaCamPillPicker<Value: Hashable>: View {
  let options: [TeslaCamPillOption<Value>]
  @Binding var selection: Value
  var accessibilityLabel: String = "Options"

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var namespace

  var body: some View {
    HStack(spacing: 3) {
      ForEach(options.indices, id: \.self) { index in
        let option = options[index]
        let isActive = option.value == selection
        Button {
          withAnimation(reduceMotion ? nil : TeslaCamMotion.pill) {
            selection = option.value
          }
        } label: {
          Text(option.label)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(isActive ? Color.white : TeslaCamTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
              if isActive {
                RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
                  .fill(TeslaCamTheme.Colors.accent)
                  .matchedGeometryEffect(id: "pill", in: namespace)
              }
            }
            .contentShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
        .fill(TeslaCamTheme.Colors.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
        .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 0.5)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }
}

// MARK: - Titled section surface

struct TeslaCamSectionCard<Content: View>: View {
  let title: String
  var systemImage: String? = nil
  var padding: CGFloat = TeslaCamTheme.Metrics.cardPaddingCompact
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.m) {
      HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        }
        Text(title.uppercased())
          .font(TeslaCamTheme.Typography.label)
          .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
          .tracking(0.6)
        Spacer(minLength: 0)
      }
      content()
    }
    .padding(padding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassSurface(role: .panel, radius: TeslaCamTheme.Metrics.cardCorner)
  }
}
#endif
