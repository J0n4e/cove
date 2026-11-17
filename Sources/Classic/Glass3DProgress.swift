import SwiftUI

// TEMP: owner compares, remove the loser before release
// Two ways to show how far a partly watched item got on a Glass3D thumbnail (Continue Watching, episode rows and
// tiles), switched by Settings → General → Progress style (@AppStorage("progressStyle"), "ring" or "glow").
// Once the owner picks one, delete the other view, the setting and `ProgressStyle`.

enum ProgressStyle {
    // TEMP: owner compares, remove the loser before release
    static let key = "progressStyle"
    static let ring = "ring"
    static let glow = "glow"
    static let choices: [(String, String)] = [(ring, "Ring"), (glow, "Glow")]

    /// The trimmed share of the ring / border: the watched fraction clamped to 0…1; nil (draw nothing) for an
    /// unstarted or finished item, or a value that isn't a number.
    static func trimFraction(_ fraction: Double) -> CGFloat? {
        guard fraction.isFinite, fraction > 0, fraction < 1 else { return nil }
        return CGFloat(min(1, max(0, fraction)))
    }

    /// Where the glowing border starts: the middle of the top edge, so it fills clockwise like a clock hand
    /// (and like the ring), symmetric on any card width.
    static func borderStart(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.minY)
    }

    /// Room the ring takes in the bottom-right corner (its size plus its inset), so the title beside it stops short.
    static let ringSize: CGFloat = 36
    static let ringInset: CGFloat = 8
    static var ringClearance: CGFloat { ringSize + ringInset + 4 }
}

/// A rounded rectangle traced clockwise from the middle of its top edge (see `ProgressStyle.borderStart`), so
/// `.trim(from: 0, to: f)` fills from there. SwiftUI's own RoundedRectangle path starts elsewhere.
struct TopCenterRoundedBorder: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: ProgressStyle.borderStart(in: rect))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// The progress mark on a thumbnail in the chosen style. Put it in an `.overlay` over the thumbnail.
// TEMP: owner compares, remove the loser before release
struct ThumbnailProgress: View {
    let fraction: Double
    /// The thumbnail's corner radius (the glow follows it)
    let radius: CGFloat
    @AppStorage(ProgressStyle.key) private var style = ProgressStyle.ring
    var body: some View {
        if let f = ProgressStyle.trimFraction(fraction) {
            if style == ProgressStyle.glow {
                ThumbnailProgressGlow(fraction: f, radius: radius)
            } else {
                ThumbnailProgressRing(fraction: f)
                    .padding(ProgressStyle.ringInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}

/// RING: a small glass circle with ▶ inside and an accent ring around it filling clockwise from the top.
/// Decorative: the card itself opens / plays.
struct ThumbnailProgressRing: View {
    let fraction: CGFloat
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        let size = ProgressStyle.ringSize
        ZStack {
            Circle().fill(Color.black.opacity(0.45))
            Circle().fill(Color.white.opacity(Glass3DTokens.Fill.strong))
            Circle().strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75)
            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                .offset(x: 1)   // optical centre of the triangle
            Circle().inset(by: 1.5).stroke(Color.white.opacity(0.18), lineWidth: 3)   // faint full track
            Circle().inset(by: 1.5).trim(from: 0, to: fraction)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))   // start at the top, run clockwise
        }
        .frame(width: size, height: size)
        .g3Shadow(Glass3DTokens.shadowSmall)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// GLOW: an accent line running clockwise along the thumbnail's rounded edge from the middle of the top, with a
/// soft accent glow and a faint full-border track.
struct ThumbnailProgressGlow: View {
    let fraction: CGFloat
    let radius: CGFloat
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        let line: CGFloat = 2.5
        let shape = TopCenterRoundedBorder(radius: max(0, radius - line / 2))
        ZStack {
            shape.stroke(Color.white.opacity(0.18), lineWidth: line)
            shape.trim(from: 0, to: fraction)
                .stroke(accent, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(0.9), radius: 5)
        }
        .padding(line / 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The title next to the ring stops short of it (Ring style only).
struct ProgressRingClearance: ViewModifier {
    let active: Bool
    @AppStorage(ProgressStyle.key) private var style = ProgressStyle.ring
    func body(content: Content) -> some View {
        content.padding(.trailing, active && style != ProgressStyle.glow ? ProgressStyle.ringClearance - 10 : 0)
    }
}
