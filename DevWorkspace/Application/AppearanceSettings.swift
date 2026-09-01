import Foundation
import Observation

enum MenuBarSkin: String, CaseIterable, Identifiable, Sendable {
    case crystalAir
    case softGlow
    case focusedFrost

    var id: Self { self }

    var localizationKey: String {
        switch self {
        case .crystalAir:
            "settings.appearance.skin.crystal-air"
        case .softGlow:
            "settings.appearance.skin.soft-glow"
        case .focusedFrost:
            "settings.appearance.skin.focused-frost"
        }
    }
}

enum MenuBarTransparency: String, CaseIterable, Identifiable, Sendable {
    case system
    case clear
    case substantial

    var id: Self { self }

    var localizationKey: String {
        switch self {
        case .system:
            "settings.appearance.transparency.system"
        case .clear:
            "settings.appearance.transparency.clear"
        case .substantial:
            "settings.appearance.transparency.substantial"
        }
    }
}

enum MenuBarGlow: String, CaseIterable, Identifiable, Sendable {
    case off
    case subtle
    case prominent

    var id: Self { self }

    var localizationKey: String {
        switch self {
        case .off:
            "settings.appearance.glow.off"
        case .subtle:
            "settings.appearance.glow.subtle"
        case .prominent:
            "settings.appearance.glow.prominent"
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var localizationKey: String {
        switch self {
        case .system:
            "settings.appearance.color-mode.system"
        case .light:
            "settings.appearance.color-mode.light"
        case .dark:
            "settings.appearance.color-mode.dark"
        }
    }
}

enum AppearancePreviewBackground: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case detailed

    var id: Self { self }

    var localizationKey: String {
        switch self {
        case .light:
            "settings.appearance.preview-background.light"
        case .dark:
            "settings.appearance.preview-background.dark"
        case .detailed:
            "settings.appearance.preview-background.detailed"
        }
    }
}

struct AppearancePreferences: Equatable, Sendable {
    var skin: MenuBarSkin
    var transparency: MenuBarTransparency
    var glow: MenuBarGlow
    var colorMode: AppAppearanceMode
}

@MainActor
@Observable
final class AppearanceSettings {
    static let skinKey = "appearance.skin"
    static let transparencyKey = "appearance.transparency"
    static let glowKey = "appearance.glow"
    static let colorModeKey = "appearance.color-mode"
    static let previewBackgroundKey = "appearance.preview-background"

    var skin: MenuBarSkin {
        didSet { persist(skin.rawValue, key: Self.skinKey, oldValue: oldValue.rawValue) }
    }

    var transparency: MenuBarTransparency {
        didSet {
            persist(
                transparency.rawValue,
                key: Self.transparencyKey,
                oldValue: oldValue.rawValue
            )
        }
    }

    var glow: MenuBarGlow {
        didSet { persist(glow.rawValue, key: Self.glowKey, oldValue: oldValue.rawValue) }
    }

    var colorMode: AppAppearanceMode {
        didSet {
            persist(
                colorMode.rawValue,
                key: Self.colorModeKey,
                oldValue: oldValue.rawValue
            )
        }
    }

    var previewBackground: AppearancePreviewBackground {
        didSet {
            persist(
                previewBackground.rawValue,
                key: Self.previewBackgroundKey,
                oldValue: oldValue.rawValue
            )
        }
    }

    var preferences: AppearancePreferences {
        AppearancePreferences(
            skin: skin,
            transparency: transparency,
            glow: glow,
            colorMode: colorMode
        )
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        skin = userDefaults.string(forKey: Self.skinKey)
            .flatMap(MenuBarSkin.init(rawValue:))
            ?? .softGlow
        transparency = userDefaults.string(forKey: Self.transparencyKey)
            .flatMap(MenuBarTransparency.init(rawValue:))
            ?? .system
        glow = userDefaults.string(forKey: Self.glowKey)
            .flatMap(MenuBarGlow.init(rawValue:))
            ?? .subtle
        colorMode = userDefaults.string(forKey: Self.colorModeKey)
            .flatMap(AppAppearanceMode.init(rawValue:))
            ?? .system
        previewBackground = userDefaults.string(forKey: Self.previewBackgroundKey)
            .flatMap(AppearancePreviewBackground.init(rawValue:))
            ?? .detailed
    }

