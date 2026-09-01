import SwiftUI

extension AppAppearanceMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

enum DevSpaceActionRole {
    case primary
    case secondary
    case quiet
    case danger
}

struct DevSpaceActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    let role: DevSpaceActionRole
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(role == .primary ? .semibold : .medium))
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, DevSpaceSpacing.medium)
            .padding(.vertical, DevSpaceSpacing.small + 1)
            .background(backgroundColor(configuration: configuration))
            .clipShape(RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control)
                    .strokeBorder(borderColor, lineWidth: DevSpaceStrokeWidth.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control))
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(
                reduceMotion || !configuration.isPressed ? 1 : 0.985
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }

    private var foregroundColor: Color {
        switch role {
        case .primary:
            .white
        case .secondary, .quiet:
            .primary
        case .danger:
            .red
        }
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        let pressedBoost = configuration.isPressed ? 0.08 : 0

        return switch role {
        case .primary:
            Color.accentColor.opacity(1 - pressedBoost)
        case .secondary:
            Color.primary.opacity(0.075 + pressedBoost)
        case .quiet:
            Color.primary.opacity(configuration.isPressed ? 0.08 : 0)
        case .danger:
            Color.red.opacity(0.075 + pressedBoost)
        }
    }

    private var borderColor: Color {
        switch role {
        case .primary:
            Color.white.opacity(0.18)
        case .secondary:
            Color.primary.opacity(0.12)
        case .quiet:
            .clear
        case .danger:
            Color.red.opacity(0.18)
        }
    }
}

struct MenuBarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let preferences: AppearancePreferences
    var cornerRadius = DevSpaceCornerRadius.panel
    var showsElevation = true

    func body(content: Content) -> some View {
        let appearance = MenuBarAppearanceResolver.resolve(
            preferences: preferences,
            accessibility: MenuBarAccessibilityEnvironment(
                reduceTransparency: reduceTransparency,
                increaseContrast: colorSchemeContrast == .increased,
                differentiateWithoutColor: differentiateWithoutColor,
                reduceMotion: reduceMotion
            )
        )

        content
            .background {
                ZStack {
                    material(for: appearance.materialRole)
                    Color.accentColor.opacity(appearance.tintOpacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.primary.opacity(appearance.borderOpacity),
                        lineWidth: DevSpaceStrokeWidth.hairline
                    )
            }
            .shadow(
                color: showsElevation ? glowColor(for: appearance) : .clear,
                radius: showsElevation ? glowRadius(for: appearance) : 0
            )
            .shadow(
                color: showsElevation
                    ? Color.black.opacity(appearance.shadowOpacity)
                    : .clear,
                radius: showsElevation ? 16 : 0,
                y: showsElevation ? 8 : 0
            )
    }

    @ViewBuilder
    private func material(for role: MenuBarMaterialRole) -> some View {
        switch role {
        case .ultraThin:
            Rectangle().fill(.ultraThinMaterial)
        case .thin:
            Rectangle().fill(.thinMaterial)
        case .regular:
            Rectangle().fill(.regularMaterial)
        case .thick:
            Rectangle().fill(.thickMaterial)
        case .opaque:
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func glowColor(for appearance: ResolvedMenuBarAppearance) -> Color {
        switch appearance.glow {
        case .off:
            .clear
        case .subtle:
            Color.accentColor.opacity(0.2)
        case .prominent:
            Color.accentColor.opacity(0.32)
        }
    }

    private func glowRadius(for appearance: ResolvedMenuBarAppearance) -> CGFloat {
        switch appearance.glow {
        case .off:
            0
        case .subtle:
            9
        case .prominent:
            16
        }
    }
}

extension View {
    func menuBarSurface(
        preferences: AppearancePreferences,
        cornerRadius: CGFloat = DevSpaceCornerRadius.panel,
        showsElevation: Bool = true
    ) -> some View {
        modifier(
            MenuBarSurface(
                preferences: preferences,
                cornerRadius: cornerRadius,
                showsElevation: showsElevation
            )
        )
    }
}
