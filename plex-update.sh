#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOKEN_FILE="$SCRIPT_DIR/.plex-token"

API_URL="https://plex.tv/api/downloads/5.json?channel=plexpass"
TMP_DIR="/tmp"
PLEX_PACKAGE="plexmediaserver"
DRY_RUN=false
NON_ROOT=false
INSTALL_MODE=false
PLEX_TOKEN=""
PLATFORM=""

# Platform-specific variables (set by set_platform_constants after detect_platform)
PLATFORM_KEY=""
BUILD=""
DISTRO=""
DIRECT_URL=""
PLEX_APP_PATH="/Applications/Plex Media Server.app"
LAUNCHD_LABEL="com.plexapp.plexmediaserver"
LAUNCHD_PLIST=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

detect_platform() {
    if [[ -n "$PLATFORM" ]]; then
        return  # already set via --platform flag
    fi
    case "$(uname -s)" in
        Darwin) PLATFORM="macos" ;;
        Linux)  PLATFORM="linux" ;;
        *) log "ERROR: Unsupported OS: $(uname -s)"; exit 1 ;;
    esac
}

set_platform_constants() {
    case "$PLATFORM" in
        macos)
            PLATFORM_KEY="MacOS"
            BUILD="darwin-x86_64"
            DISTRO="macos"
            LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
            ;;
        linux)
            PLATFORM_KEY="Linux"
            BUILD="linux-x86_64"
            DISTRO="redhat"
            ;;
        *)
            log "ERROR: Unknown platform: $PLATFORM"
            exit 1
            ;;
    esac
    DIRECT_URL="https://plex.tv/downloads/latest/5?channel=8&build=${BUILD}&distro=${DISTRO}&X-Plex-Token=xxxxxxxxxxxxxxxxxxxx"
}

get_installed_version() {
    if [[ "$PLATFORM" == "macos" ]]; then
        if [[ ! -d "$PLEX_APP_PATH" ]]; then
            return
        fi
        defaults read "${PLEX_APP_PATH}/Contents/Info.plist" CFBundleVersion 2>/dev/null || true
    else
        rpm -qi --nosignature "$PLEX_PACKAGE" 2>/dev/null \
            | awk -F': ' '/^Version/ { print $2 }'
    fi
}

fetch_api() {
    curl -sfL "$API_URL"
}

# Parse the platform-specific release from the API JSON using python3.
parse_latest() {
    local api_json="$1"

    echo "$api_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
platform = data['computer']['${PLATFORM_KEY}']
for r in platform['releases']:
    if r['build'] == '${BUILD}' and r['distro'] == '${DISTRO}':
        print(platform['version'])
        print(r['url'])
        print(r['checksum'])
        break
"
}

parse_latest_jq() {
    local api_json="$1"

    local platform_data
    platform_data=$(echo "$api_json" | jq -r --arg key "$PLATFORM_KEY" '.computer[$key]')

    local version
    version=$(echo "$platform_data" | jq -r '.version')

    local release
    release=$(echo "$platform_data" \
        | jq -r --arg build "$BUILD" --arg distro "$DISTRO" \
            '.releases[] | select(.build == $build and .distro == $distro)')

    local url checksum
    url=$(echo "$release" | jq -r '.url')
    checksum=$(echo "$release" | jq -r '.checksum')

    printf '%s\n%s\n%s\n' "$version" "$url" "$checksum"
}

# Follow the redirect of the direct download endpoint and extract version + URL
# from the resolved filename. Prints "<version>\n<url>" on success, nothing on failure.
fetch_direct() {
    local final_url
    final_url=$(curl -fsL --write-out '%{url_effective}' -o /dev/null "$DIRECT_URL" 2>/dev/null) || return 1

    local version
    if [[ "$PLATFORM" == "macos" ]]; then
        version=$(basename "$final_url" | sed -n 's/PlexMediaServer-\(.*\)-universal\.zip/\1/p')
    else
        version=$(basename "$final_url" | sed -n 's/plexmediaserver-\(.*\)\.x86_64\.rpm/\1/p')
    fi

    [[ -n "$version" ]] && printf '%s\n%s\n' "$version" "$final_url"
}

# Compare two version strings like 1.43.0.10492-121068a07.
# Returns 0 if $1 is newer than $2, 1 otherwise.
version_newer() {
    local latest="$1" installed="$2"

    if [[ "$latest" == "$installed" ]]; then
        return 1
    fi

    # Compare the numeric prefix (e.g. 1.43.0.10492) field by field
    local latest_num installed_num
    latest_num=$(echo "$latest" | cut -d'-' -f1)
    installed_num=$(echo "$installed" | cut -d'-' -f1)

    local IFS='.'
    read -ra lparts <<< "$latest_num"
    read -ra iparts <<< "$installed_num"

    for i in "${!lparts[@]}"; do
        local l="${lparts[$i]:-0}"
        local r="${iparts[$i]:-0}"
        if (( l > r )); then return 0; fi
        if (( l < r )); then return 1; fi
    done

    return 1
}

verify_checksum() {
    local file="$1" expected="$2"
    local actual
    if [[ "$PLATFORM" == "macos" ]]; then
        actual=$(shasum -a 1 "$file" | awk '{print $1}')
    else
        actual=$(sha1sum "$file" | awk '{print $1}')
    fi
    [[ "$actual" == "$expected" ]]
}

load_token() {
    if [[ -f "$TOKEN_FILE" ]]; then
        local raw
        raw=$(cat "$TOKEN_FILE")
        PLEX_TOKEN=$(echo "$raw" | tr -d '[:space:]')
    fi
}

