# WoWAddonSync

A macOS/SwiftUI app that keeps your WoW `_retail_` AddOns folder in sync
across machines via iCloud, checking each addon against WowInterface,
GitHub Releases, or a local CurseForge scan for its latest version when it
can identify one — and letting you point an addon at one of the first two
by hand when it can't.

## How it works

1. **WowInterface is the version source**, automatically, whenever the
   addon's own `.toc` file names a WowInterface ID (or you set one
   manually — see "Manual overrides" below). No key or account setup
   needed — see "Where the version info comes from" below for why that
   works. The app asks WowInterface for that addon's latest file.
2. **Otherwise, GitHub Releases is the version source**, automatically,
   whenever the addon's `.toc` `X-Website` field points at a github.com
   repo that publishes `.zip` release assets (or you set a repo manually).
3. **Otherwise, a local CurseForge scan is the version source**,
   automatically, for any addon the CurseForge desktop app itself already
   manages — see "CurseForge, without CurseForge's API" below. This one's
   opt-in: you grant the app access to a folder once in Settings, since
   macOS won't let it ask on its own.
4. **iCloud is updated first.** If the shared iCloud copy isn't at that
   version, the app downloads the release and updates iCloud.
5. **This Mac is updated from iCloud.** If your local AddOns folder isn't
   at the version now in iCloud, the app copies it down.

Addons that match none of the three are still synced — iCloud itself
becomes the shared reference point instead, the same way a synced Dropbox
folder works: first machine to see the addon seeds iCloud, every other
machine matches whatever iCloud has. That's still useful (your Macs stay
consistent), but it's a different, weaker claim than "verified against the
addon's actual latest release", and the status badges keep the two apart
— see below.

### Reading the status badges

"Is this the latest release?" and "do my Macs agree?" are two separate
questions, and the answer to one tells you nothing about the other: your
Macs can be in perfect agreement about a year-old version, and a brand new
release can be sitting in iCloud that this Mac hasn't pulled down yet. So
each addon gets **two** badges, one per question:

| Version — iCloud vs. the real latest release | |
|---|---|
| **Up to Date** | Verified against WowInterface, GitHub Releases, the CurseForge local scan, or a CurseForge page scrape. |
| **Update Available** | That source has something newer than what's in iCloud. |
| **Unverified** | No source matched this addon, so nothing has actually checked it. Grey, not orange — it isn't a problem, there's just nothing to report. |

| Sync — this Mac vs. iCloud | |
|---|---|
| **Synced** | This Mac's copy matches iCloud's. |
| **Needs Local Update** | iCloud has something this Mac doesn't. |
| **Missing Folders** | Some of the addon's folders are in iCloud but not here. |
| **Not in iCloud** | This Mac has it, iCloud doesn't yet. |

A healthy, verified addon therefore reads **Up to Date · Synced** — both
claims stated, rather than leaving you to infer the second from the first.
An addon with no version source reads **Unverified · Synced**, which is
the honest version of what a single "Synced" badge used to have to imply
on its own.

Four states replace both badges with one, because a single word already
says everything: **Syncing…**, **Error**, and **In iCloud Only** (nothing
installed here, so there's no local copy to compare and no version check
was run — see below).

Every addon's detail view has a **"View on ⟨site⟩ ↗"** link straight to
its actual page — WowInterface listing, GitHub repo, CurseForge page, or
(if none matched) whatever URL its own `.toc` names — so you can go look
at release notes, comments, or whether it's still maintained yourself.

### In iCloud but not installed on this Mac

The five steps above all assume the addon exists in `_retail_` to begin
with. The other direction happens too: another Mac pushes an addon this
one has never had, or you uninstall something here and iCloud still has
it. Those show up in the sidebar highlighted, badged **"In iCloud Only"**,
with two buttons — and sync deliberately does *nothing* to them on its
own:

- **Install** copies the addon's folder(s) out of iCloud into
  `Interface/AddOns`. iCloud is untouched, and "Delete from This Mac"
  undoes it.
- **Remove** moves them to the Trash *in the sync folder*, and drops the
  addon from `manifest.json`. This is the only action in the app that
  reaches your other Macs — they'll drop their copies on their next sync
  — so it always confirms first, and it trashes rather than deletes.

Leaving these alone is the point. Auto-installing would put addons into
your WoW folder that you may have removed on purpose; auto-removing would
delete an addon off every machine because one of them happened not to
have it. Neither is a call the app should make, so it asks.

A partially installed addon — some folders present, some not, which the
local scan can't notice on its own since it only sees folders that exist
— gets called out in its detail view instead, with "Force Pull iCloud →
This Mac" as the fix.

## Where the version info comes from

