import Carbon.HIToolbox
import CoreGraphics

/// Finds which physical key types a given character in the user's current keyboard layout.
/// A synthetic ⌘V has to press the key that *is* V on this keyboard: on Dvorak the key in the
/// QWERTY V position types K, so a hard-coded key code 9 sends ⌘K instead of a paste.
@MainActor
enum KeyboardLayout {
    /// Carbon key code for ANSI V, used when the layout can't be read (or has no V at all).
    static let ansiV: CGKeyCode = 9

    private static var cache: (layoutID: String, keyCode: CGKeyCode)?

    /// Key code that produces "v" unmodified in the current layout.
    static func keyCode(for character: Character = "v") -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return ansiV }
        let layoutID = stringProperty(source, kTISPropertyInputSourceID) ?? ""
        if let cache, cache.layoutID == layoutID, character == "v" { return cache.keyCode }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return ansiV }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        let found: CGKeyCode? = data.withUnsafeBytes { bytes in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
        let code = found ?? ansiV
        if character == "v" { cache = (layoutID, code) }
        return code
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
