#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOKEN_FILE="$SCRIPT_DIR/.plex-token"

API_URL="https://plex.tv/api/downloads/5.json?channel=plexpass"
DIRECT_URL="https://plex.tv/downloads/latest/5?channel=8&build=linux-x86_64&distro=redhat&X-Plex-Token=xxxxxxxxxxxxxxxxxxxx"
TMP_DIR="/tmp"
PLEX_PACKAGE="plexmediaserver"
DRY_RUN=false
NON_ROOT=false
PLEX_TOKEN=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

get_installed_version() {
    rpm -qi --nosignature "$PLEX_PACKAGE" 2>/dev/null \
        | awk -F': ' '/^Version/ { print $2 }'
}

fetch_api() {
    curl -sfL "$API_URL"
}

# Parse the linux x86_64 redhat release from the API JSON.
# Uses sed/grep to avoid a jq dependency, matching the specific releases entry.
parse_latest() {
    local api_json="$1"

    latest_version=$(echo "$api_json" \
        | grep -o '"id": *"linux"[^}]*' \
        | head -1)
    # The version lives at the Linux platform level, before the releases array
    latest_version=$(echo "$api_json" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
linux = data['computer']['Linux']
for r in linux['releases']:
    if r['build'] == 'linux-x86_64' and r['distro'] == 'redhat':
        print(linux['version'])
        print(r['url'])
        print(r['checksum'])
        break
")
    # This is a Bash project, but parsing nested JSON reliably without jq
    # is fragile. Let's check for jq and fall back to python3 only if needed.
    echo "$latest_version"
}

parse_latest_jq() {
    local api_json="$1"

    local linux
    linux=$(echo "$api_json" | jq -r '.computer.Linux')

    local version
    version=$(echo "$linux" | jq -r '.version')

    local release
    release=$(echo "$linux" \
        | jq -r '.releases[] | select(.build == "linux-x86_64" and .distro == "redhat")')

    local url checksum
    url=$(echo "$release" | jq -r '.url')
    checksum=$(echo "$release" | jq -r '.checksum')

    printf '%s\n%s\n%s\n' "$version" "$url" "$checksum"
}

# Follow the redirect of the direct download endpoint and extract version + URL
# from the resolved filename (e.g. plexmediaserver-1.43.0.10492-abc.x86_64.rpm).
# Prints "<version>\n<url>" on success, outputs nothing on failure.
fetch_direct() {
    local final_url
    final_url=$(curl -fsL --write-out '%{url_effective}' -o /dev/null "$DIRECT_URL" 2>/dev/null) || return 1

    local version
    version=$(basename "$final_url" | sed -n 's/plexmediaserver-\(.*\)\.x86_64\.rpm/\1/p')

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
    actual=$(sha1sum "$file" | awk '{print $1}')
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

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set-token)
                if [[ $# -lt 2 ]]; then
                    log "ERROR: --set-token requires a non-empty token value."
                    exit 1
                fi
                set_token "$2"
                shift
                ;;
            --dry-run) DRY_RUN=true; shift ;;
            *) log "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done

    if [[ $EUID -ne 0 ]]; then
        NON_ROOT=true
        log "Not running as root; will show what would happen without making changes."
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

    if $DRY_RUN || $NON_ROOT; then
        log "[DRY-RUN] Would download: $download_url"
        log "[DRY-RUN] Would install: ${PLEX_PACKAGE}-${latest_version}.x86_64.rpm"
        if $NON_ROOT && ! $DRY_RUN; then
            log "Not running as root; no changes were made. Re-run as root to apply the update."
        fi
        exit 0
    fi

    local rpm_file="$TMP_DIR/${PLEX_PACKAGE}-${latest_version}.x86_64.rpm"

    log "Downloading $download_url ..."
    curl -fL -o "$rpm_file" "$download_url"

    if [[ -n "$checksum" ]]; then
        log "Verifying checksum..."
        if ! verify_checksum "$rpm_file" "$checksum"; then
            log "ERROR: Checksum mismatch. Removing downloaded file."
            rm -f "$rpm_file"
            exit 1
        fi
        log "Checksum OK."
    else
        log "No checksum available for this build; skipping verification."
    fi

    log "Installing ${rpm_file}..."
    rpm -Uvh --nosignature "$rpm_file"

    log "Cleaning up..."
    rm -f "$rpm_file"

    log "Plex Media Server updated to $latest_version."
}

main "$@"
