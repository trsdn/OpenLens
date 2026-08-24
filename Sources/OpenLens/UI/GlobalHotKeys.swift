import Carbon.HIToolbox
import Foundation

/// System-wide ⌥1…⌥9 for switching scenes and ⌥P for pausing.
///
/// The menu-bar shortcuts only fire while OpenLens is frontmost, which is never
/// the case during a call — the whole point is to re-frame yourself without
/// leaving Zoom. `RegisterEventHotKey` is used rather than an `NSEvent` global
/// monitor because it needs no Accessibility permission and works from inside
/// the sandbox.
@MainActor
final class GlobalHotKeys {
    /// Called with a zero-based scene index.
    var onSelect: ((Int) -> Void)?
    /// Called for ⌥P.
    var onTogglePause: (() -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x4F4C_4E53)  // 'OLNS'

    /// `kVK_ANSI_1`…`kVK_ANSI_9`, which are not in numeric order.
    private static let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// `kVK_ANSI_P`, registered under an id past the end of `keyCodes`.
    private static let pauseKeyCode: UInt32 = 35
    private static let pauseHotKeyID = UInt32(100)

    private static weak var active: GlobalHotKeys?

    func register() {
        guard handler == nil else { return }
        Self.active = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr, hotKeyID.signature == GlobalHotKeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let active = GlobalHotKeys.active else { return }
                        if id == GlobalHotKeys.pauseHotKeyID {
                            active.onTogglePause?()
                        } else {
                            active.onSelect?(Int(id))
                        }
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
        guard status == noErr else { return }

        for (index, keyCode) in Self.keyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let registered = RegisterEventHotKey(
                keyCode,
                UInt32(optionKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if registered == noErr, let ref { refs.append(ref) }
        }

        var pauseRef: EventHotKeyRef?
        let pauseRegistered = RegisterEventHotKey(
            Self.pauseKeyCode,
            UInt32(optionKey),
            EventHotKeyID(signature: Self.signature, id: Self.pauseHotKeyID),
            GetApplicationEventTarget(),
            0,
            &pauseRef
        )
        if pauseRegistered == noErr, let pauseRef { refs.append(pauseRef) }
    }

    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        if Self.active === self { Self.active = nil }
    }

    deinit {
        for ref in refs { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
