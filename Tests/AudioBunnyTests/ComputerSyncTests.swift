import XCTest
@testable import AudioBunny

final class APIComputerDecodingTests: XCTestCase {
    func testDecodesWithoutLastSyncedAt() throws {
        let json = """
        {"id": 1, "name": "Alex's MacBook Pro", "plugin_count": 42}
        """.data(using: .utf8)!
        let computer = try JSONDecoder().decode(APIComputer.self, from: json)
        XCTAssertEqual(computer.id, 1)
        XCTAssertEqual(computer.name, "Alex's MacBook Pro")
        XCTAssertEqual(computer.pluginCount, 42)
        XCTAssertNil(computer.lastSyncedAt)
    }

    func testDecodesWithLastSyncedAt() throws {
        let json = """
        {"id": 2, "name": "Studio Mac", "plugin_count": 10, "last_synced_at": "2026-01-02T03:04:05Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let computer = try decoder.decode(APIComputer.self, from: json)
        XCTAssertNotNil(computer.lastSyncedAt)
    }

    func testComputerPluginIdIsFormatAndCaseIndependentIdentity() throws {
        let json = """
        {"name": "Serum", "manufacturer": "Xfer Records", "plugin_type": "VST 3", "version": "1.3"}
        """.data(using: .utf8)!
        let plugin = try JSONDecoder().decode(APIComputerPlugin.self, from: json)
        XCTAssertEqual(plugin.id, "vst 3|xfer records|serum")
    }

    func testDecodesComputerPluginWithRegistryFields() throws {
        let json = """
        {"id": 7, "plugin_id": 12, "name": "Pro-Q 3", "manufacturer": "FabFilter",
         "plugin_type": "Audio Unit", "category": null, "version": null}
        """.data(using: .utf8)!
        let plugin = try JSONDecoder().decode(APIComputerPlugin.self, from: json)
        XCTAssertEqual(plugin.name, "Pro-Q 3")
        XCTAssertNil(plugin.version)
    }
}

final class PluginSyncPayloadTests: XCTestCase {
    func testPayloadIncludesFormatVersionAndCategory() {
        let plugin = AudioPlugin(name: "Serum", manufacturer: "Xfer Records", type: .vst3,
                                 fileURL: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3/Serum.vst3"),
                                 version: "1.3", category: .instrument)
        XCTAssertEqual(APIClient.pluginSyncPayload([plugin]), [[
            "name": "Serum", "manufacturer": "Xfer Records", "plugin_type": "VST 3",
            "version": "1.3", "category": "instrument",
        ]])
    }

    func testPayloadSendsBlanksForUnknownVersionAndCategory() {
        let plugin = AudioPlugin(name: "Odd", manufacturer: "", type: .vst2,
                                 fileURL: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST/Odd.vst"))
        let payload = APIClient.pluginSyncPayload([plugin])
        XCTAssertEqual(payload.first?["version"], "")
        XCTAssertEqual(payload.first?["category"], "")
    }
}

@MainActor
final class ComputerSyncManagerTests: XCTestCase {
    func testIsThisComputerMatchesByHostname() {
        let manager = ComputerSyncManager()
        let mine = APIComputer(id: 1, name: ComputerIdentity.name, pluginCount: 5, lastSyncedAt: nil)
        let other = APIComputer(id: 2, name: "Some Other Mac", pluginCount: 3, lastSyncedAt: nil)

        XCTAssertTrue(manager.isThisComputer(mine))
        XCTAssertFalse(manager.isThisComputer(other))
    }
}
