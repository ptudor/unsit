import Foundation

/// Escape only for display. Filesystem names and archive bytes stay unchanged.
func display(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 92: result += "\\\\"
        case 10: result += "\\n"
        case 13: result += "\\r"
        case 9: result += "\\t"
        case 0...31, 127...159, 0x2028, 0x2029, 0x202a...0x202e, 0x2066...0x2069:
            result += "\\u{\(String(scalar.value, radix: 16))}"
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result
}
