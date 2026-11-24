import SwiftUI

/// The glass remote's Up next card (the local player's card, smaller): from the credits on while casting an
/// episode with a next one, or a film in collection mode; "Starts in 12s", Play now / Cancel. At the end the TV
/// loads the next item by itself (CastSessionNext.swift).
struct CastUpNextCard: View {
    @ObservedObject var cast: CastSession
    @EnvironmentObject var emby: Emby

    var body: some View {
        if let n = cast.upNext {
            HStack(spacing: Glass3DTokens.Space.m) {
                CachedImage(url: image(n)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous))
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                    Text(CastContinue.heading(n, collection: cast.collection)).cvFont(12, weight: .semibold)
                        .foregroundColor(Glass3DTokens.Grey.secondary)
                    Text(CastContinue.title(n, collection: cast.collection)).cvFont(14, weight: .semibold)
                        .lineLimit(2).frame(maxWidth: 240, alignment: .leading)
                    Text("Starts in \(cast.secsLeft)s").cvFont(11).monospacedDigit().foregroundColor(Glass3DTokens.Grey.secondary)
                    HStack(spacing: Glass3DTokens.Space.s) {
                        Button { cast.playNextNow() } label: {
                            Text("Play now").cvFont(13, weight: .bold).foregroundColor(.black)
                                .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.s).background(Capsule().fill(Color.white))
                        }.buttonStyle(HoverButton())
                        Button { cast.cancelUpNext() } label: {
                            Text("Cancel").cvFont(13, weight: .semibold)
                                .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.s).background(Capsule().fill(Color.white.opacity(0.15)))
                        }.buttonStyle(HoverButton())
                    }
                }
            }
            .foregroundColor(.white)
            .padding(Glass3DTokens.Space.m)
            .modifier(PanelSurface(classic: true))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 820, alignment: .trailing)
            .padding(.horizontal, 24).padding(.bottom, Glass3DTokens.Space.s)
            .transition(.coveGlassPopIn)
        }
    }

    private func image(_ n: Item) -> URL? {
        cast.collection != nil ? emby.image(n.backdropId ?? n.Id, n.backdropId != nil ? "Backdrop" : "Primary", width: 400)
            : emby.image(n.Id, "Primary", width: 400, plain: true)
    }
}
