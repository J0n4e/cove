import SwiftUI
import AppKit

// Classic theme font (Settings → General → Font). Every text style in the Classic screens goes through `Font.cv`,
// so one choice changes the type everywhere: titles, buttons, rows, tooltips, lists.

enum ClassicFont {
    /// (setting value, name shown in Settings). Fonts that ship with macOS; SF Pro is the default.
    static let choices: [(String, String)] = [
        ("standard", "SF Pro (macOS default)"), ("rounded", "SF Rounded"), ("expanded", "SF Pro Expanded"),
        ("avenir", "Avenir Next"), ("futura", "Futura"), ("serif", "New York"), ("seravek", "Seravek"),
    ]
    static let defaultValue = "standard"
    /// Removed choices (Helvetica Neue, Gill Sans, Optima) and anything unknown fall back to SF Pro.
    static func normalized(_ value: String?) -> String {
        guard let v = value, choices.contains(where: { $0.0 == v }) else { return defaultValue }
        return v
    }
    static var current: String { normalized(UserDefaults.standard.string(forKey: "classicFont")) }
    /// Once at launch: a stored removed choice becomes SF Pro, so Settings shows what is used.
    static func migrate() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: "classicFont"), normalized(v) != v { d.set(defaultValue, forKey: "classicFont") }
    }
    /// Seravek normally ships with macOS; when it's missing, SF Pro.
    static let hasSeravek = NSFont(name: "Seravek", size: 12) != nil

    static func font(_ size: CGFloat, _ weight: Font.Weight, _ choice: String = current) -> Font {
        switch normalized(choice) {
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        case "expanded": return .system(size: size, weight: weight).width(.expanded)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "avenir": return .custom("Avenir Next", size: size).weight(weight)
        case "futura": return .custom("Futura", size: size).weight(weight)
        case "seravek": return hasSeravek ? .custom("Seravek", size: size).weight(weight) : .system(size: size, weight: weight)
        default: return .system(size: size, weight: weight)
        }
    }
}

/// Settings → General → Font: a live sample of the chosen font.
struct ClassicFontPreview: View {
    let choice: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Cove").font(ClassicFont.font(22, .bold, choice))
            Text("Continue watching · S18:E12 · 4:42 left").font(ClassicFont.font(13, .regular, choice))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: choice)
        .accessibilityHidden(true)
    }
}

extension Font {
    /// The Classic theme's font at this size and weight. Views use `.cvFont(size, weight:)`, which passes the size
    /// through the text-size setting (TextScale.swift) first.
    static func cv(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { ClassicFont.font(size, weight) }
}

extension ClassicFont {
    /// The same font for AppKit text (the AppKit poster grid's labels).
    static func nsFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let name: String?
        switch current {
        case "avenir": name = "Avenir Next"
        case "helvetica": name = "Helvetica Neue"
        case "futura": name = "Futura"
        case "gill": name = "Gill Sans"
        case "optima": name = "Optima"
        default: name = nil
        }
        if let name, let f = NSFont(name: name, size: size) {
            return NSFontManager.shared.convert(f, toHaveTrait: weight >= .semibold ? .boldFontMask : [])
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign = current == "standard" ? .default : current == "serif" ? .serif : .rounded
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}
