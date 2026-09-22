import Testing
import CoreGraphics

struct YapperKeyTests {
    @Test func rightOptionIsTheDefault() {
        #expect(YapperKey.default == .rightOption)
    }

    @Test func deviceMasksDistinguishSides() {
        // Left option held (0x20) must not read as the right one (0x40).
        let leftOnly = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        let rightOnly = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        #expect(!YapperKey.rightOption.isDown(leftOnly))
        #expect(YapperKey.rightOption.isDown(rightOnly))
        #expect(YapperKey.rightCommand.isDown(CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)))
        #expect(!YapperKey.rightCommand.isDown(CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)))
        #expect(YapperKey.rightControl.isDown(CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)))
        #expect(YapperKey.fn.isDown(.maskSecondaryFn))
        #expect(!YapperKey.fn.isDown([]))
    }

    @Test func keyCodesMatchCarbon() {
        #expect(YapperKey.rightOption.keyCode == 61)
        #expect(YapperKey.fn.keyCode == 63)
        #expect(YapperKey.rightControl.keyCode == 62)
        #expect(YapperKey.rightCommand.keyCode == 54)
    }

    @Test func everyKeySaysWhatItTakesFromTheApp() {
        for key in YapperKey.allCases { #expect(key.caveat?.isEmpty == false) }
        #expect(YapperKey.rightOption.caveat?.contains("→") == true)
    }
}
