import MoonlightCommonC
import Testing
@testable import MoonlightMac

@Test func ordinaryKeysUseNormalizedProtocolMapping() throws {
    for code: UInt16 in [0x00, 0x06, 0x10, 0x27, 0x29, 0x2A, 0x0A] {
        let key = try #require(KeycodeMappings.hostKey(macKeyCode: code))
        #expect(key.flags == 0)
        #expect(UInt16(bitPattern: key.wireCode) & 0x8000 != 0)
    }
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x06)?.virtualKey == 0x5A) // physical Z
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x10)?.virtualKey == 0x59) // physical Y
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x0A)?.virtualKey == 0xE2) // ISO extra key
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x5D)?.flags == CChar(SS_KBE_FLAG_NON_NORMALIZED))
}

@Test func keypadAndMainEnterRemainDistinct() throws {
    let main = try #require(KeycodeMappings.hostKey(macKeyCode: 0x24))
    let keypad = try #require(KeycodeMappings.hostKey(macKeyCode: 0x4C))
    #expect(main.virtualKey == keypad.virtualKey)
    #expect(!main.extended)
    #expect(keypad.extended)
    #expect(main != keypad) // key-up bookkeeping must distinguish these
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x52)?.virtualKey == 0x60)
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x5C)?.virtualKey == 0x69)
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x4B)?.extended == true)
}

@Test func rightModifiersRetainExtendedFlagAfterRemapping() throws {
    let altGr = try #require(KeycodeMappings.hostKey(macKeyCode: 0x3D, swapWinAltKeys: false))
    #expect(altGr.virtualKey == KeycodeMappings.VK_RMENU)
    #expect(altGr.extendedModifier == CChar(MODIFIER_EXTENDED))
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x3E)?.extended == true)
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x3B)?.extended == false)
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x36, swapWinAltKeys: true)?.virtualKey == KeycodeMappings.VK_RMENU)
    #expect(KeycodeMappings.hostKey(macKeyCode: 0x7B)?.extended == true)
}
