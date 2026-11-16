import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

func endsAtText(_ t: Int64) -> String {
    Date().addingTimeInterval(Double(t) / 10_000_000).formatted(date: .omitted, time: .shortened)
}
func parseDate(_ s: String?) -> Date? {
    guard let s, s.count >= 19 else { return nil }
    return ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
}

struct CountBadge: View {
    let count: Int?
    @Environment(\.classicGlass) private var classic   // Classic theme: glass tube badges
    var body: some View {
        if classic, let n = count {
            TubeBadge(count: n == 0 ? nil : n)
                .helpLabel(n == 0 ? "All watched" : "\(n) unwatched episode\(n == 1 ? "" : "s")")
        } else if let n = count {
            if n == 0 {
                Image(systemName: "checkmark").coveFont(size: 12, weight: .heavy).foregroundColor(.white)
                    .frame(width: 24, height: 24).background(Circle().fill(WatchBadge.green)).overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 3).helpLabel("All watched")
            } else {
                Text(n > 99 ? "99+" : "\(n)").coveFont(size: 12, weight: .bold).foregroundColor(.white)
                    .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(WatchBadge.green)).overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .helpLabel("\(n) unwatched episode\(n == 1 ? "" : "s")")
            }
        }
    }
}

/// Top-right poster badge: green check when watched, unwatched-episode count for series.
/// Small white progress ring (how much of the episode you have watched), for the corner of a thumbnail.
struct ProgressRing: View {
    let progress: Double      // 0...1
    var size: CGFloat = 22
    /// Classic only: false draws the empty glass tube (the watched badge)
    var filled = true
    @Environment(\.classicGlass) private var classic   // Classic theme: a glass tube bent into a ring
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        if classic { tube } else { ring.shadow(color: .black.opacity(0.6), radius: 3) }
    }
    var trim: CGFloat { CGFloat(min(1, max(0.03, progress))) }
    var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 2.5)
            Circle().trim(from: 0, to: trim)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
    /// Light on a glass edge: bright at the top-left and bottom-right, fading along the sides (as the card frames).
    static let edgeLight = LinearGradient(stops: [.init(color: .white.opacity(0.85), location: 0),
                                                  .init(color: .white.opacity(0.12), location: 0.3),
                                                  .init(color: .white.opacity(0.06), location: 0.5),
                                                  .init(color: .white.opacity(0.12), location: 0.7),
                                                  .init(color: .white.opacity(0.85), location: 1)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)

    /// A glass ring like the card frames, filled with see-through accent color as far as the progress, with a
    /// highlight along the fill.
    var tube: some View {
        let w: CGFloat = 5               // tube thickness
        let d = size + 2                 // centerline diameter
        return ZStack {
            // glass pane ring, as the card frames: frosted body, edges lit at the top-left and bottom-right
            Circle().stroke(Color.white.opacity(0.14), lineWidth: w)
            Circle().stroke(Self.edgeLight, lineWidth: 0.9).frame(width: d + w, height: d + w)
            Circle().stroke(Self.edgeLight, lineWidth: 0.7).frame(width: d - w, height: d - w)
            // liquid: see-through accent fill with its own highlight, rounded ends
            if filled { Group {
                Circle().trim(from: 0, to: trim)
                    .stroke(Theme.accent(accentName).opacity(0.5), style: StrokeStyle(lineWidth: w - 1.2, lineCap: .round))
                Circle().trim(from: 0, to: trim)
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: d - 1.5, height: d - 1.5)
            }.rotationEffect(.degrees(-90)) }
        }
        .frame(width: d, height: d)
        .frame(width: d + w, height: d + w)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }
}

// MARK: - Detail / movie info

