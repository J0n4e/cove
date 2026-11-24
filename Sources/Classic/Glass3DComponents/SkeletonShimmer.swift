import SwiftUI

/// Page / section loading: rounded placeholder blocks with a slow light sweep (static with Reduce Motion). Small
/// spinners stay only inside buttons and rows. Like `Spinner`, draws nothing while a video plays (pages behind the
/// player can show through it).
struct SkeletonShimmer: View {
    /// rows: list-shaped blocks; posters: poster-shaped blocks that wrap like the poster grids (Library, Home rows)
    enum Layout { case rows, posters }
    var layout: Layout = .rows
    var rows: Int = 3
    /// Poster blocks: their size and the grid spacing (the poster grid's)
    var poster = CGSize(width: 150, height: 225)
    var posterSpacing: CGFloat = Glass3DTokens.Space.l
    var rowHeight: CGFloat = 56
    var spacing: CGFloat = Glass3DTokens.Space.m
    var radius: CGFloat = Glass3DTokens.Radius.card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = PlaybackFlag.shared
    @State private var phase: CGFloat = 0

    /// x offset of the light band (half the width wide) for a sweep phase 0…1: from fully left of the blocks to
    /// fully right of them.
    static func bandOffset(phase: CGFloat, width: CGFloat) -> CGFloat {
        let p = min(1, max(0, phase))
        return -width * 0.5 + p * width * 1.5
    }
    /// Number of blocks drawn (at least one).
    static func blockCount(_ rows: Int) -> Int { max(1, rows) }

    var body: some View {
        if playback.active { EmptyView() } else {
            blocks
                .foregroundStyle(Color.white.opacity(0.06))
                .overlay {
                    if Glass3DTokens.Motion.allowsLoop(reduceMotion: reduceMotion) {
                        GeometryReader { g in
                            LinearGradient(colors: [.clear, Color.white.opacity(0.08), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: g.size.width * 0.5)
                                .offset(x: Self.bandOffset(phase: phase, width: g.size.width))
                        }
                        .mask(blocks)
                        .onAppear {
                            phase = 0
                            withAnimation(.linear(duration: Glass3DTokens.Motion.shimmerPeriod).repeatForever(autoreverses: false)) {
                                phase = 1
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Loading")
                .skeletonCrossfade()   // fades out as the content fades in (Motion.standard)
        }
    }

    @ViewBuilder private var blocks: some View {
        switch layout {
        case .rows:
            VStack(spacing: spacing) {
                ForEach(0..<Self.blockCount(rows), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: radius, style: .continuous).frame(height: rowHeight)
                }
            }
        case .posters:
            // Wraps to the width it gets (a fixed row of posters would widen the page)
            LazyVGrid(columns: Self.posterColumns(poster.width, spacing: posterSpacing), alignment: .leading,
                      spacing: posterSpacing) {
                ForEach(0..<Self.blockCount(rows), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous)
                        .frame(width: poster.width, height: poster.height)
                }
            }
        }
    }

    /// The poster skeleton's grid: as the poster grids, fixed-width columns as many as fit.
    static func posterColumns(_ width: CGFloat, spacing: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: width, maximum: width), spacing: spacing, alignment: .topLeading)]
    }
}
