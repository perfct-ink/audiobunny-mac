import Foundation

// MARK: - Sample tag vocabulary + auto-tagging (pure, testable)

/// The tag vocabulary offered for samples. A sample is auto-tagged with any of
/// these whose name appears in its filename or its parent folder name.
let sampleTagVocabulary: [String] = [
    "Kick", "Snare", "HiHat", "Toms", "Crash", "Ride", "Cymbals", "Percussion",
    "Drum Loop", "Woodwind", "Brass", "Strings", "FX", "Guitar", "Bass", "Synth",
    "Vocal", "Glitch", "Pads", "Stabs",
]

let sampleTagVocabularySet = Set(sampleTagVocabulary)

/// Words/spellings that should map onto a canonical tag but wouldn't match by a
/// plain substring test (e.g. "hi-hat" → "HiHat", "vox" → "Vocal").
private let tagAliases: [String: String] = [
    "hi hat": "HiHat", "hi-hat": "HiHat", "hats": "HiHat", "hat": "HiHat",
    "perc": "Percussion",
    "vox": "Vocal", "vocals": "Vocal",
    "gtr": "Guitar",
    "pad": "Pads",
    "stab": "Stabs",
    "loop": "Drum Loop",
    "sfx": "FX",
]

/// Tags implied by a sample's filename and the folder it sits in. Matching is
/// case- and separator-insensitive: "Trap_Kick_01.wav" in a "808 Kicks" folder
/// yields ["Kick"].
func autoTags(forFileName fileName: String, parentFolderName: String) -> Set<String> {
    let haystack = normalizeForTagMatch("\(fileName) \(parentFolderName)")
    var tags: Set<String> = []

    for tag in sampleTagVocabulary {
        if haystack.contains(normalizeForTagMatch(tag)) {
            tags.insert(tag)
        }
    }
    for (alias, canonical) in tagAliases {
        if haystack.contains(normalizeForTagMatch(alias)) {
            tags.insert(canonical)
        }
    }
    return tags
}

/// Lowercases and collapses separators (space, _, -, .) to single spaces, so
/// "Hi-Hat", "hi_hat" and "HI HAT" all compare equal.
private func normalizeForTagMatch(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""
    var lastWasSpace = false
    for ch in lowered {
        if ch == " " || ch == "_" || ch == "-" || ch == "." {
            if !lastWasSpace { out.append(" ") }
            lastWasSpace = true
        } else {
            out.append(ch)
            lastWasSpace = false
        }
    }
    return " \(out.trimmingCharacters(in: .whitespaces)) "
}

// MARK: - Finder Tags (the file's own metadata, not just AudioBunny's cache)

/// The subset of `url`'s Finder Tags that belong to our vocabulary. Reading is
/// just a resource-value fetch (no file content read), safe to call often.
func vocabularyFinderTags(at url: URL) -> Set<String> {
    let names = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    return Set(names).intersection(sampleTagVocabularySet)
}

/// Merges `desired` into `url`'s Finder Tags, preserving any tag outside our
/// vocabulary (the user's own Finder tags on that file are never touched).
/// A no-op — returns `false`, doesn't write — when the file's vocabulary tags
/// already match. Throws if the write itself fails, e.g. a read-only or
/// network volume.
@discardableResult
func syncFinderTags(desired: Set<String>, at url: URL) throws -> Bool {
    let existingAll = Set((try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
    let existingVocab = existingAll.intersection(sampleTagVocabularySet)
    guard existingVocab != desired else { return false }

    let foreign = existingAll.subtracting(sampleTagVocabularySet)
    // NSURL's untyped setter, not URLResourceValues.tagNames — the typed
    // property's setter is gated to a newer OS on some SDKs, but this one
    // (the mechanism Finder itself has used since Mavericks) is not.
    try (url as NSURL).setResourceValue(Array(foreign.union(desired)).sorted(), forKey: .tagNamesKey)
    return true
}

// MARK: - Duration formatting

/// A sample's length as `M:SS` (or `SS.d s` under 10 seconds), for the list.
func formatSampleDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    if seconds < 10 {
        return String(format: "%.1fs", seconds)
    }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