struct CastTile: View {
    @EnvironmentObject var emby: Emby
    let p: Full.Person
    @AppStorage("castSize") private var castSize = "normal"   // Settings → Libraries → Movie and show pages
    @State private var hover = false
    var body: some View {
        let big = castSize == "large"
        VStack(spacing: 6) {
            CachedImage(url: emby.image(p.Id, width: big ? 360 : 240)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack { Color(white: 0.18); Image(systemName: "person.fill").coveFont(size: big ? 44 : 30).foregroundColor(.secondary) }
            }
            // Large: a portrait photo card (2:3); Normal: the round photo
            .frame(width: big ? 132 : 88, height: big ? 198 : 88)
            .clipShape(RoundedRectangle(cornerRadius: big ? 10 : 44))
            .shadow(color: .black.opacity(big ? 0.45 : 0), radius: 6, y: 3)
            // Favorites show a small heart top left, as posters do
            .overlay(alignment: .topLeading) {
                if emby.isPersonFav(p.Id) {
                    FavHeart(size: 16).padding(big ? 8 : 2)
                }
            }
            // Favorite heart, bottom right on hover, as on posters
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    let fav = emby.isPersonFav(p.Id)
                    ItemActionsButton.circle(fav ? "heart.fill" : "heart", on: fav,
                                             help: fav ? "Remove from Favorites" : "Add to Favorites") {
                        Task { await emby.setFav(p.Id, !fav, name: p.Name) }
                    }.padding(big ? 8 : 0)
                }
            }
            .scrollHover($hover)
            .hoverLift()   // grows a little under the pointer, like posters
            Text(p.Name).font((big ? Font.callout : .caption).weight(.semibold)).lineLimit(1)
            Text(p.Role ?? p.`Type` ?? "").font(big ? .caption : .caption2).foregroundColor(.secondary).lineLimit(1)
        }.frame(width: CastTile.width(castSize)).multilineTextAlignment(.center)
    }
    /// Tile width for "normal" or "large" (the Cast & Crew row spaces its tiles by this)
    static func width(_ size: String) -> CGFloat { size == "large" ? 152 : 104 }
}

struct DetailView: View {
    @Environment(\.noBack) private var noBack
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let item: Item
    /// The page's data, loading and Play decisions, shared with the other theme
    @StateObject private var model: DetailModel

