# Releasing Cove

Releases are built, signed and attested by GitHub Actions (`.github/workflows/build-app.yml`). The in-app
updater installs a release only if `Cove.zip.sig` verifies against the public key built into the app, so a
zip uploaded by hand is refused. It also ignores tags that aren't `v` plus 2–4 numbers (`v1.17.2`) and refuses a
zip whose app has a different bundle id, a `CoveVersion` other than the tag, or a version that isn't newer, so
always release with `VERSION` equal to the tag.

The signing secrets live in the GitHub **Environment `release`**, which only `v*` tags may use, and a **tag
ruleset** lets only the repository owner create `v*` tags. So a pull request, a branch, or someone with write
access (or a stolen write-access account) cannot get a build signed. Pull requests, pushes to `main`/`Development` and
*Run workflow* run the unit tests and build without any secrets (ad-hoc signature).

## One-time setup (repository owner)

1. **Environment** (Settings → Environments → New environment → `release`):
   - *Deployment branches and tags* → **Selected branches and tags** → *Add deployment branch or tag rule* →
     Ref type **Tag**, pattern `v*`. Do not add any branch rule.
   - Optional, recommended: *Required reviewers* → yourself. Each release then waits for one click
     (*Review deployments → Approve*) before the secrets are used.
2. **Update-signing key** (Ed25519), stored in the environment:
   ```sh
   swift scripts/make-update-key.swift
   gh secret set COVE_UPDATE_KEY --env release -R J0n4e/cove < update-key.private
   ```
   Put the printed **public key** into `Sources/Updater.swift` (`static let publicKey = "..."`) in a PR.
   Save `update-key.private` in your password manager, then delete it. **Never commit it.**
3. **Code-signing certificate** (self-signed, gives every release the same identity). Note: without an Apple
   Developer ID (Team ID) macOS still ties Keychain items to each exact build, so Cove keeps sign-ins in its
   preferences file for now (sealed with a per-Mac key, see SECURITY.md); Keychain storage returns once releases are signed with a Developer ID:
   ```sh
   scripts/make-signing-cert.sh --github     # creates cove-signing.p12, sets CODESIGN_P12 / CODESIGN_P12_PASSWORD in "release"
   ```
   Save `cove-signing.p12` and its password in your password manager, then delete the file.
4. **No signing secrets at repository level.** Settings → Secrets and variables → Actions → *Repository
   secrets* must not contain `COVE_UPDATE_KEY`, `CODESIGN_P12` or `CODESIGN_P12_PASSWORD` (any workflow on any
   branch can read repository secrets).
5. **Protect the release tags** (Settings → Rules → Rulesets → New ruleset → *New tag ruleset*):
   name `release-tags`, enforcement **Active**, *Bypass list* → **Repository admin**, target → *Include by
   pattern* `v*`, rules **Restrict creations**, **Restrict updates**, **Restrict deletions**, **Block force
   pushes**.
6. **Protect the branches** (Settings → Rules → Rulesets → New branch ruleset), for `main` and `Development`:
   *Restrict deletions*, *Block force pushes*, *Require a pull request before merging* (1 approval for `main`).
   Also turn on two-factor authentication for every account with write access, and
   *Settings → Code security → Private vulnerability reporting*.

Only the repository owner can add environments, secrets and rulesets.

## Each release

1. All changes go into `Development` through pull requests (CI must be green).
2. **Test build:** Actions → *Build Cove.app* → *Run workflow* on `Development`, with a version **one below** the
   coming release (for example `v1.18.4` when releasing `v1.18.5`), so the test app can still update to the real
   release. This builds an ad-hoc signed artifact without secrets and without creating a release.
3. The **owner** tests that build and gives the OK.
4. Open a PR `Development` → `main` and merge it.
5. The **owner** tags the merge commit on `main` as `vX.Y.Z` (other accounts are blocked by the tag ruleset),
   either with git or through the GitHub API:
   ```sh
   git checkout main && git pull
   git tag v1.18.5 && git push origin v1.18.5
   ```
6. The `release` job runs the unit tests (a failure stops the release), builds the app, signs it with the
   certificate, signs `Cove.zip` with the Ed25519 update key, adds a build attestation and creates a **draft**
   release with `Cove.zip` and `Cove.zip.sig`. With required reviewers on, approve the deployment first
   (Actions → the run → *Review deployments*).
7. **Verify** the draft: the job already checks `Cove.zip.sig` against the key installed apps trust; download both
   files and check the attestation (below) before publishing.
8. Write the release notes and **Publish**. Pre-releases are ignored by the updater. The notes (Markdown) are what
   the Software Update and What's New windows show, so write them for users.

Anyone can check that a download came from this repository's workflow:
`gh attestation verify Cove.zip -R J0n4e/cove`.

## Changing the update key (lost or leaked key)

The release job always verifies the signature against the public key in the **latest published release**
(the key installed apps trust), not the one in the commit being built. A rotation therefore takes one release:

1. On a Mac: `swift scripts/make-update-key.swift`. Save `update-key.private` in your password manager.
   **Do not** put it into GitHub yet.
2. PR: put the new public key into `Sources/Updater.swift`.
3. Tag and publish that release. It is signed with the **old** private key (still in GitHub) and the workflow
   shows a "Key rotation" notice. Every installed app accepts it and from then on trusts the new key.
4. Only after it is **published**: set the new key with
   `gh secret set COVE_UPDATE_KEY --env release -R J0n4e/cove < update-key.private`, delete the old secret,
   then delete the local file.

The order is enforced: a release signed with the wrong key fails in CI instead of shipping. Users who skip the
rotation release and update later get "signature is not valid" and must download Cove once from GitHub, so
leave the rotation release as the latest one for a week or two.

**Certificate:** make a new one and update the two secrets in the `release` environment. It doesn't affect
updates or sign-ins.
