import SwiftUI

// Classic theme font (Settings → General → Font). Every text style in the Classic screens goes through `Font.cv`,
// so one choice changes the type everywhere: titles, buttons, rows, tooltips, lists.

enum ClassicFont {
    /// (setting value, name shown in Settings)
    static let choices: [(String, String)] = [
        ("rounded", "SF Rounded"), ("standard", "SF Pro"), ("serif", "New York"),
        ("avenir", "Avenir Next"), ("helvetica", "Helvetica Neue"), ("futura", "Futura"),
        ("gill", "Gill Sans"), ("optima", "Optima"),
    ]
    static var current: String { UserDefaults.standard.string(forKey: "classicFont") ?? "rounded" }

    static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        switch current {
        case "standard": return .system(size: size, weight: weight)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "avenir": return .custom("Avenir Next", size: size).weight(weight)
        case "helvetica": return .custom("Helvetica Neue", size: size).weight(weight)
        case "futura": return .custom("Futura", size: size).weight(weight)
        case "gill": return .custom("Gill Sans", size: size).weight(weight)
        case "optima": return .custom("Optima", size: size).weight(weight)
        default: return .system(size: size, weight: weight, design: .rounded)
        }
    }
}

extension Font {
    /// The Classic theme's font at this size and weight.
    static func cv(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { ClassicFont.font(size, weight) }
}
