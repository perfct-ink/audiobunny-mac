import XCTest
@testable import AudioBunny

final class FinderTagSyncTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBunnyFinderTagTest-\(UUID().uuidString).wav")
        try Data("x".utf8).write(to: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
        try super.tearDownWithError()
    }

    func testSyncWritesDesiredVocabTags() throws {
        XCTAssertTrue(try syncFinderTags(desired: ["Kick", "Snare"], at: url))
        XCTAssertEqual(vocabularyFinderTags(at: url), ["Kick", "Snare"])
    }

    func testSyncIsANoopWhenAlreadyMatching() throws {
        _ = try syncFinderTags(desired: ["Snare"], at: url)
        XCTAssertFalse(try syncFinderTags(desired: ["Snare"], at: url), "matching tags shouldn't trigger a write")
    }

    func testSyncPreservesForeignFinderTags() throws {
        try (url as NSURL).setResourceValue(["MyProject", "Kick"], forKey: .tagNamesKey)

        // Vocabulary tags change (Kick -> Snare); "MyProject" isn't ours and
        // must survive untouched.
        _ = try syncFinderTags(desired: ["Snare"], at: url)

        let all = Set((try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
        XCTAssertEqual(all, ["MyProject", "Snare"])
    }

    func testSyncRemovesAVocabTagNoLongerDesired() throws {
        _ = try syncFinderTags(desired: ["Kick", "Snare"], at: url)
        _ = try syncFinderTags(desired: ["Kick"], at: url)
        XCTAssertEqual(vocabularyFinderTags(at: url), ["Kick"])
    }

    func testVocabularyFinderTagsIgnoresNonVocabularyNames() throws {
        try (url as NSURL).setResourceValue(["Kick", "Client Deliverable"], forKey: .tagNamesKey)
        XCTAssertEqual(vocabularyFinderTags(at: url), ["Kick"])
    }

    func testVocabularyFinderTagsEmptyForUntaggedFile() {
        XCTAssertEqual(vocabularyFinderTags(at: url), [])
    }

    func testSyncThrowsWhenFileIsNotWritable() throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        XCTAssertThrowsError(try syncFinderTags(desired: ["Kick"], at: url))
    }
}
