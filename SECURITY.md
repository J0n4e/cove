# Security policy

## Reporting a vulnerability

Please report security problems **privately**, through GitHub:
[Report a vulnerability](https://github.com/J0n4e/cove/security/advisories/new) (Security tab → *Report a vulnerability*).
Please don't open a public issue. We'll reply as soon as we can and credit you in the release notes if you like.

## Supported versions

| Version | Supported |
| --- | --- |
| 1.18.x (latest) | Yes |
| Older | No, please update |

Only the latest release gets security fixes. Cove updates itself (Cove → Check for Updates…).

For ordinary bugs, use the [bug report form](https://github.com/J0n4e/cove/issues/new/choose) instead.

## What Cove does to protect you

- Updates install only if they are signed with Cove's release key (Ed25519). The download is also checked
  against GitHub's SHA-256 checksum when GitHub provides one (`digest` on the release asset); older assets
  without a digest rely on the signature alone.
- Only releases tagged `vX.Y[.Z]` are offered, and the app in the download must be Cove (same bundle id),
  carry exactly that version, and be newer than the running one, so an older signed build can't be replayed.
- Releases are built by GitHub Actions and, when the attestation step succeeds, carry a build attestation
  (best effort; Cove doesn't check it): `gh attestation verify Cove.zip -R J0n4e/cove`.
- Hosts Cove contacts: the media servers you add; `api.github.com` and GitHub's release download host
  (`github.com` / `objects.githubusercontent.com`) for updates (the check can be turned off); `api.trakt.tv`
  only if you connect Trakt; YouTube (`youtube.com`, `youtube-nocookie.com`) when you play a trailer.
- The live connection to a Jellyfin server (remote control, Watch together, new-media notifications) sends the
  token in the `Authorization` header, never in the socket URL.
- Tokens are never written to the debug log (`~/Library/Logs/Cove.log`, off by default).
- New-media notifications are only shown for the server you're signed in to.
- Your password is never stored; Cove keeps the server's sign-in token instead, and Sign Out ends that session on the server.

## What is stored where

Everything lives in Cove's preferences file, `~/Library/Preferences/eu.jonae.cove.plist`:

- `servers`: the server list (name, address, user name, user id). **No tokens.**
- `serverTokens`: the servers' sign-in tokens, sealed (see below). Versions up to 1.17.3 kept them in plain
  text in `servers` (and before 1.15 under `token`); Cove moves them over on first launch and removes the
  plain-text copy only after the sealed one reads back correctly.
- `traktClientId`, `traktAccess`, `traktRefresh`: the Trakt Client ID and tokens, sealed the same way.

"Sealed" means AES-GCM with a key derived from this Mac's hardware id. This protects against casual reading
of the file and against copying it (or a backup of it) to another Mac. It does **not** protect against other
software running as you on this Mac, which can derive the same key. The macOS Keychain would do better, but
without an Apple Developer ID it asks for access after every update (see RELEASING.md). Turn on FileVault so
the file is encrypted at rest.

## Plain http and App Transport Security

Cove allows plain http app-wide (`NSAllowsArbitraryLoads`) because many Emby/Jellyfin servers run on a LAN IP or
hostname over http (`http://host:8096`), and remote http servers are supported on purpose after a confirmation
prompt. `NSAllowsLocalNetworking` alone would not cover those remote servers. What protects the sign-in token:

- Redirects are followed only to the same scheme, host and port, or as an http → https upgrade on the same host;
  never from https down to http.
- The token is added to links (`api_key=`) and image requests only for URLs with the same scheme, host and port
  as the server (default ports filled in), so an https server's reply can't send it to `http://host:443/`.
- Web views (YouTube trailers) keep full ATS (https only): `NSAllowsArbitraryLoadsInWebContent` is set to false, and when that key
  is present macOS ignores `NSAllowsArbitraryLoads` for web content, so the trailer page can only load https.

The release signing script copies the `.p12` password to the clipboard instead of printing it
(`--show-password` prints it; `--github` stores it as a secret and doesn't show it).

