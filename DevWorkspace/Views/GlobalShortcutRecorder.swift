import AppKit
import SwiftUI

struct GlobalShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut
    let recordingPrompt: String
    let accessibilityLabel: String
    let onRecorded: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton(
            shortcut: shortcut,
            recordingPrompt: recordingPrompt,
            accessibilityLabel: accessibilityLabel,
            onRecorded: onRecorded
        )
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.update(
            shortcut: shortcut,
            recordingPrompt: recordingPrompt,
            accessibilityLabel: accessibilityLabel,
            onRecorded: onRecorded
        )
    }
}

final class ShortcutRecorderButton: NSButton {
    private var shortcut: GlobalShortcut
    private var recordingPrompt: String
    private var onRecorded: (GlobalShortcut) -> Void
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    init(
        shortcut: GlobalShortcut,
        recordingPrompt: String,
        accessibilityLabel: String,
        onRecorded: @escaping (GlobalShortcut) -> Void
    ) {
        self.shortcut = shortcut
        self.recordingPrompt = recordingPrompt
        self.onRecorded = onRecorded
        super.init(frame: .zero)

        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        title = shortcut.displayName
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(shortcut.displayName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        shortcut: GlobalShortcut,
        recordingPrompt: String,
        accessibilityLabel: String,
        onRecorded: @escaping (GlobalShortcut) -> Void
    ) {
        self.shortcut = shortcut
        self.recordingPrompt = recordingPrompt
        self.onRecorded = onRecorded
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(shortcut.displayName)
        if !isRecording {
            title = shortcut.displayName
        }
    }

    @objc
    private func beginRecording() {
        isRecording = true
        title = recordingPrompt
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            finishRecording()
            return
        }

        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard
            !modifiers.intersection(.activation).isEmpty,
            let key = Self.keyLabel(for: event)
        else {
            NSSound.beep()
            return
        }

        let candidate = GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            key: key,
            modifiers: modifiers
        )
        onRecorded(candidate)
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        guard isRecording else {
            return
        }
        isRecording = false
        title = shortcut.displayName
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        let specialKeys: [UInt16: String] = [
            36: "↩",
            48: "⇥",
            49: "Space",
            51: "⌫",
            115: "Home",
            116: "Page Up",
            117: "⌦",
            119: "End",
            121: "Page Down",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
        ]
        if let specialKey = specialKeys[event.keyCode] {
            return specialKey
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        return characters.uppercased()
    }
}

private extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        let supportedFlags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if supportedFlags.contains(.command) { modifiers.insert(.command) }
        if supportedFlags.contains(.option) { modifiers.insert(.option) }
        if supportedFlags.contains(.control) { modifiers.insert(.control) }
        if supportedFlags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
