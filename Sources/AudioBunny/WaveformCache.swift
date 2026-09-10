import Foundation
import CryptoKit

// MARK: - BBC audiowaveform binary format (.dat, version 2)

/// Little-endian, from https://github.com/bbc/audiowaveform DataFormat.md:
/// ```
///  0  int32   version = 2
///  4  uint32  flags       (bit 0: 1 = 8-bit samples, 0 = 16-bit)
///  8  int32   sample_rate
/// 12  int32   samples_per_pixel
/// 16  uint32  length      (number of min/max pairs)
/// 20  int32   channels
/// 24  …       interleaved signed min/max pairs, `length × channels × 2` values
/// ```
/// AudioBunny only ever writes 8-bit / single-channel; the reader also accepts
/// 16-bit (down-scaled) so hand-supplied files still load.
enum AudioWaveformData {
    static let headerSize = 24

    static func encode(_ waveform: Waveform) -> Data {
        var data = Data(capacity: headerSize + waveform.samples.count)
        data.appendLE(Int32(2))                          // version
        data.appendLE(UInt32(1))                         // flags: 8-bit
        data.appendLE(Int32(waveform.sampleRate))
        data.appendLE(Int32(waveform.samplesPerPixel))
        data.appendLE(UInt32(waveform.pixelCount))       // length (pairs)
        data.appendLE(Int32(1))                          // channels
        waveform.samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ data: Data) -> Waveform? {
        guard data.count >= headerSize,
              data.readLE(Int32.self, at: 0) == 2 else { return nil }
        let flags = data.readLE(UInt32.self, at: 4)
        let sampleRate = Int(data.readLE(Int32.self, at: 8))
        let samplesPerPixel = Int(data.readLE(Int32.self, at: 12))
        let length = Int(data.readLE(UInt32.self, at: 16))
        let channels = Int(data.readLE(Int32.self, at: 20))
        guard channels == 1, length > 0 else { return nil }

        let eightBit = (flags & 1) == 1
        let bytesPerSample = eightBit ? 1 : 2
        guard data.count == headerSize + length * 2 * bytesPerSample else { return nil }

        let sampleCount = length * 2
        var samples = [Int8](repeating: 0, count: sampleCount)
        if eightBit {
            data.withUnsafeBytes { raw in
                _ = samples.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress, raw.baseAddress!.advanced(by: headerSize), sampleCount)
                }
            }
        } else {
            for i in 0..<samples.count {
                samples[i] = Int8(clamping: Int(data.readLE(Int16.self, at: headerSize + i * 2)) / 256)
            }
        }
        return Waveform(sampleRate: sampleRate, samplesPerPixel: samplesPerPixel, samples: samples)
    }
}

// MARK: - Cache

/// Persists computed waveforms as BBC `audiowaveform` `.dat` files, capped at a
/// byte budget with least-recently-used eviction (by cache-file modification
/// date, refreshed on every hit).
///
/// The `.dat` format has no room for source-file validation, so staleness is
/// encoded in the filename — `<sha256(path)>_<size>_<mtimeMillis>.dat`. A sample
/// that's been edited or replaced simply produces a different name (a miss), and
/// the orphaned entry ages out via LRU.
actor WaveformCache {
    static let shared = WaveformCache()

    private let directory: URL
    private let byteBudget: Int
    private var knownTotalBytes: Int?

    init(directory: URL? = nil, byteBudget: Int = 100 * 1024 * 1024) {
        self.byteBudget = byteBudget
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("AudioBunny/waveforms", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: Public

    func load(sourceURL: URL) -> Waveform? {
        guard let stat = sourceStat(sourceURL) else { return nil }
        let entry = entryURL(hash: hash(sourceURL), size: stat.size, mtimeMillis: stat.mtimeMillis)
        guard let data = try? Data(contentsOf: entry),
              let waveform = AudioWaveformData.decode(data) else { return nil }
        touch(entry)
        return waveform
    }

    func store(_ waveform: Waveform, sourceURL: URL) {
        guard waveform.pixelCount > 0, let stat = sourceStat(sourceURL) else { return }
        let digest = hash(sourceURL)
        let entry = entryURL(hash: digest, size: stat.size, mtimeMillis: stat.mtimeMillis)

        // Drop any older entry for the same source (different size/mtime).
        var reclaimed = 0
        for stale in entries() where stale.url.lastPathComponent.hasPrefix("\(digest)_")
            && stale.url != entry {
            reclaimed += stale.size
            try? FileManager.default.removeItem(at: stale.url)
        }

        let data = AudioWaveformData.encode(waveform)
        let previous = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard (try? data.write(to: entry, options: .atomic)) != nil else { return }

        var total = knownTotalBytes ?? scanTotalBytes()
        total += data.count - previous - reclaimed
        knownTotalBytes = total
        if total > byteBudget { evictToBudget() }
    }

    func clear() {
        for url in (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        knownTotalBytes = 0
    }

    func sizeBytes() -> Int { knownTotalBytes ?? scanTotalBytes() }

    // MARK: Private

    private func hash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func entryURL(hash: String, size: Int64, mtimeMillis: Int64) -> URL {
        directory.appendingPathComponent("\(hash)_\(size)_\(mtimeMillis).dat")
    }

    private func sourceStat(_ url: URL) -> (size: Int64, mtimeMillis: Int64)? {
        // FileManager, not URL.resourceValues — the latter caches on the URL
        // instance, so a caller reusing one URL wouldn't see the file change.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return (size, Int64((mtime.timeIntervalSince1970 * 1000).rounded()))
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func entries() -> [(url: URL, size: Int, mtime: Date)] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            guard url.pathExtension == "dat",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let mtime = values.contentModificationDate else { return nil }
            return (url, size, mtime)
        }
    }

    private func scanTotalBytes() -> Int {
        let total = entries().reduce(0) { $0 + $1.size }
        knownTotalBytes = total
        return total
    }

    private func evictToBudget() {
        let target = byteBudget * 9 / 10   // hysteresis so we don't evict on every write near the cap
        var remaining = entries().sorted { $0.mtime < $1.mtime }   // oldest first
        var total = remaining.reduce(0) { $0 + $1.size }
        while total > target, !remaining.isEmpty {
            let victim = remaining.removeFirst()
            try? FileManager.default.removeItem(at: victim.url)
            total -= victim.size
        }
        knownTotalBytes = total
    }
}

// MARK: - Little-endian fixed-width helpers

private extension Data {
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        T(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
