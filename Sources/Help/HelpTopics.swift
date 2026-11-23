import Foundation

// Cove Help: the topics shown in the Help window (Help → Cove Help, ⌘?, or the profile menu's Cove Help row).
// Everything is offline, written from the app's own code. Pure data + search, tested in Tests/HelpTests.swift.

enum HelpGroup: String, CaseIterable, Equatable, Sendable {
    case watching = "Watching"
    case admin = "Admin"
}

/// One keyboard shortcut line: the keys (drawn as small glass caps) and what they do.
struct HelpKey: Equatable, Sendable {
    let keys: [String]
    let what: String
}

/// One piece of a section.
enum HelpBlock: Equatable, Sendable {
    case text(String)
    case bullets([String])
    case keys([HelpKey])
    /// "Where to find it": a menu path such as "Activity → Cleanup".
    case place(String)

    var plain: String {
        switch self {
        case .text(let s), .place(let s): return s
        case .bullets(let b): return b.joined(separator: "\n")
        case .keys(let k): return k.map { $0.keys.joined(separator: " ") + " " + $0.what }.joined(separator: "\n")
        }
    }
}

struct HelpSection: Equatable, Sendable {
    let heading: String
    let blocks: [HelpBlock]
}

struct HelpTopic: Identifiable, Equatable, Sendable {
    let id: String
    let group: HelpGroup
    let title: String
    let symbol: String
    let intro: String
    let sections: [HelpSection]

    /// All the words of the topic, for search.
    var bodyText: String {
        ([intro] + sections.flatMap { [$0.heading] + $0.blocks.map(\.plain) }).joined(separator: "\n")
    }
}

enum HelpSearch {
    /// Case- and accent-insensitive form used for matching.
    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The query's words (empty for a blank query).
    nonisolated static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// Topics the user may see: admin topics only for admins (unknown role = not admin).
    nonisolated static func visible(_ all: [HelpTopic] = HelpTopics.all, admin: Bool?) -> [HelpTopic] {
        all.filter { $0.group == .watching || admin == true }
    }

    /// Topics whose title or text contains every word of the query. Title matches come first.
    nonisolated static func filter(_ topics: [HelpTopic], query: String) -> [HelpTopic] {
        let t = terms(query)
        guard !t.isEmpty else { return topics }
        let hits = topics.filter { topic in
            let hay = fold(topic.title + "\n" + topic.bodyText)
            return t.allSatisfy { hay.contains($0) }
        }
        let inTitle = hits.filter { topic in t.allSatisfy { fold(topic.title).contains($0) } }
        return inTitle + hits.filter { h in !inTitle.contains(where: { $0.id == h.id }) }
    }

    /// Character ranges of `text` matching any query word (for highlighting).
    nonisolated static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for term in terms(query) {
            var from = text.startIndex
            while from < text.endIndex,
                  let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: from..<text.endIndex) {
                out.append(r)
                from = r.upperBound
            }
        }
        return out
    }
}

enum HelpTopics {
    static let all: [HelpTopic] = watching + admin

    // MARK: - Watching (everyone)

