import AppKit
import Carbon.HIToolbox
import Foundation

protocol HotkeyDelegate: AnyObject {
    func hotkeyPressed()                    // Fn gedrückt → sofort Aufnahme starten (PTT)
    func hotkeyReleased(heldFor: TimeInterval)  // Fn losgelassen → PTT-Stop oder Freihand-Entscheidung
    func handsFreeRequested()               // Fn+Space während PTT-Aufnahme → zu Freihand
    func startHandsFree()                   // Modifier+Space im Ruhezustand → Freihand-Aufnahme starten
    func stopDictation()                    // Space allein während Freihand → beenden & transkribieren
    func cancelRequested()                  // Esc während Aufnahme
    func pasteLastRequested()               // Cmd+Ctrl+V
    var isCapturing: Bool { get }           // true solange aufgenommen wird (steuert Event-Konsum)
    var isHandsFree: Bool { get }           // true im Freihand-Modus (Space allein beendet dann)
}

/// Globaler Hotkey über einen aktiven CGEventTap (braucht Accessibility-Berechtigung).
/// Fn ist ein Modifier: er kommt als .flagsChanged mit keyCode 63 und Flag .maskSecondaryFn.
final class HotkeyManager {
    /// Unterstützte Modifier-Hotkeys: (Keycode im flagsChanged-Event, zugehöriges Flag)
    struct ModifierKey {
        let keyCode: Int64
        let flag: CGEventFlags
        static let fn = ModifierKey(keyCode: 63, flag: .maskSecondaryFn)
        static let rightOption = ModifierKey(keyCode: 61, flag: .maskAlternate)
        static let rightCommand = ModifierKey(keyCode: 54, flag: .maskCommand)

        static func named(_ name: String) -> ModifierKey {
            switch name {
            case "rightOption": return .rightOption
            case "rightCommand": return .rightCommand
            default: return .fn
            }
        }
    }

    weak var delegate: HotkeyDelegate?

    private let hotkey: ModifierKey
    private let enableControlSpace: Bool
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnHeld = false
    private var fnPressedAt: Date?
    private var safetyTimer: Timer?
    private let maxHold: TimeInterval

    // Wenn eine Leertaste geschluckt wurde, auch das zugehörige KeyUp schlucken (kein Leerzeichen).
    private var consumeNextSpaceUp = false

    init(maxHold: TimeInterval, hotkey: ModifierKey = .fn, enableControlSpace: Bool = true) {
        self.maxHold = maxHold + 5
        self.hotkey = hotkey
        self.enableControlSpace = enableControlSpace
    }

    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo!).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("CGEventTap konnte nicht erstellt werden — Accessibility-Berechtigung fehlt?")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Hotkey-Tap aktiv")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Tap-Resiliency: macOS deaktiviert Taps bei Timeouts still — wieder aktivieren.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resetFnState()
            return nil
        }
        // Eigene synthetische Events (Cmd+V vom TextInserter) nie anfassen.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .flagsChanged where keyCode == hotkey.keyCode:
            let pressed = flags.contains(hotkey.flag)
            if pressed && !fnHeld {
                fnHeld = true
                fnPressedAt = Date()
                startSafetyTimer()
                DispatchQueue.main.async { self.delegate?.hotkeyPressed() }
                return nil    // Fn schlucken → kein Emoji-Picker
            } else if !pressed && fnHeld {
                let held = fnPressedAt.map { Date().timeIntervalSince($0) } ?? 0
                resetFnState()
                DispatchQueue.main.async { self.delegate?.hotkeyReleased(heldFor: held) }
                return nil
            }
            return nil        // Autorepeat/Duplikate ebenfalls schlucken

        case .keyDown:
            let capturing = delegate?.isCapturing ?? false
            let handsFree = delegate?.isHandsFree ?? false
            let ctrlOnly = flags.contains(.maskControl)
                && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate)

            // Cmd+Ctrl+V → letztes Transkript einfügen (wie Wispr)
            if keyCode == KeyCodeResolver.vKeyCode,
               flags.contains(.maskCommand), flags.contains(.maskControl), !flags.contains(.maskAlternate) {
                DispatchQueue.main.async { self.delegate?.pasteLastRequested() }
                return nil
            }

            // Leertaste ist das Herzstück der Freihand-Bedienung:
            //   Modifier+Space (Fn+Space / Ctrl+Space)  → Freihand-Aufnahme starten
            //   Space allein während Freihand           → beenden
            if keyCode == kVK_Space {
                if capturing {
                    if handsFree {                          // Space beendet Freihand
                        consumeNextSpaceUp = true
                        DispatchQueue.main.async { self.delegate?.stopDictation() }
                        return nil
                    }
                    if fnHeld {                             // Fn+Space während PTT → Freihand
                        consumeNextSpaceUp = true
                        DispatchQueue.main.async { self.delegate?.handsFreeRequested() }
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                } else if fnHeld || (enableControlSpace && ctrlOnly) {
                    consumeNextSpaceUp = true               // Modifier+Space → Freihand starten
                    DispatchQueue.main.async { self.delegate?.startHandsFree() }
                    return nil
                }
                return Unmanaged.passUnretained(event)      // normale Leertaste
            }

            guard capturing else { return Unmanaged.passUnretained(event) }

            if keyCode == kVK_Escape {
                DispatchQueue.main.async { self.delegate?.cancelRequested() }
                return nil
            }
            // Andere Taste während Fn-PTT (z. B. Fn+Pfeil): Diktat abbrechen, Event durchlassen.
            if fnHeld && !handsFree {
                resetFnState()
                DispatchQueue.main.async { self.delegate?.cancelRequested() }
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            if keyCode == kVK_Space && consumeNextSpaceUp {
                consumeNextSpaceUp = false
                return nil            // KeyUp der geschluckten Leertaste ebenfalls schlucken
            }
            if (delegate?.isCapturing ?? false) && keyCode == kVK_Escape {
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func resetFnState() {
        fnHeld = false
        fnPressedAt = nil
        DispatchQueue.main.async { [weak self] in
            self?.safetyTimer?.invalidate()
            self?.safetyTimer = nil
        }
    }


    /// macOS kann flagsChanged-Events verlieren → nach maxHold+5 s ein Release erzwingen.
    private func startSafetyTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.safetyTimer?.invalidate()
            self.safetyTimer = Timer.scheduledTimer(withTimeInterval: self.maxHold, repeats: false) { [weak self] _ in
                guard let self, self.fnHeld else { return }
                Log.error("Safety-Timer: Fn-Release verloren, erzwinge Stop")
                let held = self.fnPressedAt.map { Date().timeIntervalSince($0) } ?? self.maxHold
                self.resetFnState()
                self.delegate?.hotkeyReleased(heldFor: held)
            }
        }
    }
}

/// Löst den Keycode für „V" auf dem AKTIVEN Layout auf (Keycode 9 hartkodiert bricht auf Nicht-QWERTY).
enum KeyCodeResolver {
    static let vKeyCode: Int64 = resolve(character: "v") ?? 9

    static func resolve(character: Character) -> Int64? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> Int64? in
            guard let layoutPtr = rawPtr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for keyCode: UInt16 in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let err = UCKeyTranslate(layoutPtr, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                         UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                         &deadKeyState, chars.count, &length, &chars)
                if err == noErr, length > 0,
                   let scalar = Unicode.Scalar(chars[0]), Character(scalar) == character {
                    return Int64(keyCode)
                }
            }
            return nil
        }
    }
}
