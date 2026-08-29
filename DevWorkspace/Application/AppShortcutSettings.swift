import Foundation
import Observation

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let control = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)

    static let supported: ShortcutModifiers = [
        .command,
        .option,
        .control,
        .shift,
    ]
    static let activation: ShortcutModifiers = [.command, .option, .control]
}

struct GlobalShortcut: Codable, Hashable, Sendable {
    static let defaultWorkspace = GlobalShortcut(
        keyCode: 13,
        key: "W",
        modifiers: [.command, .option, .control]
    )

    let keyCode: UInt32
    let key: String
    let modifiers: ShortcutModifiers

    var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + key
    }

    var isValid: Bool {
        keyCode <= UInt16.max
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modifiers.intersection(.activation).isEmpty
            && modifiers.subtracting(.supported).isEmpty
    }
}

enum GlobalShortcutRegistrationError: Error, Equatable, Sendable {
    case conflict
    case systemFailure(Int32)
}

@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    /// A failed replacement must leave the previously registered shortcut active.
    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @MainActor () -> Void
    ) throws
}

enum ShortcutRegistrationIssue: Equatable, Sendable {
    case conflict(GlobalShortcut)
    case systemFailure(Int32)
}

@MainActor
@Observable
final class AppShortcutSettings {
    static let menuBarIconVisibleKey = "shortcut.menuBarIconVisible"
    static let keyCodeKey = "shortcut.keyCode"
    static let keyLabelKey = "shortcut.keyLabel"
    static let modifiersKey = "shortcut.modifiers"

    private(set) var shortcut: GlobalShortcut
    private(set) var registrationIssue: ShortcutRegistrationIssue?
    private(set) var isShortcutRegistered = false

    var isMenuBarIconVisible: Bool {
        didSet {
            guard isMenuBarIconVisible != oldValue else {
                return
            }
            userDefaults.set(
                isMenuBarIconVisible,
                forKey: Self.menuBarIconVisibleKey
            )
        }
    }

    var effectiveMenuBarIconVisibility: Bool {
        // Never strand the user without an entry point when the saved shortcut cannot be registered.
        isMenuBarIconVisible || !isShortcutRegistered
    }

    private let registrar: any GlobalShortcutRegistering
    private let userDefaults: UserDefaults
    private let onInvoke: @MainActor () -> Void

    init(
        registrar: any GlobalShortcutRegistering,
        userDefaults: UserDefaults = .standard,
        onInvoke: @escaping @MainActor () -> Void
    ) {
        self.registrar = registrar
        self.userDefaults = userDefaults
        self.onInvoke = onInvoke
        shortcut = Self.restoreShortcut(from: userDefaults)
        isMenuBarIconVisible = userDefaults.object(
            forKey: Self.menuBarIconVisibleKey
        ) as? Bool ?? true

        activateStoredShortcut()
    }

    @discardableResult
    func apply(_ candidate: GlobalShortcut) -> Bool {
        guard candidate.isValid else {
            registrationIssue = .systemFailure(-50)
            return false
        }

        if candidate == shortcut, isShortcutRegistered {
            registrationIssue = nil
            return true
        }

        do {
            try registrar.register(candidate, handler: onInvoke)
            shortcut = candidate
            isShortcutRegistered = true
            registrationIssue = nil
            persistShortcut(candidate)
            return true
        } catch GlobalShortcutRegistrationError.conflict {
            registrationIssue = .conflict(candidate)
        } catch let GlobalShortcutRegistrationError.systemFailure(status) {
            registrationIssue = .systemFailure(status)
        } catch {
            registrationIssue = .systemFailure(-1)
        }

        return false
    }

    func resetToDefault() {
        apply(.defaultWorkspace)
    }

    private func activateStoredShortcut() {
        do {
            try registrar.register(shortcut, handler: onInvoke)
            isShortcutRegistered = true
        } catch GlobalShortcutRegistrationError.conflict {
            registrationIssue = .conflict(shortcut)
        } catch let GlobalShortcutRegistrationError.systemFailure(status) {
            registrationIssue = .systemFailure(status)
        } catch {
            registrationIssue = .systemFailure(-1)
        }

        if !isShortcutRegistered, !isMenuBarIconVisible {
            // Persist the recovery choice so a launch-time conflict cannot hide the only usable entry point.
            isMenuBarIconVisible = true
        }
    }

    private func persistShortcut(_ shortcut: GlobalShortcut) {
        userDefaults.set(Int(shortcut.keyCode), forKey: Self.keyCodeKey)
        userDefaults.set(shortcut.key, forKey: Self.keyLabelKey)
        userDefaults.set(Int(shortcut.modifiers.rawValue), forKey: Self.modifiersKey)
    }

    private static func restoreShortcut(from userDefaults: UserDefaults) -> GlobalShortcut {
        guard
            let keyCodeNumber = userDefaults.object(forKey: keyCodeKey) as? NSNumber,
            let key = userDefaults.string(forKey: keyLabelKey),
            let modifiersNumber = userDefaults.object(forKey: modifiersKey) as? NSNumber
        else {
            return .defaultWorkspace
        }

        let shortcut = GlobalShortcut(
            keyCode: keyCodeNumber.uint32Value,
            key: key,
            modifiers: ShortcutModifiers(rawValue: modifiersNumber.uint32Value)
        )
        return shortcut.isValid ? shortcut : .defaultWorkspace
    }
}
