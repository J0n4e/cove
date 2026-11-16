import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

struct SearchBar: View {
    @Binding var query: String
    @Environment(\.appBG) var bg
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search movies, shows, people", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plainHand)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: 280)
        }
        .padding(.horizontal, 32).padding(.vertical, 10)
        .background(bg)
    }
}

struct SearchView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let query: String
    @State private var results: [Item] = []
    @State private var people: [Item] = []
    @State private var busy = false
    var heading: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Results for “\(query)”").font(.title2.bold())
            if !people.isEmpty { peopleRow }
            if !people.isEmpty && !results.isEmpty { Text("Titles").font(.title3.bold()).padding(.top, 8) }
        }
    }

    var body: some View {
        Group {
            if !results.isEmpty {
                // The titles: AppKit grid (see PosterGrid), with the heading and people scrolling above them
                GeometryReader { g in
                    PosterGrid(emby: emby, items: results, look: PosterLook(glass3D: false),
                               insets: NSEdgeInsets(top: 0, left: 40, bottom: 40, right: 40),
                               header: AnyView(heading.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 40).padding(.top, 40)),
                               topInset: g.safeAreaInsets.top, push: { NavState.shared.push($0) },
                               open: { NavState.shared.open($0) })
                    .ignoresSafeArea(edges: .top)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heading
                        if busy { Spinner() }
                        else if people.isEmpty { Text("No results").foregroundColor(.secondary) }
                    }.padding(40)
                }
            }
        }
        .background(bg)
        .task(id: query) {
            busy = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            async let titles = emby.search(query)
            async let persons = emby.searchPeople(query)
            results = await titles
            people = await persons
            busy = false
        }
    }

    /// Matching people as poster-sized portraits; each opens the person's page.
    var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.title3.bold())
            // In rows like the titles below, not one line that scrolls sideways
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14, alignment: .top)], spacing: 18) {
                    ForEach(people) { p in
                        PageLink(value: PersonRef(id: p.Id, name: p.Name)) {
                            VStack(spacing: 6) {
                                CachedImage(url: emby.image(p.Id, width: 360)) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.system(size: 50)).foregroundColor(.secondary) }
                                }
                                // Poster-sized portrait, like the other result cards
                                .frame(width: 170, height: 255).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
                                .overlay(alignment: .topLeading) {
                                    if emby.isPersonFav(p.Id) {
                                        FavHeart(size: 16).padding(8)
                                    }
                                }
                                .modifier(HoverPersonHeart(id: p.Id, name: p.Name))
                                .hoverLift()
                                Text(p.Name).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(width: 170)
                        }
                        .buttonStyle(.plainHand).accessibilityLabel("Show everything with \(p.Name)")   // no tooltip on actors
                    }
            }.padding(.vertical, 8)
        }
        .task { _ = await emby.favoritePeople() }   // hearts on favorite people
    }
}

/// Search box floating at the bottom of the window (top bar layout), above the toast spot.
struct SearchDock: View {
    @Binding var query: String
    @Binding var open: Bool
    let focusTick: Int
    @FocusState private var focused: Bool
    var body: some View {
        VStack {
            Spacer()
            if open {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary)
                    // Typing counts only while the box is open: after closing, the field could hold on to the
                    // keyboard while sliding away, and typing then opened search results
                    TextField("Search movies, shows, people", text: Binding(get: { query }, set: { if open { query = $0 } }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15)).frame(width: 320)
                        .focused($focused)
                        .onExitCommand { close() }   // Esc closes it
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                            .buttonStyle(.plainHand)
                    }
                }
                .padding(.horizontal, 18).frame(height: 44)
                .searchGlass()
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear { DispatchQueue.main.async { focused = true } }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.35), value: open)
        .onChange(of: focusTick) { focused = true }
        // However it closes (Esc, the search button): let go of the keyboard. The text field kept it while
        // sliding away, so typing afterwards still went into the search and opened results.
        .onChange(of: open) { _, on in if !on { release() } }
    }

    func close() {
        query = ""
        open = false
        release()
    }

    func release() {
        focused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        // Again once the slide-away animation is over, in case the field took the keyboard back meanwhile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !open, let w = NSApp.keyWindow, w.firstResponder is NSText else { return }
            w.makeFirstResponder(nil)
        }
    }
}
