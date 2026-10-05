import XCTest
@testable import AudioBunny

final class CatalogDeveloperURLTests: XCTestCase {
    private func decode(_ json: String) throws -> CatalogPlugin? {
        let api = try JSONDecoder().decode(APIPlugin.self, from: Data(json.utf8))
        return CatalogPlugin(api: api)
    }

    func testManufacturerUrlMapsToDeveloperURL() throws {
        let plugin = try decode("""
        {"id":1,"name":"Dexed","manufacturer":"Digital Suburban","plugin_type":"AU",
         "category":"instrument","website_url":"https://example.com/dexed",
         "manufacturer_url":"https://example.com","is_free":true,"favorited":false}
        """)
        XCTAssertEqual(plugin?.developerURL, "https://example.com")
    }

    func testMissingManufacturerUrlIsNil() throws {
        let plugin = try decode("""
        {"id":2,"name":"Dexed","manufacturer":"Digital Suburban","plugin_type":"AU",
         "category":"instrument","is_free":true,"favorited":false}
        """)
        XCTAssertNil(plugin?.developerURL)
    }
}
