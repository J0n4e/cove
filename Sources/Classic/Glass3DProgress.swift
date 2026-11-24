import SwiftUI

// How far a partly watched item got on a Glass3D thumbnail (Continue Watching, episode rows and tiles): a glowing
// accent line along the thumbnail's bottom edge, plus a Resume button in the bottom-right corner (the glass play
// button with an accent ring filling clockwise from the top). The thumbnail's centre play button then plays from
// the beginning.

enum ProgressStyle {
    /// The watched fraction for the line / ring: clamped to 0…1; nil (draw nothing) for an unstarted or finished
    /// item, or a value that isn't a number.
    static func trimFraction(_ fraction: Double) -> CGFloat? {
        guard fraction.isFinite, fraction > 0, fraction < 1 else { return nil }
        return CGFloat(min(1, max(0, fraction)))
    }

    /// Width of the bottom glow line for a thumbnail `total` points wide (0 when nothing is drawn).
    static func lineWidth(_ fraction: Double, total: CGFloat) -> CGFloat {
        guard let f = trimFraction(fraction), total.isFinite, total > 0 else { return 0 }
        return total * f
    }

    /// Thickness of the bottom glow line.
    static let line: CGFloat = 2.5

    /// The Resume button in the bottom-right corner: its size, its inset from the right, and its inset from the
    /// bottom (higher, so it sits clear above the bottom glow line).
    static let ringSize: CGFloat = 36
    static let ringInset: CGFloat = 8
    static var ringBottomInset: CGFloat { ringInset }
    /// Room the ring takes, so the title beside it stops short.
    static var ringClearance: CGFloat { ringSize + ringInset + 4 }

    /// "0:45", "12:34", "1:02:03" for a saved position in seconds.
    static func timeText(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds)) : 0
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func resumeTip(_ seconds: Double) -> String { "Resume from " + timeText(seconds) }

    /// Where the centre play button starts: the beginning (0) for a partly watched item, else nil (the normal
    /// play path, as before).
    static func centreStart(hasProgress: Bool) -> Double? { hasProgress ? 0 : nil }
    /// The centre play button's tooltip (nil: unchanged).
    static func centreTip(hasProgress: Bool) -> String? { hasProgress ? "Play from the beginning" : nil }
    /// Where the ring (Resume) starts: the saved position.
    static func ringStart(resumeAt: Double) -> Double { max(0, resumeAt) }
}

/// The progress marks on a thumbnail: the bottom glow line and the Resume ring. Put it in an `.overlay` over the
/// thumbnail (inside its clip shape, so the line follows the rounded bottom corners).
struct ThumbnailProgress: View {
    let fraction: Double
    /// The saved position in seconds (the ring's tooltip)
    let resumeAt: Double
    let onResume: () -> Void
    var body: some View {
        if let f = ProgressStyle.trimFraction(fraction) {
            ZStack {
                // Only the Resume ring (owner): no bottom glow line
                ThumbnailResumeRing(fraction: f, resumeAt: resumeAt, onResume: onResume)
                    .padding(.trailing, ProgressStyle.ringInset)
                    .padding(.bottom, ProgressStyle.ringBottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}

/// A glowing accent line along the bottom edge, left to right, over a faint full-width track.
struct ThumbnailProgressLine: View {
    let fraction: CGFloat
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        return GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: ProgressStyle.line)
                Capsule().fill(accent)
                    .frame(width: ProgressStyle.lineWidth(Double(fraction), total: g.size.width), height: ProgressStyle.line)
                    .shadow(color: accent.opacity(0.9), radius: 5)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// RESUME: the thumbnail's glass play button (same `classicGlassPill` glass and hover) with an accent ring around
/// it filling clockwise from the top. Clicking it resumes from the saved position.
struct ThumbnailResumeRing: View {
    let fraction: CGFloat
    let resumeAt: Double
    let onResume: () -> Void
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        Button(action: onResume) { label.contentShape(Circle()) }
            .buttonStyle(.plainHand)
            .tip(ProgressStyle.resumeTip(resumeAt))
            .accessibilityLabel("Resume")
            // Like the centre Play button: while the pointer is on the ring, the card's lit border steps back
            .reportsThumbnailInnerHover()
    }
    var label: some View {
        Label("Resume", systemImage: "play.fill").classicGlassPill(size: ProgressStyle.ringSize)
            .overlay { RingArc(fraction: fraction, accent: Theme.accent(accentName)) }
    }
}

/// The same Resume ring as a static mark (no button), for thumbnails that are already one big button (library
/// posters, the player's Episodes panel). Replaces the old bottom progress lines (owner: ring only).
struct ResumeRingMark: View {
    let fraction: Double
    var size: CGFloat = ProgressStyle.ringSize
    var inset: CGFloat = ProgressStyle.ringInset
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        if let f = ProgressStyle.trimFraction(fraction) {
            Label("Resume", systemImage: "play.fill").classicGlassPill(size: size)
                .overlay { RingArc(fraction: f, accent: Theme.accent(accentName)) }
                .padding(.trailing, inset).padding(.bottom, inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The ring itself: a faint full track and the accent arc from the top, clockwise.
private struct RingArc: View {
    let fraction: CGFloat
    let accent: Color
    var body: some View {
        ZStack {
            Circle().inset(by: 1.5).stroke(Color.white.opacity(0.18), lineWidth: 3)
            Circle().inset(by: 1.5).trim(from: 0, to: fraction)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))   // start at the top, run clockwise
        }
        .allowsHitTesting(false)
    }
}

/// The title next to the ring stops short of it.
struct ProgressRingClearance: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.padding(.trailing, active ? ProgressStyle.ringClearance - 10 : 0)
    }
}
