#!/bin/bash
#
# install.sh — build WoWAddonSync and install it into /Applications,
# replacing whatever's already there.
#
# Signing: the app is sandboxed, and its two folder grants (the WoW AddOns
# folder and the iCloud sync folder) are security-scoped bookmarks, which
# only work if the sandbox entitlements are actually attached to the
# signature. This script signs ad-hoc by default — the same thing Xcode's
# "Sign to Run Locally" does, and what every build of this app so far has
# used, since it needs no certificate and no Apple Developer membership.
# The build is verified afterwards and the install is aborted if the
# sandbox entitlement didn't make it in, because that failure is otherwise
# silent: the app launches fine and then can't read either folder.
#
# Your settings and folder grants live in the app's container, keyed by
# bundle identifier, so replacing the bundle keeps them. If macOS does
# decide a re-signed build is a different app and drops the grants, the
# only cost is re-picking the two folders in Settings — nothing is lost.
#
# Run ./install.sh --help for options.
#

set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT="$REPO_DIR/WoWAddonSync.xcodeproj"
readonly SCHEME="WoWAddonSync"
# Kept outside the repo so repeat installs are incremental without
# leaving build products next to the source.
readonly DERIVED_DATA="$HOME/Library/Caches/WoWAddonSync-install"

configuration="Release"
dest_dir="/Applications"
sign_identity="-"
prebuilt_app=""
do_build=1
do_clean=0
do_open=0
universal=0
force=0

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# PlistBuddy reports a missing file on *stdout* ("File Doesn't Exist, Will
# Create: ...") rather than stderr, so reading a key straight into a
# variable can capture that complaint as if it were the value. Check the
# file first and return empty on any failure.
plist_value() {
    local plist="$1" key="$2"
    [[ -f "$plist" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Builds WoWAddonSync and installs it into /Applications, moving any existing
copy to the Trash first.

Options:
  --debug              Build the Debug configuration instead of Release.
  --universal          Build for both arm64 and x86_64, so the same bundle
                       runs on Intel Macs too. Slower; the default builds
                       only for this Mac's architecture.
  --clean              Discard the cached build products and build fresh.
  --sign IDENTITY      Codesign identity to use. Defaults to "-" (ad-hoc),
                       which needs no certificate. Pass a name from
                       `security find-identity -v -p codesigning` if you
                       have a real one.
  --app PATH           Install an already-built .app instead of building.
  --dest DIR           Install into DIR instead of /Applications.
  --open               Launch the app once it's installed.
  --force              Replace whatever is at the destination even if it
                       isn't this app. Off by default.
  -h, --help           Show this.

Examples:
  ./install.sh                      # build Release, install to /Applications
  ./install.sh --universal --open   # build for both Macs, then launch it
  ./install.sh --app ~/Desktop/WoWAddonSync.app
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)     configuration="Debug"; shift ;;
        --release)   configuration="Release"; shift ;;
        --universal) universal=1; shift ;;
        --clean)     do_clean=1; shift ;;
        --open)      do_open=1; shift ;;
        --force)     force=1; shift ;;
        --sign)      sign_identity="${2:?--sign needs an identity}"; shift 2 ;;
        --app)       prebuilt_app="${2:?--app needs a path}"; do_build=0; shift 2 ;;
        --dest)      dest_dir="${2:?--dest needs a directory}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------- build

if [[ $do_build -eq 1 ]]; then
    [[ $EUID -ne 0 ]] || die "don't build as root — run this without sudo. If the install step needs privileges it'll ask for them on its own."
    [[ -d "$PROJECT" ]] || die "no Xcode project at $PROJECT"
    command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
    xcodebuild -version >/dev/null 2>&1 || die "xcodebuild found but not usable. Open Xcode once to finish its first-run setup, or: sudo xcode-select -s /Applications/Xcode.app"

    if [[ $do_clean -eq 1 ]]; then
        step "Clearing cached build products"
        rm -rf "$DERIVED_DATA"
    fi

    build_args=(
        -project "$PROJECT"
        -scheme "$SCHEME"
        -configuration "$configuration"
        -destination 'platform=macOS'
        -derivedDataPath "$DERIVED_DATA"
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$sign_identity"
        CODE_SIGNING_REQUIRED=YES
        CODE_SIGNING_ALLOWED=YES
        DEVELOPMENT_TEAM=""
    )
    if [[ $universal -eq 1 ]]; then
        build_args+=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
    fi

    step "Building $SCHEME ($configuration$([[ $universal -eq 1 ]] && echo ", universal"))"
    note "this takes a minute; full output is in $DERIVED_DATA/build.log"
    mkdir -p "$DERIVED_DATA"

    # Xcode's out-of-process macro host (swift-plugin-server, which expands
    # the #Preview macros in ContentView/SettingsView) sometimes fails with
    # "produced malformed response" instead of compiling. Every occurrence
    # so far was inside a sandboxed automation environment, where the
    # plugin host can't get at something it needs; a normal Terminal build
    # may never hit it. It isn't a code error either way — the identical
    # command succeeds on a rerun — so it's worth one cheap retry, with any
    # stray plugin host cleared first. Only ever retried for that specific
    # message, so a genuine compile error still fails on the first attempt.
    build_attempt() {
        xcodebuild "${build_args[@]}" build >"$DERIVED_DATA/build.log" 2>&1
    }
    build_failed() {
        grep -E "error:" "$DERIVED_DATA/build.log" | sort -u | head -20 >&2 || true
        die "build failed — see $DERIVED_DATA/build.log"
    }
    if ! build_attempt; then
        grep -q "swift-plugin-server" "$DERIVED_DATA/build.log" || build_failed
        note "Xcode's Swift macro plugin host misbehaved; clearing it and rebuilding once"
        pkill -f swift-plugin-server 2>/dev/null || true
        sleep 2
        build_attempt || build_failed
    fi

    app="$DERIVED_DATA/Build/Products/$configuration/WoWAddonSync.app"
