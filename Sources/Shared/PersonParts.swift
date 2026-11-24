import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

// MARK: - Person

struct PersonRef: Hashable { let id: String; let name: String }

/// Top of an actor's page: a dimmed backdrop from one of their titles, a large portrait,
/// and the name, birth facts, title counts and biography beside it, sized to fill the width.
struct PersonHeader: View {
    @Environment(\.classicGlass) private var classic   // the main window: glass frame
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let id: String
    let name: String
    let record: Item?
    let items: [Item]
    let loading: Bool

    var bio: String { record?.Overview ?? "" }
    var backdrop: Item? { items.first { $0.backdropId != nil } }

    /// "Born 12 March 1970 · Bucharest, Romania" (and "Died …" when the server has it).
    var facts: String {
        func day(_ s: String?) -> String? {
            guard let s, let d = ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z") else { return nil }
            return d.formatted(date: .long, time: .omitted)
        }
        var f: [String] = []
        if let b = day(record?.PremiereDate) { f.append("Born " + b) }
        if let place = record?.ProductionLocations?.first, !place.isEmpty { f.append(place) }
        if let d = day(record?.EndDate) { f.append("Died " + d) }
        return f.joined(separator: " · ")
    }

    @ViewBuilder func chip(_ text: String) -> some View {
        if classic {
            // Glass3D: glass like the buttons, but still (it is not a button: no hover glow)
            Text(text).cvFont(13, weight: .semibold).foregroundColor(.white).padding(.horizontal, 14).frame(minHeight: 30)
                .modifier(ClassicClearGlass(shape: Capsule(), interactive: false))
        } else {
            Text(text).coveFont(size: 13, weight: .semibold)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15)))
        }
    }

    var body: some View {
        let movies = items.filter { !$0.isSeries }.count, shows = items.filter { $0.isSeries }.count
        ZStack(alignment: .bottomLeading) {
            // Backdrop: one of their titles, faded into the page
            Color.clear.frame(height: 460).frame(maxWidth: .infinity)
                .overlay {
                    if let b = backdrop {
                        Backdrop(id: b.backdropId ?? b.Id, width: 1600).opacity(0.45)
                    }
                }
                .clipped()
                .overlay(LinearGradient(colors: [bg.opacity(0.2), bg.opacity(0.75), bg], startPoint: .top, endPoint: .bottom))
            // Photo top lines up with the name
            HStack(alignment: .top, spacing: 36) {
                CachedImage(url: emby.image(id, width: 480)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").coveFont(size: 70).foregroundColor(.secondary) }
                }
                .frame(width: 280, height: 420).clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel))
                // Favorite: heart top left when it is one, heart button bottom right on hover (as on cast photos)
                .overlay(alignment: .topLeading) {
                    if emby.isPersonFav(id) {
                        FavHeart(size: 20).padding(12)
                    }
                }
                .modifier(HoverPersonHeart(id: id, name: name))
                .task { _ = await emby.favoritePeople() }   // knows whether this person is a favorite
                .modifier(PersonPhotoFrame(classic: classic))   // Glass3D: the glass card frame
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 12) {
                    Text(name).coveFont { s in let f = TextScale.scaledSize(base: 42, scale: s); return classic ? .cv(f, weight: .bold) : .system(size: f, weight: .bold) }.lineLimit(2)
                    if !facts.isEmpty { Text(facts).coveFont(size: 15).foregroundColor(.secondary) }
                    HStack(spacing: 8) {
                        if !loading {
                            if movies > 0 { chip("\(movies) Movie\(movies == 1 ? "" : "s")") }
                            if shows > 0 { chip("\(shows) Show\(shows == 1 ? "" : "s")") }
                        }
                    }
                    if !bio.isEmpty {
                        Text(bio).coveFont(size: 15).lineSpacing(4).foregroundColor(.white.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: 820, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 52).padding(.top, 90)
        }
    }
}
