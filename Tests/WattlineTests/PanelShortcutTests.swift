import Carbon
import Foundation
import XCTest
@testable import Wattline

final class PanelShortcutTests: XCTestCase {
    @MainActor
    private func commandW(_ layoutID: String) throws -> UInt32? {
        let properties = [kTISPropertyInputSourceID: "com.apple.keylayout." + layoutID] as CFDictionary
        let sources = TISCreateInputSourceList(properties, true)?.takeRetainedValue() as? [TISInputSource]
        guard let source = sources?.first, let data = PanelShortcut.keyLayoutData(source) else {
            throw XCTSkip("This Mac does not provide the \(layoutID) keyboard layout.")
        }
        return PanelShortcut.commandW(in: data, keyboardType: UInt32(LMGetKbdType()))
    }

    @MainActor
    func testFrenchAndDvorakCommandKeyPositions() async throws {
        XCTAssertEqual(try commandW("French"), UInt32(kVK_ANSI_Z))
        XCTAssertEqual(try commandW("Dvorak"), UInt32(kVK_ANSI_Comma))
    }

    @MainActor
    func testCommandLayerOverridesTypingLayer() async throws {
        XCTAssertEqual(try commandW("DVORAK-QWERTYCMD"), UInt32(kVK_ANSI_W))
    }

    @MainActor
    func testMissingLayoutDataDoesNotInventAKeyCode() async {
        XCTAssertNil(PanelShortcut.commandW(in: Data() as CFData, keyboardType: 40))
    }
}
