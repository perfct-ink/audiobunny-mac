import Foundation

// MARK: - Sample tag vocabulary + auto-tagging (pure, testable)

/// The tag vocabulary offered for samples. A sample is auto-tagged with any of
/// these whose name appears in its filename or its parent folder name.
let sampleTagVocabulary: [String] = [
    "Kick", "Snare", "HiHat", "Toms", "Crash", "Ride", "Cymbals", "Percussion",
    "Drum Loop", "Woodwind", "Brass", "Strings", "FX", "Guitar", "Bass", "Synth",
    "Vocal", "Glitch", "Pads", "Stabs",
]

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