A `.toc` file is plain text, and beyond the standard fields (Title,
Version, Interface, ...) addon authors' build tooling commonly writes a
few non-standard `X-` fields into it. The widely-used **"BigWigs
Packager"** GitHub Action (and similar tools) writes these into every
addon it publishes, so a lot of installed addons carry them without the
author doing anything special. The app reads them in `TocParser.swift`:

- `## X-WoWI-ID: 12345` — the addon's WowInterface listing. WowInterface's
  file-details API (`api.mmoui.com`) is a plain, anonymous GET — no key,
  no application, no approval process.
- `## X-Website: https://github.com/owner/repo` — when this is a
  github.com URL, the app treats it as that addon's GitHub repo and checks
  its releases (also a plain, anonymous GET, rate-limited to 60
  requests/hour per network when unauthenticated — see
  `GitHubReleasesAPI.swift`). Only an actual uploaded `.zip` release
  *asset* is used, never GitHub's auto-generated "Source code (zip)"
  archive — that one's folder structure and contents (README, `.github/`,
  LICENSE, ...) aren't what belongs in AddOns.
- `## X-Wago-ID: aBcDeFgH` is also parsed but not used — see "Why not
  Wago.io" below.

### Manual overrides

For an addon that doesn't carry either field — or where you'd rather point
it at a different listing than the one it names — select it in the
sidebar and use the **Manual override** fields in its **Version Source**
box to set a WowInterface ID or a GitHub repo (as `owner/repo` or a full
URL) by hand. This is stored locally (in this Mac's `UserDefaults`, via
`AppSettings.swift`), but the very next sync that uses it records the
match into the shared iCloud manifest, so your other Macs pick up the same
version-checking benefit without needing to enter it themselves too.

### The known-addons list (`KnownGitHubAddons.swift`)

Most CurseForge-primary addons don't carry `X-Website` at all, so GitHub
Releases only ever kicked in automatically for addons published through
WowInterface-style tooling — everything else needed a manual override
typed in by hand, every time, on every Mac. `KnownGitHubAddons.swift` is a
small built-in table (folder name → `owner/repo`) that closes that gap for
addons someone's actually gone and checked: confirmed to publish real
GitHub Releases with a `.zip` asset whose version matches what's actually
installed, not just "a repo with a matching name." It's checked last —
after your own manual override and after the addon's `.toc` — so it never
overrides something you've set on purpose.

It currently covers WeakAuras, Bartender4, Grid2, and both Deadly Boss
Mods projects (Core and the Dungeons/Delves pack), found by cross-checking
your installed CurseForge addons against GitHub by hand. Three other
addons were checked and deliberately left out — Clique, TomTom, and
BeQuiet all have real, matching source on GitHub, but none of the three
has ever published a release, so there's no `.zip` for this app to check
against or download; adding them here would just turn into a permanent
error instead of falling back to iCloud-only syncing (once an addon
resolves to a GitHub repo, that's its source exclusively — see
`evaluateWithGitHubSource` in `SyncCoordinator.swift`). Class Codex has no
findable repo from its credited original author at all.

Extending this list means actually checking a candidate's releases page
for a matching `.zip` asset first, the same way — not just adding
whatever repo shares the addon's name.

### CurseForge, without CurseForge's API

CurseForge is where most WoW addons actually live, but its API requires a
developer application/approval process — that's why this app avoided it
entirely at first, and why the other two sources above exist. There's a
third option that doesn't go through that gate at all: the CurseForge
*desktop app* keeps its own local record of every addon it manages, at
`~/Library/Application Support/CurseForge/agent/GameInstances/*.json`,
refreshed periodically while that app runs. Each entry already carries
both `installedFile` (what's on disk) and `latestFile` (what CurseForge's
servers say is newest, plus a plain CDN download link) — the CurseForge
app already made the real API call and wrote the answer to disk. This app
just reads that file, the same way it reads a `.toc`. It never calls
CurseForge's actual API; the one live network request is downloading a
release zip from `latestFile.downloadUrl`, which points at CurseForge's
CDN (`edge.forgecdn.net`) — an unauthenticated GET, same as any direct
download link.

Real limitations to know about:
- Only helps addons the CurseForge app is actually managing.
- Freshness depends on when CurseForge's app last refreshed that file —
  this app has no way to trigger or check that.
- It's CurseForge's own internal app format, not a published, versioned
  API. It's what a real installed copy wrote as of when this was built,
  but nothing guarantees it stays in this shape across CurseForge app
  updates.
- macOS treats `~/Library/...` as sensitive enough that this app can't
  request access to it automatically the way it can the AddOns/sync
  folders — you grant it yourself, once, via the folder picker in
  Settings → CurseForge (local scan).

See `CurseForgeLocalScanAPI.swift` for the implementation and
`FolderAccess.swift`'s `CurseForgeFolderAccess` for the folder grant.

