# Cove

A native macOS client for [Emby](https://emby.media) and [Jellyfin](https://jellyfin.org), written in SwiftUI.

**[Download the latest release](https://github.com/J0n4e/cove/releases/latest)**: for Macs with Apple Silicon (M1 or later), macOS 14 or later. Intel Macs are not supported.

## Install

1. Download `Cove.zip` from [Releases](https://github.com/J0n4e/cove/releases/latest) and unzip it.
2. Move **Cove.app** to **Applications**.
3. The first time, right-click the app and choose **Open** (or try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**). Cove is self-signed, not notarized by Apple, so macOS asks once.

**Coming from EmbyFlix?** Cove is the new name of EmbyFlix and a separate download (EmbyFlix can't update itself to Cove). The first time Cove opens it copies your EmbyFlix settings, saved servers and sign-in, so there is nothing to set up again. You can delete EmbyFlix afterwards.

Closing the window quits the app; click the Dock icon to open it again.

After that, Cove keeps itself up to date. It checks for new releases at launch and shows a **Software Update** window with the release notes: **Install and Restart**, **Later** or **Skip This Version** (a skipped version isn't offered again at launch; Check for Updates still shows it). You can also check yourself under **Cove → Check for Updates…**. After an update, **What's New in Cove** shows the notes once; it's also in the Cove menu.

## Requirements

- A Mac with Apple Silicon, **macOS 14 or later**. Liquid Glass (the Glass setting and the glass player controls) needs **macOS 26** or later; on older macOS Cove uses its own frosted look.
- An **Emby** or **Jellyfin** server.
- **Watch together** (SyncPlay) needs **Jellyfin 10.8 or later** and a user account that is allowed to use SyncPlay (Jellyfin Dashboard → Users → the user → SyncPlay access).

## Logs and bug reports

- Something wrong with playback? Turn on **Settings → Playback → Debug log**, reproduce it, and find the log at `~/Library/Logs/Cove.log` (kept under about 1 MB). Leave it off otherwise.
- Report a bug with the [bug report form](https://github.com/J0n4e/cove/issues/new/choose): it asks for your Cove and macOS versions, server type and steps. Security problems go privately, see [SECURITY.md](SECURITY.md).

## Features

### What's new in 1.17 and 1.18
- **Themes:** Settings → General → **Theme** has **Glass** (default) and **Glass3D** (the former Classic theme, with a 3D glass look). On macOS 26+ both use Liquid Glass.
- **Glass:** **Follow macOS**, or a slider from **Clear** to **Tinted**.
- **Hover effects** for posters and cards: **Fogged mirror**, **Soft glow** or **Liquid lens**.
- **Fonts:** SF Pro (default), SF Rounded, SF Pro Expanded, Avenir Next, Futura, New York or Seravek, with a live preview, plus **Text size**.
- **Server pill** on Home shows the current server; click it to switch servers.
- **Posters:** the ♡ (favorite) and ✓ (watched) badges are always shown and are buttons: click to toggle. With Trakt connected, ★ rates the title.
- **Resume ring** on Continue Watching cards and episodes: click it to resume; the play button in the centre starts from the beginning.
- **Now Playing** updates live.
- **Player:** a glass control bar, a quick subtitle list plus the full subtitle panel, readable audio/subtitle track names, an **Episodes** panel and the **Up next** card.
- **Watch together** (SyncPlay, Jellyfin 10.8+): create or join a group and play in sync with others. Pause, play and seek are shared, drift is corrected, everyone waits while someone buffers (unless **Don't wait for others** is on), you can rejoin a group, and a series can be watched together with the next episode starting for everyone.
- **Remote control from the Jellyfin Dashboard:** play/pause/seek/stop, volume and mute, audio and subtitle tracks, full screen and **Send message**. Needs **Settings → Playback → Live connection to the server**.
- **Notifications** for new movies and episodes (Settings → Home). macOS asks for permission the first time. On Emby Cove checks every 10 minutes; on Jellyfin it uses the live connection. Only the server you're signed in to is watched.
- **Updates** are signed and verified; after an update **What's New** shows the release notes.
- **Subtitle cache:** downloaded subtitles are kept on your Mac; Settings → About → Storage shows the size and clears it.

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
- **Glass3D**: the original Cove layout (called Classic before 1.17) with a 3D glass look.

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
- **Navigation:** a sidebar, or a **top bar** under the title bar: the app name on the left, a pill with Home, Favorites, Activity, your libraries in the middle, search and Settings on the right. Choose it under Settings → General → Appearance → Navigation.
- Library pages:
  - grid or list view
  - sort and filter (watched, unwatched, genre), with an A–Z jump bar
  - **Group by Collection** (⋯ menu) in movie libraries shows each collection as one poster
  - your choices are remembered per library
- Series pages have a season poster row with unwatched counts and an episode grid or a list (number, still with progress, title, length, summary). A season shows only its unwatched episodes, with a **Show all / Hide watched** link when it has both. Grid cards put the name bottom-left, "S3·E3 · 42m left" top-left and a white progress ring bottom-right. The episode description can be turned off. Episode stills are loaded without server image frames. Movie pages show cast, similar titles and version, audio, subtitle and quality pickers.
- **Actor pages:** click anyone in Cast & Crew to see all their movies and shows in your libraries.
- **Favorites** page like Emby: Favorite Movies, Favorite Shows and Favorite Collections rows; each heading opens the full list. Shows display their run (e.g. 2007 – 2019).
- ♡ and ✓ badges on posters toggle favorite and watched with one click (an empty ♡ or a dim ✓ when not set).
- **Activity → Now Playing:** every active stream on the server, with its title, position, direct play or transcode, client, device, user and IP.
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
General (theme, Glass, hover effect, font and text size, accent color, background, navigation style), Home (rows and new-media notifications), Libraries (**Poster labels**, hover preview, episode layout and description, library list), Subtitles, Playback (live connection to the server, Watch together, and an optional player debug log, off by default), Servers (saved servers and **Sign Out**, which also ends the session on the server), and About (version, update controls, Storage for the picture and subtitle caches, **Save and load settings** to a file, and **Reset all settings to default**).

> Intro skipping and thumbnail previews depend on your Emby server: intro detection and thumbnail-image extraction must be enabled there.

## Build from source

Requires macOS 14+ and Xcode 15+ (Swift 5.9).

```sh
swift run                 # run in development
./make-app.sh             # build dist/Cove.app (Apple Silicon, ad-hoc signed)
VERSION=v1.18.5 ./make-app.sh   # set the version shown in the app (default: latest git tag)
```

## Development and releases

- Work goes to the **`Development`** branch through pull requests. `Development` is merged into `main` for each release.
- Releases are built by the **Build Cove.app** GitHub Actions workflow when the owner tags `main` (`vX.Y.Z`). It signs the app and the update (Ed25519) and creates a draft release to write notes for and publish. The in-app updater installs only published releases whose signature verifies; pre-releases are ignored. See [RELEASING.md](RELEASING.md) and [SECURITY.md](SECURITY.md).

## License

See [LICENSE](LICENSE).