    private func persist(_ value: String, key: String, oldValue: String) {
        guard value != oldValue else {
            return
        }
        userDefaults.set(value, forKey: key)
    }
}

enum MenuBarMaterialRole: Equatable, Sendable {
    case ultraThin
    case thin
    case regular
    case thick
    case opaque
}

struct MenuBarAccessibilityEnvironment: Equatable, Sendable {
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var differentiateWithoutColor: Bool
    var reduceMotion: Bool

    static let standard = Self(
        reduceTransparency: false,
        increaseContrast: false,
        differentiateWithoutColor: false,
        reduceMotion: false
    )
}

struct ResolvedMenuBarAppearance: Equatable, Sendable {
    var materialRole: MenuBarMaterialRole
    var tintOpacity: Double
    var borderOpacity: Double
    var shadowOpacity: Double
    var glow: MenuBarGlow
    var usesEmphasizedControls: Bool
    var allowsMotion: Bool
}

enum MenuBarAppearanceResolver {
    static func resolve(
        preferences: AppearancePreferences,
        accessibility: MenuBarAccessibilityEnvironment
    ) -> ResolvedMenuBarAppearance {
        let base = baseAppearance(for: preferences.skin)
        var resolved = ResolvedMenuBarAppearance(
            materialRole: material(
                for: preferences.transparency,
                skinDefault: base.materialRole
            ),
            tintOpacity: base.tintOpacity,
            borderOpacity: base.borderOpacity,
            shadowOpacity: base.shadowOpacity,
            glow: effectiveGlow(preferences.glow, for: preferences.skin),
            usesEmphasizedControls: accessibility.increaseContrast,
            allowsMotion: !accessibility.reduceMotion
        )

        if accessibility.reduceTransparency {
            // 系统的“降低透明度”优先级高于用户皮肤选择，但不覆写已保存的偏好。
            resolved.materialRole = .opaque
            resolved.tintOpacity = 0
            resolved.borderOpacity = 0.72
            resolved.shadowOpacity = 0.2
            resolved.glow = .off
        }

        if accessibility.increaseContrast {
            resolved.borderOpacity = max(resolved.borderOpacity, 0.78)
            resolved.glow = .off
        }

        if accessibility.differentiateWithoutColor {
            resolved.usesEmphasizedControls = true
            resolved.borderOpacity = max(resolved.borderOpacity, 0.64)
        }

        return resolved
    }

    private static func baseAppearance(
        for skin: MenuBarSkin
    ) -> (
        materialRole: MenuBarMaterialRole,
        tintOpacity: Double,
        borderOpacity: Double,
        shadowOpacity: Double
    ) {
        switch skin {
        case .crystalAir:
            (.ultraThin, 0.05, 0.58, 0.12)
        case .softGlow:
            (.regular, 0.075, 0.44, 0.18)
        case .focusedFrost:
            // Focused Frost is the high-readability option. A semantic opaque
            // surface stays stable over busy desktops and mirrors the spec's
            // "near opaque" allowance without sampling the wallpaper.
            (.opaque, 0.02, 0.6, 0.24)
        }
    }

    private static func material(
        for transparency: MenuBarTransparency,
        skinDefault: MenuBarMaterialRole
    ) -> MenuBarMaterialRole {
        switch transparency {
        case .system:
            skinDefault
        case .clear:
            .ultraThin
        case .substantial:
            .thick
        }
    }

    private static func effectiveGlow(
        _ requestedGlow: MenuBarGlow,
        for skin: MenuBarSkin
    ) -> MenuBarGlow {
        guard skin == .focusedFrost, requestedGlow == .prominent else {
            return requestedGlow
        }

        // 聚焦磨砂以可读性为先，即使用户选择明显柔光，也只使用克制级别。
        return .subtle
    }
}