### Why not Wago.io

Wago.io was the first thing I looked at for a third source, since a lot of
addons (WeakAuras, Plater profiles especially) carry an `X-Wago-ID`
already. I couldn't find a public *read* API for it, though — `docs.wago.io`
only documents a publish-side `POST /api/projects/<id>/version` for addon
authors uploading a new release, not a way to ask "what's the latest
version of project X" as a consumer. The one open-source client I found
with any Wago support (`AcidWeb/CurseBreaker`) only talks to a separate,
narrower `data.wago.io/api/check/{type}` endpoint scoped to WeakAuras/
Plater *import strings*, not general addon zip downloads — not the same
thing this app needs. Rather than build against an undocumented endpoint
I can't verify actually works the way I'd be guessing, I left Wago
unwired; `X-Wago-ID` is still parsed and stored on `TocMetadata` in case a
real API turns up later.

## Installing it into /Applications

`./install.sh` builds the Release configuration and puts the result in
`/Applications`, moving any copy already there to the Trash first. No
arguments needed:

```sh
./install.sh            # build and install
./install.sh --open     # ...and launch it afterwards
./install.sh --help     # every option
```

It signs **ad-hoc** (`codesign -s -`, the same thing Xcode's "Sign to Run
Locally" does), so it needs no certificate and no Apple Developer
membership — consistent with the rest of this project. The one thing it's
strict about is the sandbox: it refuses to install a build whose signature
is missing `com.apple.security.app-sandbox`, because that failure is
otherwise invisible. Such an app launches perfectly well and then can't
hold onto either folder grant, which looks like an app bug rather than a
packaging one. (Building with `CODE_SIGNING_ALLOWED=NO` does exactly
this.)

Your settings and the two folder grants live in the app's container, keyed
by bundle identifier, so replacing the bundle keeps them. Worst case, if
macOS decides a re-signed build is a different app, you re-pick the two
folders in Settings — nothing is lost.

Other options worth knowing: `--universal` builds for arm64 *and* x86_64,
so you can copy the same bundle to an Intel Mac (the default builds only
for the machine you're on); `--app PATH` installs an already-built bundle
instead of building one; `--dest DIR` installs somewhere other than
`/Applications`. Build products are cached in
`~/Library/Caches/WoWAddonSync-install`, so repeat installs are
incremental — `--clean` throws that away and builds fresh.

## One-time setup (do this on each Mac)

This app deliberately avoids Apple's app-private iCloud container API
(`com.apple.developer.icloud-container-identifiers`) — that requires a
paid Apple Developer Program membership ($99/yr), and a free "Personal
Team" account can build an app that claims it but macOS refuses to launch
the result (a code-signing/RunningBoard failure at launch, not a build
error — if you hit "Could not launch... Runningboard has returned error
5" that's this). Instead, the app just asks you to pick a folder — put it
inside your regular iCloud Drive and it syncs exactly the same way, no
paid account needed, works with any Apple ID.

If you just want the app installed, `./install.sh` (above) does steps 1–3
for you and needs no Team set at all — it signs ad-hoc. The Xcode route
below is for when you want to work on the code, or want the build signed
with your own Apple ID.

1. Open `WoWAddonSync.xcodeproj` in Xcode.
2. Select the **WoWAddonSync** target → **Signing & Capabilities**.
   - Set your **Team** (your Apple ID needs to be added in Xcode → Settings
     → Accounts if it isn't already) — a free Personal Team is fine, this
     app doesn't use anything that requires a paid one.
   - The bundle identifier is currently `com.jimmy.WoWAddonSync` — change
     it if you'd rather, doesn't need to match anything special.
3. Build and run (⌘R). On first launch it'll ask you for two folders:
   - Your AddOns folder — point it at
     `/Applications/World of Warcraft/_retail_/Interface/AddOns` (it
     defaults there if that path exists).
   - A sync folder — navigate into **iCloud Drive** (it's in the panel's
     sidebar) and create or pick a folder there, e.g. `iCloud Drive →
     WoWAddonSync`.
4. Repeat on your other Macs — pick **the same iCloud Drive folder** (same
   name/path) as the sync folder on each one, so they all read and write
   the same place. Same Apple ID (signed into iCloud) on each Mac, same as
   any other iCloud Drive syncing.

There's nothing else to configure — no API key, no account, no settings
required to get real version checks on WowInterface- or GitHub-matched
addons. If you also want the CurseForge local-scan source (see "CurseForge,
without CurseForge's API" above), grant it once per Mac in Settings → the
CurseForge section; it's entirely optional. Everything else (addons
matching none of the three) is still kept in sync across your machines via
iCloud regardless.

## What I couldn't verify from here

I built and researched this from a sandboxed Linux environment with no
Mac and no Xcode — I do have live web access (used to verify the
`KnownGitHubAddons.swift` entries by hand, checking real releases pages
for matching `.zip` assets and versions), but nothing here can actually
compile or run the app. So I want to be upfront about what that still
leaves unconfirmed:

**WowInterface's response format.** Verified against
`AcidWeb/CurseBreaker`'s open-source client (an existing WoW addon
updater), but I don't have a Mac or live network access here to confirm a
real response against, so treat the field names as "probably right, worth
a glance once you're testing for real." One specific piece I'm genuinely
unsure of: `UIDate`'s exact string format (the code tries a plain epoch
number and a couple of common date formats, falling back to "now" if none
match). This only affects the *displayed* release date though — sync
correctness compares the file's MD5, not the date, so a wrong date never
causes an addon to sync incorrectly.

**Zip extraction shells out to `/usr/bin/ditto`** (standard on every Mac)
rather than a third-party zip library, to keep the project
dependency-free.

**The CurseForge local-scan JSON shape** was built by inspecting one real
`AddonGameInstance.json` file you exported from your own CurseForge
install (not from any published schema — CurseForge doesn't publish one
for this file), so the fields the parser reads (`addonID`, `name`,
`webSiteURL`, `filePaths`, `installedFile`/`latestFile` with their `id`,
`fileName`, `fileDate`, `downloadUrl`) are confirmed against a real
example, which is better footing than WowInterface's format above. Two
things are still worth knowing: the parser accepts the file as either a
single game-instance object or an array of them (your sample was an array
of one), since I don't know which shape every CurseForge version writes;
and it treats a missing or unparseable file the same as "no CurseForge
data" rather than erroring, so a schema change would make this source
silently stop matching addons instead of breaking the app.

## Project layout

Everything lives flat under `WoWAddonSync/` for a simpler, more robust
hand-written Xcode project file:

- `Murmur2Fingerprint.swift` — content hashing (murmur2), used to notice
  when this Mac's local copy of an addon differs from iCloud's.
- `TocParser.swift` / `AddonScanner.swift` — reads `.toc` files (including
  the `X-WoWI-ID` / `X-Wago-ID` / `X-Website` source-site fields) and
  walks your AddOns folder.
- `WowInterfaceAPI.swift` — the WowInterface client (no key needed).
- `GitHubReleasesAPI.swift` — the GitHub Releases client (no key needed),
  plus `GitHubRepoRef` parsing for both `.toc`-derived and manually
  entered repos.
- `KnownGitHubAddons.swift` — the hand-curated folder-name → GitHub-repo
  fallback table. See "The known-addons list" above.
- `CurseForgeLocalScanAPI.swift` — reads CurseForge's local GameInstances
  scan (not CurseForge's API) and downloads matched releases from its CDN.
  See "CurseForge, without CurseForge's API" above.
- `iCloudAddonStore.swift` — the sync-folder store (manifest.json + synced
  addon folders), rooted at whatever folder `CloudFolderAccess` grants.
  Also lists what's in the sync folder and trashes entries out of it, for
  "In iCloud but not installed on this Mac" above.
- `SyncCoordinator.swift` — the sync logic described above (WowInterface,
  then GitHub Releases, then the CurseForge local scan, then
  iCloud-as-reference; manual overrides take priority over the first two).
  The actual file/network work runs off the main thread (`SyncEngine`) so
  the UI never freezes during a sync.
- `FolderAccess.swift` — three sandbox folder-access types: `FolderAccess`
  for the WoW AddOns folder, `CloudFolderAccess` for the sync folder,
  `CurseForgeFolderAccess` for CurseForge's GameInstances folder (all
  grant-once-via-NSOpenPanel-then-bookmark, same pattern).
- `AppSettings.swift` — auto-sync toggle, device label, and the manual
  WowInterface-ID/GitHub-repo override dictionaries, all in UserDefaults.
- `ContentView.swift` / `AddonRowView.swift` / `SettingsView.swift` /
  `SupportingViews.swift` — the UI.

## Not built yet

You said macOS first — this is macOS/SwiftUI only for now, nothing iOS or
cross-platform. Let me know when you want another machine type and we can
figure out what's shared vs. rebuilt.

A Tukui.org client for its smaller catalog is researched and reasonably
well understood if you want it added later — say the word. Wago.io is
*not* on that list; see "Why not Wago.io" above for why it isn't a
realistic option with its current public API surface.

CurseForge's actual *API* is still deliberately unused — the developer
application process asks for more than it's worth for this project. What
changed is that the CurseForge desktop app's own local scan file turned
out to be a legitimate, key-free way to get real version data for
CurseForge-managed addons anyway; see "CurseForge, without CurseForge's
API" above for exactly what that does and doesn't cover.