    static let watching: [HelpTopic] = [
        HelpTopic(id: "getting-started", group: .watching, title: "Getting started", symbol: "sparkles",
                  intro: "Cove plays your movies and shows from an Emby or Jellyfin server. You need the server's address and your user name and password.",
                  sections: [
                    HelpSection(heading: "Add a server", blocks: [
                        .bullets(["Type the server's address, for example http://192.168.1.10:8096 or https://media.example.com.",
                                  "Sign in with the user name and password you use on that server.",
                                  "Cove finds out by itself whether it is Emby or Jellyfin."]),
                        .place("Profile circle (top right) → Add server…"),
                    ]),
                    HelpSection(heading: "Switch server or user", blocks: [
                        .text("The profile circle at the far right of the top bar shows your picture or initials. Click it to open your menu."),
                        .bullets(["Your servers are listed with a dot: green is online. A ✓ marks the one you use now. Click another one to switch.",
                                  "Switch user… signs in a different user on the same server. Cove keeps both sign-ins, so the next switch is one click.",
                                  "Change picture… sets your user picture on the server."]),
                        .place("Profile circle → Servers / Switch user…"),
                    ]),
                    HelpSection(heading: "Several servers", blocks: [
                        .text("You can save as many servers as you like. Each keeps its own sign-in. Saved servers are also listed in Settings → Connect."),
                        .place("Settings → Connect → Saved servers"),
                    ]),
                  ]),
        HelpTopic(id: "home", group: .watching, title: "Home", symbol: "house",
                  intro: "Home is the first page. It shows a big banner on top and rows of things to watch below it.",
                  sections: [
                    HelpSection(heading: "The banner", blocks: [
                        .text("The banner shows one title at a time. Use ← and → to go to the previous or next one."),
                        .bullets(["Banner shows: From Home rows, Newest, Random picks or Favorites.",
                                  "Refresh banner sets how often new picks come in.",
                                  "Style and Banner navigation change how it looks and moves."]),
                        .place("Settings → Home → Banner"),
                    ]),
                    HelpSection(heading: "Rows", blocks: [
                        .bullets(["Continue Watching: things you started. Press Return to open the selected card.",
                                  "Up Next: the next episode of shows you watch (can be turned off).",
                                  "One row per library, and Recently Added if you turn it on."]),
                        .text("Continue Watching and the other sections can each be a row or a grid. Which libraries appear on Home is set per library."),
                        .place("Settings → Home → Layout / Rows, and Settings → Libraries"),
                    ]),
                    HelpSection(heading: "Shortcuts", blocks: [
                        .keys([HelpKey(keys: ["H"], what: "Go to Home (when you are not typing)"),
                               HelpKey(keys: ["←", "→"], what: "Previous / next banner")]),
                    ]),
                  ]),
        HelpTopic(id: "libraries", group: .watching, title: "Libraries & search", symbol: "square.grid.2x2",
                  intro: "Each library has its own page in the top bar. Search looks through everything on the server.",
                  sections: [
                    HelpSection(heading: "Search", blocks: [
                        .text("Press ⌘F to open the search bar at the bottom of the window. Results show as you type. Esc closes it."),
                        .keys([HelpKey(keys: ["⌘", "F"], what: "Search")]),
                        .place("Profile circle → Search, or ⌘F"),
                    ]),
                    HelpSection(heading: "Filter and sort", blocks: [
                        .bullets(["Tabs on a library page: the library itself, Collections, Genres and Favorites.",
                                  "Filter: show All, Unwatched or Watched, or one genre.",
                                  "Sort: by Name, Recently Added, Release Date or Rating.",
                                  "Switch between grid and list with the view buttons."]),
                        .text("The default view and sort of each library are in Settings."),
                        .place("Settings → Libraries → Your libraries"),
                    ]),
                    HelpSection(heading: "Posters", blocks: [
                        .bullets(["Dim watched posters makes things you have seen a bit darker.",
                                  "You can show the title and the year under each poster."]),
                        .place("Settings → General → Posters"),
                    ]),
                  ]),
        HelpTopic(id: "title-page", group: .watching, title: "A title's page", symbol: "film",
                  intro: "Click a poster to open its page. The buttons under the title do the main things.",
                  sections: [
                    HelpSection(heading: "Buttons", blocks: [
                        .bullets(["Play starts from the beginning. Resume (↻ with a time) goes on where you stopped.",
                                  "Trailer plays the trailer, when the server has one.",
                                  "✓ Watched marks it as watched or unwatched.",
                                  "♡ Favorite adds it to your Favorites.",
                                  "★ shows your own rating. It is stored in Trakt, so connect Trakt first (Settings → Connect).",
                                  "Watch together starts a SyncPlay group (Jellyfin only)."]),
                    ]),
                    HelpSection(heading: "More on the page", blocks: [
                        .bullets(["The About card shows the details: year, runtime, genres, the story and more.",
                                  "Cast & Crew, and More Like This, are further down.",
                                  "Series pages list seasons and episodes."]),
                        .text("Movie pages can show a big banner or a poster with details."),
                        .place("Settings → Libraries → Movie and show pages"),
                    ]),
                  ]),
        HelpTopic(id: "player", group: .watching, title: "Player", symbol: "play.rectangle",
                  intro: "The player shows its controls when you move the mouse and hides them again after a moment.",
                  sections: [
                    HelpSection(heading: "Controls", blocks: [
                        .bullets(["The bar at the bottom: play/pause, skip back and forward, and the timeline.",
                                  "Buttons on the right: Audio, Subtitles, Quality and speed, Playback info, Picture in Picture, Cast, AirPlay and full screen.",
                                  "Episodes and Chapters panels when the video has them.",
                                  "The Back pill at the top left closes the player."]),
                    ]),
                    HelpSection(heading: "Audio and subtitles", blocks: [
                        .text("Open the Subtitles panel to pick a track. If subtitles come too early or too late, use − and + to move them by 100 ms. The ↺ button resets the offset."),
                        .text("Your subtitle language and the look of subtitles (size, color, shadow, background) are in Settings."),
                        .place("Settings → Subtitles"),
                    ]),
                    HelpSection(heading: "Up next and intros", blocks: [
                        .bullets(["Near the end of an episode, Up Next shows the next one. Press Space or Return to play it now.",
                                  "When the server knows where the intro is, a Skip Intro button appears.",
                                  "Play the next episode and Skip intros can both happen by themselves."]),
                        .place("Settings → Playback → Automatically"),
                    ]),
                    HelpSection(heading: "AirPlay", blocks: [
                        .text("While AirPlay is on, the picture is on the TV. The player shows \u{201C}Playing on\u{201D} with the device name."),
                    ]),
                    HelpSection(heading: "Shortcuts", blocks: [
                        .keys([HelpKey(keys: ["Space"], what: "Play or pause"),
                               HelpKey(keys: ["←", "→"], what: "Skip back / forward"),
                               HelpKey(keys: ["F"], what: "Full screen on or off"),
                               HelpKey(keys: ["Esc"], what: "Close a panel, leave full screen, or close the player"),
                               HelpKey(keys: ["I"], what: "Playback info"),
                               HelpKey(keys: ["P"], what: "Picture in Picture"),
                               HelpKey(keys: ["E"], what: "Episodes panel"),
                               HelpKey(keys: ["C"], what: "Chapters panel")]),
                        .text("The skip length and the starting quality and speed are in Settings → Playback."),
                    ]),
                  ]),
        HelpTopic(id: "tv", group: .watching, title: "Watch on a TV", symbol: "tv",
                  intro: "Cove can send a video to a TV with Google Cast or AirPlay. You pick one of the two.",
                  sections: [
                    HelpSection(heading: "Choose Cast or AirPlay", blocks: [
                        .text("Pick Google Cast or AirPlay. The player then shows the matching button."),
                        .place("Settings → Playback → Play on a TV with"),
                        .text("You can't change this while a cast or AirPlay is running. Stop it first."),
                    ]),
                    HelpSection(heading: "While casting", blocks: [
                        .bullets(["Play, pause and seek from Cove. The TV follows.",
                                  "Pick subtitles in the cast panel, or Off. The offset can be moved there too.",
                                  "Stop casting to watch on the Mac again."]),
                    ]),
                  ]),
        HelpTopic(id: "watch-together", group: .watching, title: "Watch together", symbol: "person.2",
                  intro: "Watch together (SyncPlay) lets people on different devices watch the same thing at the same time. It needs a Jellyfin server.",
                  sections: [
                    HelpSection(heading: "How it works", blocks: [
                        .bullets(["On a movie or episode page, click Watch together to make a group or join one.",
                                  "Everyone in the group plays, pauses and seeks together.",
                                  "In the player, the Watch together button shows the group and its members.",
                                  "If someone is still loading, the group waits and Cove shows it."]),
                        .place("A title's page → Watch together"),
                    ]),
                  ]),
        HelpTopic(id: "collections", group: .watching, title: "Collections", symbol: "square.stack",
                  intro: "A collection groups films, such as all films of a series. You find them under a library's Collections tab.",
                  sections: [
                    HelpSection(heading: "Playing a collection", blocks: [
                        .bullets(["Play collection starts the first film and plays the others one after another.",
                                  "Resume goes on with the film you stopped in.",
                                  "A collection counts as watched when all its films are watched. ✓ on the collection marks all of them."]),
                        .place("Library → Collections"),
                    ]),
                  ]),
        HelpTopic(id: "notifications", group: .watching, title: "Notifications", symbol: "bell",
                  intro: "Cove can tell you when new movies or episodes arrive on the server you are signed in to.",
                  sections: [
                    HelpSection(heading: "Turn them on", blocks: [
                        .bullets(["Choose New movies and/or New episodes.",
                                  "Per library, choose what to hear about. \u{201C}Series I'm watching\u{201D} means series in your Favorites or with an episode watched or started.",
                                  "Things you already started or watched are never announced.",
                                  "Send test notification checks that macOS shows them."]),
                        .place("Settings → Home → Notifications"),
                        .text("macOS asks for permission the first time. If notifications are off for Cove, use Open System Settings."),
                    ]),
                    HelpSection(heading: "See them later", blocks: [
                        .text("Every notification is also kept in Activity. A red badge shows how many you haven't seen yet."),
                        .place("Activity → Notifications, or Profile circle → Notifications"),
                    ]),
                  ]),
        HelpTopic(id: "activity", group: .watching, title: "Activity", symbol: "chart.bar",
                  intro: "Activity is the last item in the top bar. It shows what is playing and your watching history.",
                  sections: [
                    HelpSection(heading: "Pages", blocks: [
                        .bullets(["Now Playing: who is watching what on the server right now.",
                                  "Notifications: new movies and episodes.",
                                  "Statistics (the dropdown pill): Overview, History and Year in review."]),
                        .place("Activity, or Profile circle → My activity"),
                    ]),
                    HelpSection(heading: "Year in review", blocks: [
                        .text("A story of your year: what you watched most, how long, and more. Pick the year with the year pill."),
                        .bullets(["Save as image saves a tall share card.",
                                  "Copy image puts it on the clipboard."]),
                        .place("Activity → Statistics → Year in review"),
                    ]),
                  ]),
        HelpTopic(id: "settings", group: .watching, title: "Settings overview", symbol: "gearshape",
                  intro: "Open Settings with ⌘, or from the profile menu. Changes apply right away. Esc closes the window.",
                  sections: [
                    HelpSection(heading: "Tabs", blocks: [
                        .bullets(["General: font, hover effect, Glass, text size, accent color, background, navigation style and the top bar, poster labels and Dim watched posters.",
                                  "Home: the banner, the layout of rows, which rows show, and notifications.",
                                  "Libraries: order and visibility of your libraries, each library's view and sort, Favorites, and the movie and show pages.",
                                  "Subtitles: your subtitle language and how subtitles look.",
                                  "Playback: clicking the video, starting quality and speed, skip length, autoplay, skip intros, Play on a TV with, the live connection and the debug log.",
                                  "Connect: your current and saved servers, Trakt, and for admins nexcrate and Nexview.",
                                  "Trakt: your Trakt numbers (only while Trakt is connected).",
                                  "The full list of keyboard shortcuts is here in Help, under Keyboard shortcuts.",
                                  "About: version, updates (including Get beta versions), storage (image and subtitle cache), backup of your settings, and Reset."]),
                        .place("Cove → Settings… (⌘,)"),
                    ]),
                  ]),
        HelpTopic(id: "shortcuts", group: .watching, title: "Keyboard shortcuts", symbol: "keyboard",
                  intro: "Letter shortcuts work when you are not typing in a field.",
                  sections: [
                    HelpSection(heading: "Everywhere", blocks: [
                        .keys([HelpKey(keys: ["⌘", "F"], what: "Search"),
                               HelpKey(keys: ["H"], what: "Home"),
                               HelpKey(keys: ["F"], what: "Full screen on / off"),
                               HelpKey(keys: ["⌃", "⌘", "F"], what: "Full screen on / off"),
                               HelpKey(keys: ["Esc"], what: "Close a menu or search first, then leave full screen"),
                               HelpKey(keys: ["←", "→"], what: "Home: previous / next banner"),
                               HelpKey(keys: ["⌘", ","], what: "Settings"),
                               HelpKey(keys: ["⌘", "←"], what: "Back"),
                               HelpKey(keys: ["⌘", "["], what: "Back"),
                               HelpKey(keys: ["⌘", "?"], what: "Cove Help")]),
                    ]),
                    HelpSection(heading: "While a video plays", blocks: [
                        .keys([HelpKey(keys: ["Space"], what: "Play or pause (on Up Next: play the next episode now)"),
                               HelpKey(keys: ["Return"], what: "Play the next episode while Up Next shows"),
                               HelpKey(keys: ["←", "→"], what: "Skip back / forward"),
                               HelpKey(keys: ["F"], what: "Full screen on or off"),
                               HelpKey(keys: ["Esc"], what: "Close a panel, leave full screen, or close the player"),
                               HelpKey(keys: ["I"], what: "Show or hide playback info"),
                               HelpKey(keys: ["P"], what: "Picture in Picture"),
                               HelpKey(keys: ["E"], what: "Episodes panel (episodes only)"),
                               HelpKey(keys: ["C"], what: "Chapters panel (when the video has chapters)")]),
                    ]),
                    HelpSection(heading: "Other", blocks: [
                        .keys([HelpKey(keys: ["Return"], what: "Open the selected Continue Watching card"),
                               HelpKey(keys: ["Return"], what: "Try Again when the server can't be reached"),
                               HelpKey(keys: ["Esc"], what: "Close Settings, About or Help")]),
                        .text("The usual Mac shortcuts work too, such as ⌘Q, ⌘W and ⌘H."),
                    ]),
                  ]),
        HelpTopic(id: "updates", group: .watching, title: "Updates & troubleshooting", symbol: "wrench.and.screwdriver",
                  intro: "Cove updates itself and has a few tools for when something goes wrong.",
                  sections: [
                    HelpSection(heading: "Updates", blocks: [
                        .bullets(["Cove checks for updates when it starts, if Check for updates automatically is on.",
                                  "Check now from the Cove menu or the profile menu.",
                                  "Keep Cove in your Applications folder, so the update can replace it.",
                                  "Turn on Get beta versions to get new versions first. Betas may have rough edges.",
                                  "Turning betas off never downgrades: you stay on the beta until the next official release."]),
                        .place("Cove → Check for Updates…, or Settings → About → Updates"),
                    ]),
                    HelpSection(heading: "Report an issue", blocks: [
                        .text("Describe what happened. You can attach the debug log: tokens, addresses and IDs are removed first."),
                        .place("Help → Report an Issue…, or About Cove → Report an issue"),
                    ]),
                    HelpSection(heading: "Debug log", blocks: [
                        .text("Turn on Write a player debug log, play the video that has the problem, then report it. The log is at ~/Library/Logs/Cove.log."),
                        .place("Settings → Playback → Troubleshooting"),
                    ]),
                    HelpSection(heading: "Sign out", blocks: [
                        .text("Sign out removes your sign-in for this server from this Mac."),
                        .place("Profile circle → Sign out"),
                    ]),
                  ]),
    ]

