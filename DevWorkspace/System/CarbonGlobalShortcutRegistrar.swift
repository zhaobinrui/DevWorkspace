import Carbon.HIToolbox

@MainActor
final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering {
    private static let hotKeySignature: OSType = 0x44565753 // "DVWS"

    private let registrationStorage = CarbonRegistrationStorage()
    private var action: (@MainActor () -> Void)?

    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @MainActor () -> Void
    ) throws {
        try installEventHandlerIfNeeded()

        var candidateRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: 1
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &candidateRef
        )

        guard status == noErr, let candidateRef else {
            if status == eventHotKeyExistsErr {
                throw GlobalShortcutRegistrationError.conflict
            }
            throw GlobalShortcutRegistrationError.systemFailure(status)
        }

        // Register the replacement before releasing the old hot key. On conflict, this preserves
        // the last known-good entry point instead of leaving a hidden menu-bar app unreachable.
        if let hotKeyRef = registrationStorage.hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        registrationStorage.hotKeyRef = candidateRef
        action = handler
    }

    fileprivate func invoke() {
        action?()
    }

    private func installEventHandlerIfNeeded() throws {
        guard registrationStorage.eventHandlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handleCarbonGlobalShortcut,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &registrationStorage.eventHandlerRef
        )

        guard status == noErr else {
            throw GlobalShortcutRegistrationError.systemFailure(status)
        }
    }

}

// Carbon exposes opaque C pointers that Swift does not mark Sendable. Normal mutation stays on the
// main actor; this small owner exists only so deterministic C cleanup remains legal from deinit.
private final class CarbonRegistrationStorage: @unchecked Sendable {
    var eventHandlerRef: EventHandlerRef?
    var hotKeyRef: EventHotKeyRef?

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

private func handleCarbonGlobalShortcut(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let registrar = Unmanaged<CarbonGlobalShortcutRegistrar>
        .fromOpaque(userData)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        registrar.invoke()
    }
    return noErr
}

private extension ShortcutModifiers {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