    init(item: Item) {
        self.item = item
        _model = StateObject(wrappedValue: DetailModel(item: item))
    }
    @AppStorage("episodeSubLang") private var epSubLang = ""
    @AppStorage("subAlways") private var subAlwaysOn = false
    @AppStorage("subLang") private var prefSubLang = "english"
    /// First entry of the Subtitles menu: the preferred language when that setting is on, otherwise Off.
    var defaultSubLabel: String { subAlwaysOn ? prefSubLang.capitalized : "Off" }
    @AppStorage("episodeLayoutTV") private var epLayout = "row"
    @AppStorage("seasonLayoutTV") private var seasonLayout = "row"   // Seasons posters: "row" (scrolls sideways) or "grid"
    @AppStorage("showEpisodeDescription") private var showEpDesc = true   // Settings → Libraries → Series
    @AppStorage("similarLayout") private var similarLayout = "row"   // "row", "grid" or "list"; also in Settings → Libraries

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header.id("pageTop")
                    pickers
                    if item.isSeries { episodesList }
                    if item.isBox { boxGrid }
                    castSection.task { _ = await emby.favoritePeople() }   // hearts on the cast photos
                    aboutSection
                    includedInSection
                    similarSection
                }.padding(.bottom, 50)
            }
            // Switching views adds or removes the Seasons posters above the episodes (row view has none), which
            // pushed the episodes and the view buttons out of sight on long shows: go back to the top of the page
            .onChange(of: epLayout) {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("pageTop", anchor: .top) }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(bg)
        .task { model.bind(emby); await model.load() }
        .onChange(of: model.srcIdx) { model.sourceChanged() }
        .onChange(of: model.season) { model.seasonChanged() }
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: noBack ? nil : { dismiss() }) }
        .hideToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
    }


    /// "Movie · Action · Drama", like Apple TV.
    var kindLine: String {
        let kind = item.isSeries ? "TV Show" : item.isEpisode ? "Episode" : item.isBox ? "Collection" : "Movie"
        return ([kind] + (model.full?.Genres ?? item.Genres ?? []).prefix(2)).joined(separator: " · ")
    }

    /// 4K / HD and CC badges from the media.
    var badges: [String] {
        var b: [String] = []
        if let w = model.streams("Video").first?.Width { b.append(w >= 3200 ? "4K" : w >= 1200 ? "HD" : "SD") }
        if !model.streams("Subtitle").isEmpty { b.append("CC") }
        return b
    }

    func badge(_ t: String) -> some View {
        Text(t).coveFont(size: 10, weight: .bold).padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.75), lineWidth: 1))
    }

    var starring: [String] { (model.full?.People ?? []).filter { $0.`Type` == "Actor" }.prefix(3).map { $0.Name } }
    var directors: [String] { (model.full?.People ?? []).filter { $0.`Type` == "Director" }.prefix(2).map { $0.Name } }

    // Header: Apple TV style, a full-width backdrop with the logo, info and buttons in the bottom-left corner
    var header: some View {
        ZStack(alignment: .bottomLeading) {
            // Fill the page width without growing it (a filled image sized by its own width widened the page)
            Color.clear.frame(maxWidth: .infinity).frame(height: 600)
                .overlay { Backdrop(id: item.backdropId ?? item.Id) }.clipped()
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .init(x: 0.65, y: 0.5))
            LinearGradient(colors: [.clear, .clear, bg.opacity(0.7), bg], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if item.isEpisode, let sn = item.SeriesName {
                        Text("\(sn) · S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0)")
                            .coveFont(size: 15, weight: .semibold).opacity(0.85)
                    }
                    if item.isEpisode { Text(item.Name).coveFont(size: 44, weight: .heavy).lineLimit(2) }
                    else { TitleLogo(item: item, height: 110, font: 52) }
                    HStack(spacing: 8) {
                        Text(kindLine)
                        if let o = model.full?.OfficialRating { badge(o) }
                        if let r = model.full?.CommunityRating {
                            HStack(spacing: 3) { Image(systemName: "star.fill").foregroundColor(.yellow); Text(String(format: "%.1f", r)) }
                        }
                    }.coveFont(size: 15, weight: .medium)
                    if let o = item.Overview, !o.isEmpty {
                        // The whole description, no MORE button
                        Text(o).frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            .coveFont(size: 15).foregroundColor(.white.opacity(0.85))
                    }
                    HStack(spacing: 8) {
                        if let y = item.ProductionYear { Text(item.isSeries ? item.yearText : String(y)) }
                        if let t = model.full?.RunTimeTicks, t > 0 { Text("· " + runtimeText(t)) }
                        if let t = model.full?.RunTimeTicks, t > 0, !model.simple { Text("· Ends at " + endsAtText(t)) }
                        ForEach(badges, id: \.self) { badge($0) }
                    }.coveFont(size: 14).foregroundColor(.white.opacity(0.85))
                    buttons.padding(.top, 8)
                }
                Spacer(minLength: 30)
                VStack(alignment: .leading, spacing: 2) {
                    if !starring.isEmpty {
                        (Text("Starring ").foregroundColor(.white.opacity(0.55)) + Text(starring.joined(separator: ", ")))
                    }
                    if !directors.isEmpty {
                        (Text("Director ").foregroundColor(.white.opacity(0.55)) + Text(directors.joined(separator: ", ")))
                    }
                }
                .coveFont(size: 14).frame(maxWidth: 280, alignment: .leading).padding(.bottom, 8)
            }
            .padding(.horizontal, 52).padding(.bottom, 30)
        }
        .frame(height: 600)
        .clipped()
        .foregroundColor(.white)
    }

    /// Version, audio, subtitle and quality pickers under the header (movies and episodes).
    @ViewBuilder var pickers: some View {
        if !model.simple {
            VStack(alignment: .leading, spacing: 8) {
                if let tag = model.full?.Taglines?.first { Text(tag).font(.headline) }
                streamsRow
            }.padding(.horizontal, 52)
        }
    }

    var meta: some View {
        HStack(spacing: 12) {
            if let r = model.full?.CommunityRating {
                HStack(spacing: 3) { Image(systemName: "star.fill").foregroundColor(.yellow); Text(String(format: "%.1f", r)) }
            }
            if let c = model.full?.CriticRating { Text("🍅 \(Int(c))%") }
            if let y = item.ProductionYear { Text(String(y)) }
            if let t = model.full?.RunTimeTicks { Text(runtimeText(t)) }
            if let o = model.full?.OfficialRating {
                Text(o).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary))
            }
            if let g = model.full?.Genres?.first { Text(g) }
            if let t = model.full?.RunTimeTicks, !model.simple { Text("Ends at " + endsAtText(t)) }
        }.font(.subheadline).foregroundColor(.secondary)
    }

    /// Wraps onto more lines when the window is narrow, so long version names can't widen the page.
    var streamsRow: some View {
        FlowLayout(hSpacing: 20, vSpacing: 10) {
            if model.sources.count > 1 {
                HStack(spacing: 6) {
                    Text("Version").foregroundColor(.secondary)
                    Picker("", selection: $model.srcIdx) {
                        ForEach(Array(model.sources.enumerated()), id: \.element.Id) { i, s in Text(s.Name ?? s.Path ?? "Version \(i + 1)").tag(i) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: 320)   // long file names are cut with "…"
                }
            }
            if let v = model.streams("Video").first {
                HStack(spacing: 6) { Text("Video").foregroundColor(.secondary); Text(v.DisplayTitle ?? "") }
            }
            if !model.streams("Audio").isEmpty {
                labeled("Audio") {
                    Picker("", selection: $model.audioIdx) {
                        ForEach(model.streams("Audio")) { Text($0.DisplayTitle ?? "Track \($0.Index)").tag($0.Index) }
                    }
                }
            }
            labeled("Subtitles") {
                Picker("", selection: $model.subIdx) {
                    Text("Off").tag(-1)
                    ForEach(model.streams("Subtitle")) { Text($0.DisplayTitle ?? "Track \($0.Index)").tag($0.Index) }
                }
            }
            labeled("Quality") {
                Picker("", selection: $model.quality) {
                    Text("Original").tag(0)
                    Text("1080p · 8 Mbps").tag(8_000_000)
                    Text("720p · 4 Mbps").tag(4_000_000)
                    Text("480p · 1.5 Mbps").tag(1_500_000)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundColor(.secondary)
            content().pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }

    var buttons: some View {
        let played = emby.isPlayed(item)
        let fav = emby.isFav(item)
        return HStack(spacing: 12) {
            let r = model.resumePoint
            Button { model.playNow(from: r > 0 ? 0 : nil) } label: {
                Label(model.playLabel, systemImage: "play.fill").coveFont(size: 17, weight: .semibold)
                    .padding(.horizontal, 34).frame(height: 46)
                    .background(Capsule().fill(.white)).foregroundColor(.black)
            }.buttonStyle(HoverButton())
            if r > 0 {
                Button { model.playNow() } label: {
                    Label("Resume from \(timeString(r))", systemImage: "arrow.uturn.forward").coveFont(size: 17, weight: .semibold)
                        .padding(.horizontal, 26).frame(height: 46)
                        .background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(HoverButton())
            }
            RatingButton(item: item, full: model.full)
            glassCircle(fav ? "checkmark" : "plus", help: fav ? "Remove from Favorites" : "Add to Favorites") {
                Task { await emby.setFav(item.id, !fav, name: item.Name) }
            }
            glassCircle(played ? "eye.slash" : "eye", help: played ? "Mark as unwatched" : "Mark as watched") {
                Task { await emby.setPlayed(item.id, !played, name: item.Name) }
            }
            if let u = SafeLink.url(model.full?.RemoteTrailers?.first?.Url) {
                glassCircle("film", help: "Trailer") { Trailer.open(u, item: item, emby: emby) }
            }
        }
    }

    func glassCircle(_ name: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).coveFont(size: 17, weight: .semibold)
                .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(HoverButton()).helpLabel(help)
    }

    /// Language name from "English (SRT)" etc., so "eng" and "en" tracks group together.
    static func langName(_ st: MStream) -> String { subLangName(st) }   // same rule as "Always load…"




    func seasonPoster(_ n: Int) -> some View {
        let sItem: Item? = model.seasonItem(n)
        let title: String = model.seasonTitle(n)
        let selected: Bool = n == model.currentSeason
        return Button { model.season = n } label: {
            VStack(spacing: 8) {
                CachedImage(url: emby.image(sItem?.Id ?? item.Id, width: 400)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.15); Text(title) }
                }
                .frame(width: 170, height: 255).clipped().cornerRadius(8)
                .overlay(alignment: .topTrailing) { CountBadge(count: model.unwatched(n)).padding(8) }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(selected ? 1 : 0.85), lineWidth: selected ? 3 : 1))
                .shadow(radius: 6)
                .hoverLift()
                .hoverItemActions(sItem, .bottomTrailing, children: model.episodes(inSeason: n))
                Text(title).font(.body).foregroundColor(selected ? .primary : .secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plainHand)
    }

    var seasonRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons").coveFont(size: 22, weight: .bold).padding(.horizontal, 52)
            if seasonLayout == "grid" {
                // All seasons at once, wrapped onto as many lines as needed (Settings → Libraries → Season layout)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 170), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(model.seasonNumbers, id: \.self) { n in seasonPoster(n) }
                }.padding(.horizontal, 52).padding(.vertical, 8)
            } else {
                ArrowScrollRow(ids: model.seasonNumbers, itemWidth: 170, inset: 52) { n in seasonPoster(n) }
            }
        }
    }

    var episodesHeader: some View {
        let multi: Bool = model.seasonNumbers.count > 1
        let heading: String = multi ? model.seasonTitle(model.currentSeason) : "Episodes"
        return HStack(spacing: 16) {
            if multi {
                Menu {
                    ForEach(model.seasonNumbers, id: \.self) { n in Button(model.seasonTitle(n)) { model.season = n } }
                } label: {
                    HStack(spacing: 6) {
                        Text(heading).coveFont(size: 22, weight: .bold)
                        Image(systemName: "chevron.up.chevron.down").coveFont(size: 14, weight: .semibold).foregroundColor(.secondary)
                    }
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().handCursor()
            } else {
                Text(heading).coveFont(size: 22, weight: .bold)
            }
            if model.canFilterWatched {
                Button(model.showAllEps ? "Hide watched" : "Show all") { model.showAllEps.toggle() }
                    .buttonStyle(.plainHand).font(.callout.weight(.semibold)).foregroundStyle(.tint)
            }
            Spacer()
            episodeLayoutToggle
            if !model.epLangs.isEmpty {
                Text("Subtitles").foregroundColor(.secondary)
                Picker("", selection: $epSubLang) {
                    Text(defaultSubLabel).tag("")
                    if subAlwaysOn { Text("Off").tag("off") }
                    ForEach(model.epLangs, id: \.code) { l in Text(l.name).tag(l.code) }
                }.labelsHidden().fixedSize()
            }
        }.padding(.horizontal, 52).padding(.top, 10)
    }

    /// Netflix-style episode row: big number, clean 16:9 still with progress, title + length, summary.
    func episodeRow(_ ep: Item) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        return NavigationLink(value: ep) {
            HStack(alignment: .center, spacing: 18) {
                Text("\(ep.IndexNumber ?? 0)").coveFont(size: 26, weight: .semibold)
                    .foregroundColor(.secondary).frame(width: 40)
                CachedImage(url: emby.image(ep.id, width: 480, plain: true)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color(white: 0.15) }
                .frame(width: 220, height: 124).clipped()
                .overlay(alignment: .bottomTrailing) {
                    if pct > 0, pct < 100, !played { ProgressRing(progress: pct / 100).padding(8) }
                }
                .cornerRadius(6)
                .thinBorder(6)
                .hoverLift(play: 36) { model.playEpisode(ep) }
                .hoverItemActions(ep)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ep.Name).coveFont(size: 16, weight: .semibold).lineLimit(1)
                        if played { Image(systemName: "checkmark.circle.fill").foregroundColor(.white.opacity(0.7)) }
                        Spacer()
                        if let t = ep.RunTimeTicks, t > 0 { Text(runtimeText(t)).foregroundColor(.secondary) }
                    }
                    if showEpDesc { Text(ep.Overview ?? "").lineLimit(3).font(.callout).foregroundColor(.secondary) }
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
            .contentShape(Rectangle())
        }.handCursor()
        .buttonStyle(.plainHand).padding(.horizontal, 52)
    }

    var episodesList: some View {
        let eps: [Item] = model.shownEpisodes
        return VStack(alignment: .leading, spacing: 12) {
            // Row view picks the season from the "Season 7" menu; grid and list also show the season posters
            if model.seasonNumbers.count > 1 && epLayout != "row" { seasonRow }
            // Extra space below the header, and the header kept in front: a hovered episode card grows a little
            // (hover lift) and could otherwise cover the view buttons and swallow their clicks
            episodesHeader.padding(.bottom, 14).zIndex(1)
            if epLayout == "row" {
                ArrowScrollRow(ids: eps.map { $0.id }, itemWidth: 360, spacing: 22, inset: 52) { id in
                    if let ep = eps.first(where: { $0.id == id }) { episodeCard(ep) }
                }
            } else if epLayout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 22) {
                    ForEach(eps) { ep in episodeCard(ep, fill: true) }
                }.padding(.horizontal, 52)
            } else {
                ForEach(eps) { ep in episodeRow(ep) }
            }
        }
    }

    var episodeLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { epLayout = m.0 } label: {
                    Image(systemName: m.1).coveFont(size: 13, weight: .semibold)
                        .frame(width: 36, height: 28)
                        .background(Capsule().fill(epLayout == m.0 ? Color.white.opacity(0.22) : Color.clear))
                        .foregroundColor(epLayout == m.0 ? .white : .secondary)
                        .contentShape(Capsule())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 36).glassCapsule()
    }


    /// Apple TV episode card: still with "EPISODE 1", the title, summary and "▶ 59m" over a dark fade.
    /// `fill`: the card fills its grid column (same shape as the 360-wide card in the row) instead of a fixed width.
    func episodeCard(_ ep: Item, fill: Bool = false) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        let hasProgress: Bool = pct > 0 && pct < 100 && !played
        let height: CGFloat = showEpDesc ? 330 : 203
        return NavigationLink(value: ep) {
            Group {
                if fill {
                    Color.clear.frame(minWidth: 0, maxWidth: .infinity).aspectRatio(360 / height, contentMode: .fit)
                        .overlay { episodeStill(ep) }
                } else {
                    episodeStill(ep).frame(width: 360, height: height)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EPISODE \(ep.IndexNumber ?? 0)").coveFont(size: 12, weight: .medium).opacity(0.7)
                    Text(ep.Name).coveFont(size: 17, weight: .semibold).lineLimit(1)
                    if showEpDesc {
                        Text(ep.Overview ?? "").coveFont(size: 13).opacity(0.8).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: played ? "checkmark" : "play.fill").coveFont(size: 11)
                        if hasProgress {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.35))
                                Capsule().fill(Color.white).frame(width: 34 * pct / 100)
                            }.frame(width: 34, height: 4)
                        }
                        if let t = ep.RunTimeTicks, t > 0 {
                            let left = hasProgress ? max(0, t - (ep.UserData?.PlaybackPositionTicks ?? 0)) : t
                            Text(runtimeText(left) + (hasProgress ? " left" : "")).coveFont(size: 13, weight: .medium)
                        }
                    }.padding(.top, 4)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.top, 70).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                   .init(color: .black.opacity(0.75), location: 0.45),
                                                   .init(color: .black.opacity(0.9), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .thinBorder(12)
            .hoverLift(play: 44) { model.playEpisode(ep) }
        }.handCursor()
        .buttonStyle(.plainHand)
        .hoverItemActions(ep)
    }

    func episodeStill(_ ep: Item) -> some View {
        CachedImage(url: emby.image(ep.id, width: 720, plain: true)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color(white: 0.15) }
    }

    var boxGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 18) {
            ForEach(model.kids) { PosterCard(item: $0) }
        }.padding(.horizontal, 52)
    }

    @AppStorage("castSize") private var castSize = "normal"
    @ViewBuilder var castSection: some View {
        let people = Array((model.full?.People ?? []).prefix(30))
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast & Crew").coveFont(size: 22, weight: .bold).padding(.horizontal, 52)
                ArrowScrollRow(ids: Array(people.indices), itemWidth: CastTile.width(castSize), inset: 52) { i in
                    NavigationLink(value: PersonRef(id: people[i].Id, name: people[i].Name)) { CastTile(p: people[i]) }
                        .buttonStyle(.plainHand).accessibilityLabel("Show everything with \(people[i].Name)")   // no tooltip on actors
                }
            }
        }
    }

    func mediaInfo(_ s: MSource, _ f: Full) -> String {
        var info = (s.Container ?? "").uppercased()
        if let z = s.Size { info += "  " + ByteCountFormatter.string(fromByteCount: z, countStyle: .file) }
        if let a = parseDate(f.DateCreated) { info += "  Added " + a.formatted(date: .abbreviated, time: .shortened) }
        return info
    }

    func aboutRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).bold()
            Text(text).foregroundColor(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder var aboutSection: some View {
        if let f = model.full {
            VStack(alignment: .leading, spacing: 16) {
                Text("About").font(.title3.bold())
                if let d = parseDate(f.UserData?.LastPlayedDate) {
                    aboutRow("Date Last Played", d.formatted(date: .abbreviated, time: .shortened))
                }
                if let g = f.Genres, !g.isEmpty { aboutRow("Genres", g.joined(separator: ", ")) }
                if let s = f.Studios, !s.isEmpty { aboutRow("Studios", s.map { $0.Name }.joined(separator: ", ")) }
                if let links = f.ExternalUrls, !links.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Links").bold()
                        HStack(spacing: 10) {
                            ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                                if let n = l.Name, let u = SafeLink.url(l.Url) { Link(n, destination: u).handCursor() }
                            }
                        }
                    }
                }
                if let s = model.src {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Media Info").bold()
                        if let p = s.Path { Text(p).foregroundColor(.secondary).textSelection(.enabled) }
                        Text(mediaInfo(s, f)).foregroundColor(.secondary)
                    }
                }
            }.padding(.horizontal, 52).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Included In": the collections this title belongs to; a click opens the collection's page.
    @ViewBuilder var includedInSection: some View {
        if !model.includedIn.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Included In").coveFont(size: 22, weight: .bold).padding(.horizontal, 52)
                ArrowScrollRow(ids: Array(model.includedIn.indices), itemWidth: 170, spacing: 14, inset: 52) { PosterCard(item: model.includedIn[$0]) }
            }
        }
    }

    @ViewBuilder var similarSection: some View {
        if !model.similar.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("More Like This").coveFont(size: 22, weight: .bold)
                    Spacer()
                    similarLayoutToggle
                }.padding(.horizontal, 52)
                // Extra space below, and the header kept in front: a hovered poster grows a little (hover lift)
                // and could otherwise cover the view buttons and swallow their clicks
                .padding(.bottom, 14).zIndex(1)
                if similarLayout == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(model.similar) { PosterCard(item: $0) }
                    }.padding(.horizontal, 52)
                } else if similarLayout == "list" {
                    LazyVStack(spacing: 6) { ForEach(model.similar) { ListRow(item: $0) } }.padding(.horizontal, 52)
                } else {
                    ArrowScrollRow(ids: Array(model.similar.indices), itemWidth: 170, spacing: 14, inset: 52) { PosterCard(item: model.similar[$0]) }
                }
            }
        }
    }

    var similarLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { similarLayout = m.0 } label: {
                    Image(systemName: m.1).coveFont(size: 13, weight: .semibold)
                        .frame(width: 36, height: 28)
                        .background(Capsule().fill(similarLayout == m.0 ? Color.white.opacity(0.22) : Color.clear))
                        .foregroundColor(similarLayout == m.0 ? .white : .secondary)
                        .contentShape(Capsule())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 36).glassCapsule()
    }
}

/// Lays children out left to right and wraps to a new line when the width runs out.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 12
    var vSpacing: CGFloat = 8

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            var sz = v.sizeThatFits(.unspecified)
            if sz.width > width { sz = v.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + sz.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, sz))
            x += sz.width + hSpacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let r = rows(width, subviews)
        var h: CGFloat = 0, w: CGFloat = 0
        for row in r {
            var rowW: CGFloat = 0, rowH: CGFloat = 0
            for (_, sz) in row { rowW += sz.width; rowH = max(rowH, sz.height) }
            rowW += hSpacing * CGFloat(max(0, row.count - 1))
            w = max(w, rowW)
            h += rowH
        }
        h += vSpacing * CGFloat(max(0, r.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let h = row.map(\.1.height).max() ?? 0
            for (i, sz) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + hSpacing
            }
            y += h + vSpacing
        }
    }
}