    // MARK: - Admin (server admins only)

    static let admin: [HelpTopic] = [
        HelpTopic(id: "manage-server", group: .admin, title: "Manage server", symbol: "server.rack",
                  intro: "If you are an admin on the server, Cove can do the common dashboard jobs.",
                  sections: [
                    HelpSection(heading: "Tabs", blocks: [
                        .bullets(["Overview: the server's name and version, how many streams run, Restart server and Shut down server.",
                                  "Users: add, rename and delete users, change a password, pick which libraries they can open, and see when they were last active.",
                                  "Libraries: scan one library or all of them, add a library or a folder, rename or remove one.",
                                  "Tasks: the server's scheduled tasks. Run now starts one.",
                                  "Devices: the devices that use the server. Rename one, or remove it to sign it out.",
                                  "Plugins: installed plugins, install updates, or uninstall one.",
                                  "Logs: read the server's log files.",
                                  "Trash: titles you deleted in the last 7 days, with Undo for each."]),
                        .text("Anything that can't be undone, such as a restart or removing a user, asks you first."),
                        .place("Profile circle → Manage server…"),
                    ]),
                  ]),
        HelpTopic(id: "title-tools", group: .admin, title: "Title tools", symbol: "ellipsis.circle",
                  intro: "Admins get a ⋯ menu on movie, series, season, episode and collection pages.",
                  sections: [
                    HelpSection(heading: "The ⋯ menu", blocks: [
                        .bullets(["Edit metadata…: title, story, dates, genres and other fields.",
                                  "Refresh metadata…: fetch the information and images again.",
                                  "Identify…: search by name, year or IMDb/TMDb/TVDb id and pick the right match (movies and shows).",
                                  "Edit images…: change the poster, backdrops, logo and more.",
                                  "Open in web dashboard.",
                                  "Items without poster / Items without backdrop: lists of titles that are missing artwork."]),
                        .place("A title's page → ⋯"),
                    ]),
                    HelpSection(heading: "Find to edit", blocks: [
                        .text("On a library page, Find to edit… searches the library and opens Edit metadata for the title you pick."),
                        .place("Library page → Find to edit…"),
                    ]),
                  ]),
        HelpTopic(id: "statistics", group: .admin, title: "Statistics", symbol: "chart.xyaxis.line",
                  intro: "Full statistics need the Playback Reporting plugin on the server. It only records plays from the day it is installed.",
                  sections: [
                    HelpSection(heading: "Pages", blocks: [
                        .bullets(["Overview: totals and what is popular.",
                                  "History: every play, newest first.",
                                  "Users: each user's watch time, or sorted by Last active.",
                                  "Graphs: plays by day, hour, device and more.",
                                  "Libraries: how much each library is watched.",
                                  "Insights: habits such as binges and favourite times."]),
                        .place("Activity → Statistics"),
                    ]),
                    HelpSection(heading: "How long data is kept", blocks: [
                        .text("The plugin deletes old plays after its Max data age. To keep everything, set it to keep data forever in the server's dashboard."),
                        .place("Server dashboard → Playback Reporting → Max data age"),
                    ]),
                  ]),
        HelpTopic(id: "cleanup", group: .admin, title: "Cleanup", symbol: "trash.circle",
                  intro: "Cleanup lists your movies and series so you can find what nobody watches and delete it.",
                  sections: [
                    HelpSection(heading: "Columns and sorting", blocks: [
                        .bullets(["Columns: Title, Watched, Rating, Added, Last played, Size and Requested by.",
                                  "Click a column header to sort by it. Click again to reverse. Items with no value always come last."]),
                    ]),
                    HelpSection(heading: "Filters and search", blocks: [
                        .bullets(["Never watched by anyone, Watched by nobody in 1 year, Low rated, Not watched and added more than 6 months ago.",
                                  "Requested via Nexview, and Requested but the requester never watched it (needs Nexview).",
                                  "Rating: Rated by you, Has a server rating, No server rating.",
                                  "Movies, series or both, and a search field for titles."]),
                        .text("\u{201C}Your rating\u{201D} is your own ★ from Trakt. \u{201C}Server rating\u{201D} is the server's community rating."),
                    ]),
                    HelpSection(heading: "Deleting", blocks: [
                        .text("Select several rows to delete them in one go. See Delete & Undo."),
                        .place("Activity → Cleanup"),
                    ]),
                  ]),
        HelpTopic(id: "delete", group: .admin, title: "Delete & Undo", symbol: "arrow.uturn.backward.circle",
                  intro: "Admins can delete a movie, series, season or episode with Delete…. A window shows exactly what goes before anything happens.",
                  sections: [
                    HelpSection(heading: "Two ways", blocks: [
                        .bullets(["With nexcrate connected and the title in nexcrate: the torrents leave qBittorrent and the files go to nexcrate's recycle bin for 7 days. You can Undo.",
                                  "Without nexcrate: the server deletes the files for good. There is no Undo."]),
                    ]),
                    HelpSection(heading: "Undo", blocks: [
                        .text("Right after deleting, a toast offers Undo. Later, open the Trash tab in Manage server: it lists each delete for 7 days, with Undo."),
                        .place("Manage server → Trash"),
                    ]),
                    HelpSection(heading: "If the server says no", blocks: [
                        .text("Your account needs Allow media deletion. Turn it on for your user in Manage server → Users."),
                    ]),
                  ]),
        HelpTopic(id: "connect", group: .admin, title: "Connect nexcrate & Nexview", symbol: "link",
                  intro: "nexcrate gives deletes a 7-day Undo. Nexview shows who requested each title in Cleanup.",
                  sections: [
                    HelpSection(heading: "nexcrate", blocks: [
                        .bullets(["Enter nexcrate's address and click Connect.",
                                  "Cove shows a pairing code. Confirm that code in nexcrate.",
                                  "Or click Enter key… and paste a key made in nexcrate. It needs the read and request scopes.",
                                  "Test checks the connection. Disconnect removes it."]),
                        .place("Settings → Connect → nexcrate"),
                    ]),
                    HelpSection(heading: "Nexview", blocks: [
                        .bullets(["Make a token in Nexview: Profile → Account → Security → API tokens. \u{201C}May only read\u{201D} is enough.",
                                  "The Nexview account must be an admin or approver.",
                                  "Enter the address, paste the token and click Save."]),
                        .place("Settings → Connect → Nexview"),
                        .text("Keys and tokens are kept sealed on this Mac."),
                    ]),
                  ]),
        HelpTopic(id: "server-alerts", group: .admin, title: "Server alerts", symbol: "exclamationmark.triangle",
                  intro: "Cove can warn you about the server you are signed in to. It checks every 5 minutes while Cove is open.",
                  sections: [
                    HelpSection(heading: "What can trigger an alert", blocks: [
                        .bullets(["Server restart needed",
                                  "Server restarting / unreachable / back online",
                                  "Server update available",
                                  "Plugin updates available",
                                  "Scheduled task failed",
                                  "Failed sign-in attempts",
                                  "Library scan finished"]),
                        .text("Turn each one on or off. Clicking an alert opens Manage server."),
                        .place("Settings → Home → Notifications → Server alerts (admins)"),
                    ]),
                  ]),
        HelpTopic(id: "watch-activity", group: .admin, title: "Watch activity", symbol: "eye",
                  intro: "On a title's page, the 👁 pill shows how many of the server's users watched it, for example \u{201C}3/10 watched\u{201D}.",
                  sections: [
                    HelpSection(heading: "Details", blocks: [
                        .bullets(["Click the pill to see each user: watched, how far they got, or Not started.",
                                  "It also shows the date added and when it was last played, and by whom.",
                                  "Last active (in Manage server → Users and Activity → Users) shows when each account last used the server."]),
                        .place("A title's page → 👁 pill"),
                    ]),
                  ]),
    ]
}
