import SwiftUI

// MARK: - Plugin format badge colour (shared: My Plugins list + Discover catalog)

/// The badge colour for a plugin format, so the My Plugins list and the Discover
/// catalog render AU / VST2 / VST3 identically. Accepts both the short labels the
/// catalog stores ("AU", "VST2", "VST3") and `PluginType.rawValue`
/// ("Audio Unit", "VST 2", "VST 3").
func pluginFormatColor(_ format: String) -> Color {
    switch format.uppercased().replacingOccurrences(of: " ", with: "") {
    case "AU", "AUDIOUNIT": return .blue
    case "VST2", "VST":     return Color(red: 0.36, green: 0.16, blue: 0.56)
    case "VST3":            return Color(red: 0.68, green: 0.42, blue: 0.98)
    default:                return .secondary
    }
}

// MARK: - Separated rows (definition lists without a trailing rule)

/// A vertical stack of rows with hairline separators *between* rows only — never
/// a rule below the last row, which would otherwise double up against the edge
/// of an enclosing `GroupBox`.
struct SeparatedRows: View {
    let rows: [AnyView]

    init(rows: [AnyView]) {
        self.rows = rows
    }

    /// Convenience for a plain key/value list.
    init(pairs: [(String, String)], labelWidth: CGFloat = 140) {
        self.rows = pairs.map { label, value in
            AnyView(
                HStack(alignment: .top) {
                    Text(label)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                if i != 0 { Divider() }
                rows[i]
            }
        }
    }
}