set_token() {
    local token
    token=$(echo "$1" | tr -d '[:space:]')
    if [[ -z "$token" ]]; then
        log "ERROR: --set-token requires a non-empty token value."
        exit 1
    fi
    printf '%s' "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    log "Token saved to $TOKEN_FILE"
    exit 0
}

install_package() {
    local pkg_file="$1"

    if [[ "$PLATFORM" == "macos" ]]; then
        log "Stopping Plex Media Server..."
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true

        local tmp_unzip="$TMP_DIR/plex-update-unzip-$$"
        mkdir -p "$tmp_unzip"
        log "Extracting ${pkg_file}..."
        unzip -q "$pkg_file" -d "$tmp_unzip"

        log "Installing Plex Media Server.app..."
        rm -rf "$PLEX_APP_PATH"
        cp -R "$tmp_unzip/Plex Media Server.app" "$PLEX_APP_PATH"
        rm -rf "$tmp_unzip"

        log "Starting Plex Media Server..."
        launchctl load "$LAUNCHD_PLIST"
    else
        rpm -Uvh --nosignature "$pkg_file"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -i, --install       Initial install; errors if Plex is already installed
      --dry-run       Show what would happen without making changes
      --platform VAL  Override platform detection (linux or macos)
      --set-token TOK Save a Plex token for PlexPass downloads
  -h, --help          Show this help message
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set-token)
                if [[ $# -lt 2 ]]; then
                    log "ERROR: --set-token requires a non-empty token value."
                    exit 1
                fi
                set_token "$2"
                ;;
            --dry-run) DRY_RUN=true ;;
            --platform)
                if [[ $# -lt 2 ]]; then
                    log "ERROR: --platform requires a value (linux or macos)."
                    exit 1
                fi
                PLATFORM="$2"
                shift
                ;;
            *) log "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done

    detect_platform
    set_platform_constants

    if [[ "$PLATFORM" == "linux" && $EUID -ne 0 ]]; then
        NON_ROOT=true
    elif [[ "$PLATFORM" == "macos" && ! -w "/Applications" ]]; then
        NON_ROOT=true
        log "No write access to /Applications; will show what would happen without making changes."
    fi

    load_token
    if [[ -n "$PLEX_TOKEN" ]]; then
        API_URL="${API_URL}&X-Plex-Token=${PLEX_TOKEN}"
        DIRECT_URL="${DIRECT_URL/xxxxxxxxxxxxxxxxxxxx/$PLEX_TOKEN}"
    fi

    log "Checking installed Plex version..."
    local installed_version
    installed_version=$(get_installed_version)

    if [[ -z "$installed_version" ]]; then
        log "Plex Media Server is not installed."
        exit 1
    fi
    log "Installed version: $installed_version"

    log "Fetching latest release info from Plex API..."
    local api_json
    api_json=$(fetch_api)

    local parsed
    if command -v jq &>/dev/null; then
        parsed=$(parse_latest_jq "$api_json")
    else
        parsed=$(parse_latest "$api_json")
    fi

    local latest_version download_url checksum
    latest_version=$(echo "$parsed" | sed -n '1p')
    download_url=$(echo "$parsed" | sed -n '2p')
    checksum=$(echo "$parsed" | sed -n '3p')

    if [[ -z "$latest_version" || -z "$download_url" ]]; then
        log "ERROR: Failed to parse API response."
        exit 1
    fi
    log "API version: $latest_version"

    if [[ -z "$PLEX_TOKEN" ]]; then
        log "No Plex token found; skipping direct download check."
    else
        log "Checking direct download endpoint for newer build..."
        local direct_parsed direct_version direct_url
        direct_parsed=$(fetch_direct) || true
        if [[ -n "$direct_parsed" ]]; then
            direct_version=$(echo "$direct_parsed" | sed -n '1p')
            direct_url=$(echo "$direct_parsed" | sed -n '2p')
            log "Direct endpoint version: $direct_version"
            if version_newer "$direct_version" "$latest_version"; then
                log "Direct endpoint has a newer build; using it (no checksum available)."
                latest_version="$direct_version"
                download_url="$direct_url"
                checksum=""
                log "Latest version: $latest_version"
            fi
        else
            log "Direct endpoint check failed or returned no version; falling back to API."
        fi
    fi

    if ! version_newer "$latest_version" "$installed_version"; then
        log "Already up to date."
        exit 0
    fi

    local pkg_filename
    if [[ "$PLATFORM" == "macos" ]]; then
        pkg_filename="PlexMediaServer-${latest_version}-universal.zip"
    else
        pkg_filename="${PLEX_PACKAGE}-${latest_version}.x86_64.rpm"
    fi

    if $DRY_RUN || $NON_ROOT; then
        log "[DRY-RUN] Would download: $download_url"
        log "[DRY-RUN] Would install: ${pkg_filename}"
        if $NON_ROOT && ! $DRY_RUN; then
            if [[ "$PLATFORM" == "macos" ]]; then
                log "No write access to /Applications; no changes were made. Re-run with sudo to apply the update."
            else
                log "Not running as root; no changes were made. Re-run as root to apply the update."
            fi
        fi
        exit 0
    fi

    local pkg_file="$TMP_DIR/${pkg_filename}"

    log "Downloading $download_url ..."
    curl -fL -o "$pkg_file" "$download_url"

    if [[ -n "$checksum" ]]; then
        log "Verifying checksum..."
        if ! verify_checksum "$pkg_file" "$checksum"; then
            log "ERROR: Checksum mismatch. Removing downloaded file."
            rm -f "$pkg_file"
            exit 1
        fi
        log "Checksum OK."
    else
        log "No checksum available for this build; skipping verification."
    fi

    log "Installing ${pkg_file}..."
    install_package "$pkg_file"

    log "Cleaning up..."
    rm -f "$pkg_file"

    log "Plex Media Server updated to $latest_version."
}

main "$@"
