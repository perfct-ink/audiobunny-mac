import XCTest
@testable import AudioBunny

final class WaveformCacheTests: XCTestCase {
    private var dir: URL!
    private var sources: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBunnyWFCache-\(UUID().uuidString)")
        dir = root.appendingPathComponent("cache")
        sources = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func makeSource(_ name: String, bytes: Int = 1_000) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private func waveform(_ n: Int = 480, seed: Int = 0) -> Waveform {
        Waveform(sampleRate: 44_100, samplesPerPixel: 256,
                 samples: (0..<(n * 2)).map { Int8(truncatingIfNeeded: $0 + seed) })
    }

    func testStoreThenLoadRoundTrips() async throws {
        let cache = WaveformCache(directory: dir)
        let src = try makeSource("a.wav")
        let wf = waveform()

        await cache.store(wf, sourceURL: src)
        let loaded = await cache.load(sourceURL: src)

        XCTAssertEqual(loaded, wf)
    }

    func testWrittenFileIsAValidAudiowaveformDat() async throws {
        let cache = WaveformCache(directory: dir)
        let src = try makeSource("a.wav")
        await cache.store(waveform(), sourceURL: src)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let dat = try XCTUnwrap(files.first { $0.hasSuffix(".dat") })
        let data = try Data(contentsOf: dir.appendingPathComponent(dat))
        let decoded = try XCTUnwrap(AudioWaveformData.decode(data))
        XCTAssertEqual(decoded.pixelCount, 480)
        XCTAssertEqual([UInt8](data.prefix(4)), [2, 0, 0, 0])   // version 2, LE
    }

    func testMissForUnknownSource() async throws {
        let cache = WaveformCache(directory: dir)
        let loaded = await cache.load(sourceURL: sources.appendingPathComponent("nope.wav"))
        XCTAssertNil(loaded)
    }

    func testChangingTheSourceInvalidatesAndReplacesTheEntry() async throws {
        let cache = WaveformCache(directory: dir)
        let src = try makeSource("a.wav", bytes: 1_000)
        await cache.store(waveform(seed: 1), sourceURL: src)
        let firstHit = await cache.load(sourceURL: src)
        XCTAssertNotNil(firstHit)

        // Rewrite the source with a different size — old entry is now stale.
        try Data(repeating: 0xCD, count: 2_000).write(to: src)
        let staleHit = await cache.load(sourceURL: src)
        XCTAssertNil(staleHit, "stale entry must not be served")

        await cache.store(waveform(seed: 2), sourceURL: src)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".dat") }
        XCTAssertEqual(files.count, 1, "the stale entry for the same source should be purged")
    }

    func testEvictionKeepsCacheUnderBudget() async throws {
        // One 480-pixel entry is 24 + 960 = 984 bytes; budget holds ~3.
        let cache = WaveformCache(directory: dir, byteBudget: 3_000)

        for i in 0..<10 {
            let src = try makeSource("s\(i).wav")
            await cache.store(waveform(seed: i), sourceURL: src)
            try await Task.sleep(for: .milliseconds(5))   // keep mtimes ordered for LRU
        }

        let size = await cache.sizeBytes()
        XCTAssertLessThanOrEqual(size, 3_000)
        XCTAssertGreaterThan(size, 0)

        // The most recently stored survives; the first is gone.
        let newest = await cache.load(sourceURL: sources.appendingPathComponent("s9.wav"))
        let oldest = await cache.load(sourceURL: sources.appendingPathComponent("s0.wav"))
        XCTAssertNotNil(newest)
        XCTAssertNil(oldest)
    }

    func testClearEmptiesTheCache() async throws {
        let cache = WaveformCache(directory: dir)
        await cache.store(waveform(), sourceURL: try makeSource("a.wav"))
        await cache.clear()

        let size = await cache.sizeBytes()
        XCTAssertEqual(size, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
    }
}
