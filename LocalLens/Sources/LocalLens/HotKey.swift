import Carbon.HIToolbox
import Foundation

/// Globaler Hotkey via Carbon RegisterEventHotKey — braucht KEINE Accessibility-Berechtigung
/// und belastet das System praktisch nicht (nur ein registrierter Kurzbefehl beim System).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    /// keyCode = kVK_ANSI_… ; modifiers = cmdKey|shiftKey|controlKey|optionKey
    init?(keyCode: Int, modifiers: Int, onFire: @escaping () -> Void) {
        self.onFire = onFire
        let id = HotKey.nextID; HotKey.nextID += 1
        HotKey.instances[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.instances[hkID.id]?.onFire()
            return noErr
        }, 1, &spec, nil, &handler)

        let hkID = EventHotKeyID(signature: OSType(0x4C4C4E53) /* 'LLNS' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