else
    app="$prebuilt_app"
fi

[[ -d "$app" ]] || die "no app bundle at $app"

# ------------------------------------------------------- verify the build

step "Verifying the built app"

bundle_id="$(plist_value "$app/Contents/Info.plist" CFBundleIdentifier)"
[[ -n "$bundle_id" ]] || die "$app has no readable Info.plist — that isn't an app bundle"

codesign --verify --strict "$app" 2>/dev/null \
    || die "$app isn't validly signed. Try: ./install.sh --clean"

# Captured into variables rather than piped into `grep -q`: with
# `set -o pipefail`, grep exiting early on a match SIGPIPEs codesign, and
# the pipeline then reports the *producer's* failure even though the match
# succeeded. On the entitlement check below that would abort a perfectly
# good install.
app_entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
app_signature="$(codesign -dv "$app" 2>&1 || true)"

# The check this whole script exists for. An app built with
# CODE_SIGNING_ALLOWED=NO launches perfectly well and then silently can't
# hold onto either folder grant, which looks like an app bug rather than a
# packaging one.
if [[ "$app_entitlements" != *"com.apple.security.app-sandbox"* ]]; then
    die "the built app has no app-sandbox entitlement, so its folder grants wouldn't survive a relaunch. Refusing to install it."
fi

if [[ "$app_signature" == *"Signature=adhoc"* ]]; then
    signed_as="ad-hoc signed"
else
    signed_as="signed as $sign_identity"
fi
note "$bundle_id, $signed_as, $(lipo -archs "$app/Contents/MacOS/WoWAddonSync" 2>/dev/null || echo "unknown arch")"

# ------------------------------------------------------------- install

dest="$dest_dir/$(basename "$app")"

[[ -d "$dest_dir" ]] || die "$dest_dir doesn't exist"

# /Applications is normally group-writable by admin, so this usually stays
# empty. Only the copy itself is ever elevated — never the build.
sudo_cmd=""
if [[ ! -w "$dest_dir" ]]; then
    sudo_cmd="sudo"
    note "$dest_dir isn't writable by $(whoami); the install step will ask for your password."
fi

if [[ -e "$dest" ]]; then
    existing_id="$(plist_value "$dest/Contents/Info.plist" CFBundleIdentifier)"
    if [[ "$existing_id" != "$bundle_id" && $force -eq 0 ]]; then
        die "$dest already exists but is '${existing_id:-not an app bundle}', not '$bundle_id'. Pass --force to replace it anyway."
    fi

    if pgrep -x "WoWAddonSync" >/dev/null 2>&1; then
        step "Quitting the running copy"
        # Ask nicely first so it gets to flush its preferences; escalate
        # only if it doesn't go. The AppleScript needs Automation consent
        # and may be declined — that's fine, the signals below still work.
        osascript -e "quit app id \"$bundle_id\"" >/dev/null 2>&1 || true
        for _ in $(seq 20); do
            pgrep -x "WoWAddonSync" >/dev/null 2>&1 || break
            sleep 0.25
        done
        if pgrep -x "WoWAddonSync" >/dev/null 2>&1; then
            pkill -x "WoWAddonSync" || true
            sleep 1
            pkill -9 -x "WoWAddonSync" 2>/dev/null || true
        fi
    fi

    # To the Trash rather than rm -rf: the app itself never permanently
    # deletes anything, and neither should the thing that installs it.
    trashed="$HOME/.Trash/WoWAddonSync $(date '+%Y-%m-%d %H.%M.%S').app"
    step "Moving the existing copy to the Trash"
    note "$trashed"
    $sudo_cmd mv "$dest" "$trashed"
    [[ -z "$sudo_cmd" ]] || $sudo_cmd chown -R "$(id -u):$(id -g)" "$trashed"
fi

step "Installing to $dest"
# ditto rather than cp -R, to carry the bundle's metadata across intact.
$sudo_cmd ditto "$app" "$dest"

# So Finder, Spotlight and `open -a` see the new copy immediately.
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$dest" >/dev/null 2>&1 || true

codesign --verify --strict "$dest" 2>/dev/null \
    || die "the installed copy at $dest doesn't verify — something went wrong copying it"

version="$(plist_value "$dest/Contents/Info.plist" CFBundleShortVersionString)"
step "Installed${version:+ version $version}"
note "$dest"

if [[ $do_open -eq 1 ]]; then
    step "Launching"
    open "$dest"
else
    note "Launch it with: open \"$dest\""
fi
