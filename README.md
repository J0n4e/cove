# Cove

A native macOS client for [Emby](https://emby.media) and [Jellyfin](https://jellyfin.org), written in SwiftUI.

**[Download the latest release](https://github.com/J0n4e/cove/releases/latest)**: for Macs with Apple Silicon (M1 or later), macOS 14 or later. Intel Macs are not supported.

## Install

1. Download `Cove.zip` from [Releases](https://github.com/J0n4e/cove/releases/latest) and unzip it.
2. Move **Cove.app** to **Applications**.
3. The first time, right-click the app and choose **Open**. The app is ad-hoc signed, not notarized.

**Coming from EmbyFlix?** Cove is the new name of EmbyFlix and a separate download (EmbyFlix can't update itself to Cove). The first time Cove opens it copies your EmbyFlix settings, saved servers and sign-in, so there is nothing to set up again. You can delete EmbyFlix afterwards.

Closing the window quits the app; click the Dock icon to open it again.

After that, Cove keeps itself up to date. It checks for new releases at launch and shows a **Software Update** window with the release notes: **Install and Restart**, **Later** or **Skip This Version** (a skipped version isn't offered again at launch; Check for Updates still shows it). You can also check yourself under **Cove → Check for Updates…**. After an update, **What's New in Cove** shows the notes once; it's also in the Cove menu.

## Features

### Security (v1.15)
- **Signed updates:** every release is signed, and the in-app updater only installs an update whose signature checks out, so a fake download can't be installed.
- **Stable code signature:** builds are signed with Cove's own certificate, so macOS recognises each update as the same app.
- Safer links, sign-out revokes the login on the server, and redirects only to the same server. An optional player debug log can be turned on in Settings → Playback.
- **https first (v1.15.1):** a server address typed without http/https uses https when the server supports it, and Cove warns before sending a password over plain http to a server outside your home network. Picture links no longer carry your sign-in token.

### Emby and Jellyfin (v1.13)
- Works with both **Emby** and **Jellyfin** servers. Cove detects which one a server is and talks to each the way it expects.
- **Add Server** has an optional **Name** field, and saved servers can be renamed in Settings → Servers (click the name). Each server shows whether it is Emby or Jellyfin.
- **Settings → Libraries → Home → Up Next row** turns the Up Next row on or off.
- On Jellyfin, automatic intro skipping and progress-bar thumbnails are not available yet.

### Themes (v1.12)
Settings → General → **Theme**:
- **Glass** (default): full-width banners, frosted glass buttons and bars, Up Next and Recently Added, the new Settings window, media keys and an optional separate player window (details below).
- **Classic**: the original Cove v1.9.2 screens, options and behaviour, unchanged.

Switching is instant and swaps the whole app, including the Dock icon.

### Glass theme
- **Home:** a full-width banner with the title's logo, "TV Show · Comedy · 2011", a short summary, a white **Play** pill and round glass **+** (favorite) and **i** (more info) buttons. Page dots sit at the bottom and arrows appear on hover.
- **Continue Watching:** wide rounded cards with the title, episode and a "▶ ━ 42m" line.
- **Show and movie pages:** a full-width backdrop with the logo, genres, rating, a two-line summary with **MORE**, year, length and 4K/HD/CC badges, the Play pill and glass buttons, and "Starring … / Director …" on the right.
- **Episodes:** a **Season ⌃⌄** menu and a row of large episode cards ("EPISODE 1", title, summary, "▶ 59m"). Row, grid or list can be chosen next to the heading or in Settings.
- **Player:** big glass back / play-pause / forward circles in the middle; glass groups for picture in picture, full screen and info (top left), volume (top right), and episodes, subtitles, quality, chapters and options (bottom right). The episode and show names sit bottom-left, above a glass scrubber.

### Browsing
- **Fast pictures:** posters and banners are saved on your Mac (up to 500 MB, Settings → About shows the size and can clear it), so pictures seen before appear instantly. Cove asks for lighter pictures, loads the next banners and the first posters of each row ahead, shows blurred previews while loading on Jellyfin, and downloads what is on screen first.
- Sign in to one or more Emby or Jellyfin servers (http or https). Switch between them in Settings → Servers.
- Home page with a rotating featured banner (white text with a black outline over the picture), Continue Watching, and rows for each library.
- **Continue Watching** cards show the title bottom-left, "S3·E3 · 42m left" (or the time left for a movie) top-left and a white progress ring bottom-right. The play button resumes; clicking the card opens the series page on that season (or the movie page).
- **Navigation:** a sidebar, or a **top bar** under the title bar: EMBYFLIX on the left, a pill with Home, Favorites, Now Playing, your libraries in the middle, search and Settings on the right. Choose it under Settings → General → Appearance → Navigation.
- Library pages:
  - grid or list view
  - sort and filter (watched, unwatched, genre), with an A–Z jump bar
  - **Group by Collection** (⋯ menu) in movie libraries shows each collection as one poster
  - your choices are remembered per library
- Series pages have a season poster row with unwatched counts and an episode grid or a list (number, still with progress, title, length, summary). A season shows only its unwatched episodes, with a **Show all / Hide watched** link when it has both. Grid cards put the name bottom-left, "S3·E3 · 42m left" top-left and a white progress ring bottom-right. The episode description can be turned off. Episode stills are loaded without server image frames. Movie pages show cast, similar titles and version, audio, subtitle and quality pickers.
- **Actor pages:** click anyone in Cast & Crew to see all their movies and shows in your libraries.
- **Favorites** page like Emby: Favorite Movies, Favorite Shows and Favorite Collections rows; each heading opens the full list. Shows display their run (e.g. 2007 – 2019).
- Watched/unwatched badges (neutral white-on-dark, so they don't clash with the accent colour).
- **Now Playing:** every active stream on the server, with its title, position, direct play or transcode, client, device, user and IP.
- Rows scroll with the arrows (one item per click; each arrow hides when that end is reached), by dragging with the mouse, or with the trackpad.
- Search across movies, shows and people. Matching people appear in their own row and open their actor page.
- Posters, seasons and episodes lift on hover; episodes show a play button.
- Posters, series and episodes have a thin white border.
- **Hover preview card:** rest on a poster to see the backdrop, details and summary, with Play, favorite and watched buttons. It opens over the poster with a zoom (Smooth or Spring, adjustable duration) that can be turned off, and clicking it opens the title. The delay is adjustable, and the whole hover preview can be switched off.

### Player
- Direct play or HLS transcode. Quick **subtitle** and **quality** menus sit in the player's bottom bar. Server transcodes are stopped when you close the player, and are kept alive while you pause, so subtitles stay in sync after resuming.
- Resume and Start Over, with progress synced to the server. Playback starts directly at the resume point, so subtitles stay in sync.
- **Subtitles:**
  - text subtitles (SRT and others) are drawn by the app; image subtitles (PGS) are burned in by the server
  - adjustable offset, size, colour, shadow, background and position; subtitles move above the controls while they are shown
  - **Always load preferred subtitle language** applies everywhere (movies, episodes, Continue Watching), ahead of what was remembered for a series
  - audio and subtitle choices are remembered per series
- **Skip intros automatically** using Emby's intro markers. You can turn this off to get a Skip Intro button instead.
- **Up next card** in the last 30 seconds of an episode, showing when the next one starts. Space or Return plays it now.
- **Thumbnail previews** when hovering or dragging the progress bar (uses Emby's generated thumbnails).
- **Episode picker** (E) in the player: browse seasons and jump to another episode.
- **Chapters** panel (C), **picture in picture** (P) and a **playback info** overlay (I) that shows codecs, bitrate and why the server is transcoding.
- Video-only full screen (F). Esc leaves full screen without stopping the video. In full screen the pointer hides. The screen saver and display sleep are blocked while a video plays.
- Keyboard: Space play/pause (or play the next episode when the Up next card shows), ← → skip, F full screen, E episodes, C chapters, I info, P picture in picture, Esc back.

### Settings (⌘,)
General (accent color, background, navigation style), Libraries (**Poster labels**, hover preview, episode layout and description, library list), Subtitles, Playback (including an optional player debug log, off by default), Servers (saved servers and **Sign Out**, which also ends the session on the server), and About (version, update controls, **Save and load settings** to a file, and **Reset all settings to default**).

> Intro skipping and thumbnail previews depend on your Emby server: intro detection and thumbnail-image extraction must be enabled there.

## Build from source

Requires macOS 14+ and Xcode 15+ (Swift 5.9).

```sh
swift run                 # run in development
./make-app.sh             # build dist/Cove.app (Apple Silicon, ad-hoc signed)
VERSION=v1.15.1 ./make-app.sh   # set the version shown in the app (default: latest git tag)
```

## Development and releases

- Work goes to the **`Development`** branch through pull requests. `Development` is merged into `main` for each release.
- Releases are built by the **Build Cove.app** GitHub Actions workflow when a version tag is pushed (for example `v1.15` or `v1.15.1`; small releases use X.Y.Z, major ones X.Y). It signs the app and the update, and creates a draft release to write notes for and publish. Full releases are what the in-app updater installs, and only when their update signature verifies; pre-releases are ignored. See [RELEASING.md](RELEASING.md) (one-time key setup included) and [SECURITY.md](SECURITY.md).

## License

See [LICENSE](LICENSE).
