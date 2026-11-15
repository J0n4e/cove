# Security policy

## Reporting a vulnerability

Please report security problems **privately**, through GitHub:
[Report a vulnerability](https://github.com/J0n4e/cove/security/advisories/new) (Security tab → *Report a vulnerability*).
Please don't open a public issue. We'll reply as soon as we can and credit you in the release notes if you like.

## Supported versions

Only the latest release gets security fixes. Cove updates itself (Cove → Check for Updates…).

## What Cove does to protect you

- Updates install only if they are signed with Cove's release key (Ed25519) and match GitHub's checksum.
- Only releases tagged `vX.Y[.Z]` are offered, and the app in the download must be Cove (same bundle id),
  carry exactly that version, and be newer than the running one, so an older signed build can't be replayed.
- Releases are built by GitHub Actions and carry a build attestation:
  `gh attestation verify Cove.zip -R J0n4e/cove`.
- Cove talks only to the media servers you add and to `api.github.com` (update check, can be turned off).
- Your password is never stored; Cove keeps the server's sign-in token instead, and Sign Out ends that session on the server.
