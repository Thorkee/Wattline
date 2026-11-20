import AppKit
import Carbon
import Combine

@MainActor
final class PanelShortcut: NSObject, ObservableObject {
    @Published private(set) var isAvailable = false

    private static let signature: OSType = 0x57617474 // Watt
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var registeredCode: UInt32?
    private var handler: EventHandlerRef?

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init()

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<PanelShortcut>.fromOpaque(context).takeUnretainedValue()
                guard id.signature == PanelShortcut.signature, id.id == shortcut.registeredCode else {
                    return OSStatus(eventNotHandledErr)
                }
                shortcut.action()
                return noErr
            }
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refresh),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil
        )
        refresh()
    }

    @objc func refresh() {
        guard handler != nil else { return }
        let code = Self.currentKeyCode()
        if code == registeredCode, hotKey != nil { return }

        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredCode = nil
        if let code {
            let id = EventHotKeyID(signature: Self.signature, id: code)
            let modifiers = UInt32(controlKey | optionKey | cmdKey)
            if RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(),
                                   OptionBits(kEventHotKeyExclusive), &hotKey) == noErr {
                registeredCode = code
            }
        }
        let available = registeredCode != nil
        if isAvailable != available { isAvailable = available }
    }

    private static func currentKeyCode() -> UInt32? {
        let keyboardType = UInt32(LMGetKbdType())
        if let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = keyLayoutData(layout) {
            return commandW(in: data, keyboardType: keyboardType)
        }

        // Input methods without their own Unicode layout use the underlying
        // ASCII-capable layout. A concrete keyboard layout with no W stays unavailable.
        guard let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(selected, kTISPropertyInputSourceType),
              !CFEqual(Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue(), kTISTypeKeyboardLayout),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = keyLayoutData(ascii) else { return nil }
        return commandW(in: data, keyboardType: keyboardType)
    }

    static func keyLayoutData(_ source: TISInputSource) -> CFData? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    }

    static func commandW(in data: CFData, keyboardType: UInt32) -> UInt32? {
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        return withExtendedLifetime(data) {
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            // Command can select a distinct layout (for example, Dvorak–QWERTY ⌘).
            // Option and Control are shortcut modifiers; they can change the emitted character.
            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var character: UniChar = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8),
                                            keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState, 1, &length, &character)
                if status == noErr, length == 1, character == 0x77 || character == 0x57 {
                    return UInt32(code)
                }
            }
            return nil
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let handler { RemoveEventHandler(handler) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
    }
}
