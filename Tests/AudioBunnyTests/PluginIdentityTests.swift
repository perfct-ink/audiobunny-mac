import XCTest
import AudioToolbox
@testable import AudioBunny

final class PluginIdentityTests: XCTestCase {

    // MARK: auCodeString

    func testAUCodeStringPreservesAllFourBytesIncludingSpaces() {
        // 'aumu'
        XCTAssertEqual(auCodeString(0x61756D75), "aumu")
        // 'out ' — trailing space must survive (unlike the display formatter)
        XCTAssertEqual(auCodeString(0x6F757420), "out ")
    }

    // MARK: identityKey

    private func au(name: String, manufacturer: String = "M",
                    desc: AudioComponentDescription? = nil) -> AudioPlugin {
        AudioPlugin(name: name, manufacturer: manufacturer, type: .audioUnit,
                    fileURL: URL(fileURLWithPath: "/tmp/\(name).component"),
                    version: "1.0", componentDescription: desc)
    }

    func testAudioUnitIdentityIsItsCodesNotItsPath() {
        var desc = AudioComponentDescription()
        desc.componentType = 0x61756D75      // 'aumu'
        desc.componentSubType = 0x4E696638   // 'Nif8'
        desc.componentManufacturer = 0x2D4E492D // '-NI-'

        let a = au(name: "FM8", desc: desc)
        let b = AudioPlugin(name: "FM8 renamed", manufacturer: "x", type: .audioUnit,
                            fileURL: URL(fileURLWithPath: "/somewhere/else.component"),
                            version: "9", componentDescription: desc)

        // Same component codes → same identity regardless of name or location.
        XCTAssertEqual(a.identityKey, b.identityKey)
        XCTAssertEqual(a.identityKey, "au:aumu/Nif8/-NI-")
    }

    func testTwoComponentsSharingOneBundleGetDistinctIdentities() {
        var instrument = AudioComponentDescription()
        instrument.componentType = 0x61756D75      // 'aumu'
        instrument.componentSubType = 0x4E696638
        instrument.componentManufacturer = 0x2D4E492D
        var midiFX = instrument
        midiFX.componentType = 0x61756D66          // 'aumf'

        // Both are the FM8 bundle, but must not collapse into one row.
        XCTAssertNotEqual(au(name: "FM8", desc: instrument).identityKey,
                          au(name: "FM8 MFX", desc: midiFX).identityKey)
    }

    func testAudioUnitWithoutDescriptionFallsBackToNameAndManufacturer() {
        // e.g. a bundle found only in the Disabled folder, with no live component.
        let p = au(name: "SausageFattener", manufacturer: "Dada Life")
        XCTAssertEqual(p.identityKey, "au:sausagefattener|dada life")
    }

    func testVSTIdentityIsItsBundlePath() {
        let p = AudioPlugin(name: "Serum", manufacturer: "Xfer", type: .vst3,
                            fileURL: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3/Serum.vst3"),
                            version: "1.0")
        XCTAssertEqual(p.identityKey, "VST 3:/Library/Audio/Plug-Ins/VST3/Serum.vst3")
    }

    // MARK: canOpen ("Open Plugin" — AU only, and never for a disabled plugin)

    func testCanOpenIsTrueForAudioUnitsRegardlessOfTestStatus() {
        for status: PluginStatus in [.untested, .active, .failed("x"), .timedOut, .testing] {
            let p = au(name: "FM8")
            p.status = status
            XCTAssertTrue(p.canOpen, "status \(status) should still allow opening the AU")
        }
    }

    func testCanOpenIsFalseForDisabledAudioUnits() {
        let p = au(name: "FM8")
        p.status = .disabled
        XCTAssertFalse(p.canOpen)
    }

    func testCanOpenIsFalseForVSTFormats() {
        let vst2 = AudioPlugin(name: "Serum", manufacturer: "Xfer", type: .vst2,
                               fileURL: URL(fileURLWithPath: "/tmp/Serum.vst"), version: "1.0")
        let vst3 = AudioPlugin(name: "Serum", manufacturer: "Xfer", type: .vst3,
                               fileURL: URL(fileURLWithPath: "/tmp/Serum.vst3"), version: "1.0")
        XCTAssertFalse(vst2.canOpen)
        XCTAssertFalse(vst3.canOpen)
    }
}
