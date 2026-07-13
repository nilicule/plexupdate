#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOKEN_FILE="$SCRIPT_DIR/.plex-token"
CLIENT_ID_FILE="$SCRIPT_DIR/.plex-client-id"
PLEX_PRODUCT="plex-update"

API_URL="https://plex.tv/api/downloads/5.json?channel=plexpass"
PUBLIC_API_URL="https://plex.tv/api/downloads/5.json"
TMP_DIR="/tmp"
PLEX_PACKAGE="plexmediaserver"
DRY_RUN=false
LIST_VERSIONS=false
NON_ROOT=false
INSTALL_MODE=false
PLEX_TOKEN=""
CLIENT_ID=""
PLATFORM=""

PLATFORM_KEY=""
BUILD=""
DISTRO=""
PLEX_APP_PATH="/Applications/Plex Media Server.app"
PLEX_MACOS_BINARY="Plex Media Server.app/Contents/MacOS/Plex Media Server"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

detect_platform() {
    if [[ -n "$PLATFORM" ]]; then
        return
    fi
    local os
    os=$(uname -s)
    case "$os" in
        Darwin) PLATFORM="macos" ;;
        Linux)  PLATFORM="linux" ;;
        *) log "ERROR: Unsupported OS: $os"; exit 1 ;;
    esac
}

set_platform_constants() {
    case "$PLATFORM" in
        macos)
            PLATFORM_KEY="MacOS"
            BUILD="darwin-x86_64"
            DISTRO="macos"
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
    if [[ -n "$PLEX_TOKEN" ]]; then
        curl -sfL "${API_URL}&X-Plex-Token=${PLEX_TOKEN}"
    else
        curl -sfL "$API_URL"
    fi
}

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
    jq -r --arg key "$PLATFORM_KEY" --arg build "$BUILD" --arg distro "$DISTRO" \
        '.computer[$key] | .version, (.releases[] | select(.build==$build and .distro==$distro) | .url, .checksum)' \
        <<< "$api_json"
}

parse_release() {
    local api_json="$1"
    if command -v jq &>/dev/null; then
        parse_latest_jq "$api_json" || true
    else
        parse_latest "$api_json" || true
    fi
}

# Returns 0 if $1 is newer than $2, 1 otherwise.
version_newer() {
    local latest="$1" installed="$2"

    if [[ "$latest" == "$installed" ]]; then
        return 1
    fi

    local latest_num="${latest%%-*}"
    local installed_num="${installed%%-*}"

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

write_secret_file() {
    printf '%s' "$2" > "$1"
    chmod 600 "$1"
}

load_token() {
    if [[ -f "$TOKEN_FILE" ]]; then
        PLEX_TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
    fi
}

validate_token() {
    if [[ -z "$PLEX_TOKEN" ]]; then
        return
    fi
    local http_status
    http_status=$(curl -o /dev/null -sw '%{http_code}' \
        -H "X-Plex-Token: $PLEX_TOKEN" \
        -H "Accept: application/json" \
        "https://plex.tv/api/v2/user")
    if [[ "$http_status" == "401" ]]; then
        log "WARNING: Stored Plex token is invalid or expired. Run --login to re-authenticate."
        PLEX_TOKEN=""
    fi
}

load_or_create_client_id() {
    if [[ -f "$CLIENT_ID_FILE" ]]; then
        CLIENT_ID=$(tr -d '[:space:]' < "$CLIENT_ID_FILE")
    else
        CLIENT_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
        write_secret_file "$CLIENT_ID_FILE" "$CLIENT_ID"
    fi
}

fetch_and_display_version() {
    local label="$1" url="$2" fallback_msg="$3"
    local json parsed version pkg_url
    if json=$(curl -sfL "$url" 2>/dev/null); then
        parsed=$(parse_release "$json")
        { read -r version; read -r pkg_url; } <<< "$parsed"
        printf '  %-12s %s\n' "${label}:" "$version"
        printf '  %-12s %s\n' "" "$pkg_url"
    else
        printf '  %-12s %s\n' "${label}:" "$fallback_msg"
    fi
}

list_versions() {
    load_token
    validate_token

    echo "Available Plex versions for ${PLATFORM} (${BUILD}/${DISTRO}):"
    echo ""
    fetch_and_display_version "Public" "$PUBLIC_API_URL" "(failed to fetch)"
    echo ""
    if [[ -n "$PLEX_TOKEN" ]]; then
        fetch_and_display_version "PlexPass" "${API_URL}&X-Plex-Token=${PLEX_TOKEN}" "(failed to fetch)"
    else
        printf '  %-12s %s\n' "PlexPass:" "(no token — run --login to authenticate)"
    fi
}

plex_login() {
    load_or_create_client_id

    local pin_response
    pin_response=$(curl -sfL -X POST "https://plex.tv/api/v2/pins" \
        -H "Accept: application/json" \
        -H "X-Plex-Product: $PLEX_PRODUCT" \
        -H "X-Plex-Client-Identifier: $CLIENT_ID" \
        --data-urlencode "strong=true")

    local pin_id pin_code
    { read -r pin_id; read -r pin_code; } < <(echo "$pin_response" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['id']); print(d['code'])")

    local auth_url="https://app.plex.tv/auth#?clientID=${CLIENT_ID}&code=${pin_code}&context[device][product]=${PLEX_PRODUCT}"
    log "Open this URL in a browser to authenticate with Plex:"
    echo ""
    echo "  $auth_url"
    echo ""
    log "Waiting for authentication (press Ctrl-C to cancel)..."

    local token=""
    local attempts=0
    while [[ $attempts -lt 100 ]]; do
        sleep 3
        local poll_response
        poll_response=$(curl -sfL "https://plex.tv/api/v2/pins/${pin_id}" \
            -H "Accept: application/json" \
            -H "X-Plex-Product: $PLEX_PRODUCT" \
            -H "X-Plex-Client-Identifier: $CLIENT_ID")
        token=$(echo "$poll_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('authToken') or '')" 2>/dev/null || true)
        if [[ -n "$token" ]]; then
            break
        fi
        attempts=$(( attempts + 1 ))
    done

    if [[ -z "$token" ]]; then
        log "ERROR: Authentication timed out. Run --login again."
        exit 1
    fi

    write_secret_file "$TOKEN_FILE" "$token"
    log "Authentication successful. Token saved to $TOKEN_FILE"
    exit 0
}

set_token() {
    local token="${1//[[:space:]]/}"
    if [[ -z "$token" ]]; then
        log "ERROR: --set-token requires a non-empty token value."
        exit 1
    fi
    write_secret_file "$TOKEN_FILE" "$token"
    log "Token saved to $TOKEN_FILE"
    exit 0
}

stop_plex_macos() {
    # Plex on macOS is a GUI app, not a launchd service. Ask it to quit
    # gracefully via an Apple event, then force-kill anything left behind.
    if ! pgrep -f "$PLEX_MACOS_BINARY" >/dev/null 2>&1; then
        return
    fi
    log "Stopping Plex Media Server..."
    osascript -e 'quit app "Plex Media Server"' >/dev/null 2>&1 || true

    local i
    for i in $(seq 1 15); do
        pgrep -f "$PLEX_MACOS_BINARY" >/dev/null 2>&1 || return
        sleep 1
    done

    pkill -f "$PLEX_MACOS_BINARY" 2>/dev/null || true
    sleep 1
}

start_plex_macos() {
    # Launching the app also (re)registers its login item, so it keeps
    # starting automatically after a reboot.
    log "Starting Plex Media Server..."
    open -a "$PLEX_APP_PATH"
}

install_package() {
    local pkg_file="$1"

    if [[ "$PLATFORM" == "macos" ]]; then
        stop_plex_macos

        local tmp_unzip="$TMP_DIR/plex-update-unzip-$$"
        mkdir -p "$tmp_unzip"
        log "Extracting ${pkg_file}..."
        unzip -q "$pkg_file" -d "$tmp_unzip"

        log "Installing Plex Media Server.app..."
        rm -rf "$PLEX_APP_PATH"
        cp -R "$tmp_unzip/Plex Media Server.app" "$PLEX_APP_PATH"
        rm -rf "$tmp_unzip"

        start_plex_macos
    else
        rpm -Uvh --nosignature "$pkg_file"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -i, --install        Initial install; errors if Plex is already installed
      --dry-run        Show what would happen without making changes
      --list-versions  Show available versions from both public and PlexPass channels
      --platform VAL   Override platform detection (linux or macos)
      --login          Authenticate with Plex via browser (PIN flow) and save token
      --set-token TOK  Save a Plex token manually (advanced)
  -h, --help           Show this help message
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --login)
                plex_login
                ;;
            --set-token)
                if [[ $# -lt 2 ]]; then
                    log "ERROR: --set-token requires a non-empty token value."
                    exit 1
                fi
                set_token "$2"
                ;;
            --dry-run) DRY_RUN=true ;;
            --list-versions) LIST_VERSIONS=true ;;
            -i|--install) INSTALL_MODE=true ;;
            -h|--help) usage; exit 0 ;;
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

    if $LIST_VERSIONS; then
        list_versions
        exit 0
    fi

    if [[ "$PLATFORM" == "linux" && $EUID -ne 0 ]]; then
        NON_ROOT=true
    elif [[ "$PLATFORM" == "macos" && ! -w "/Applications" ]]; then
        NON_ROOT=true
        log "No write access to /Applications; will show what would happen without making changes."
    fi

    load_token
    validate_token

    log "Checking installed Plex version..."
    local installed_version
    installed_version=$(get_installed_version)

    if [[ -n "$installed_version" ]] && $INSTALL_MODE; then
        log "ERROR: Plex Media Server is already installed ($installed_version). Run without --install to update."
        exit 1
    fi
    if [[ -z "$installed_version" ]] && ! $INSTALL_MODE; then
        log "Plex Media Server is not installed."
        exit 1
    fi
    if [[ -z "$installed_version" ]]; then
        log "No version installed; will install latest."
        installed_version="0"
    else
        log "Installed version: $installed_version"
    fi

    log "Fetching latest release info from Plex API..."
    local api_json
    if ! api_json=$(fetch_api); then
        log "ERROR: Failed to fetch API response. Check network connectivity and your Plex token."
        exit 1
    fi

    local parsed
    parsed=$(parse_release "$api_json")

    local latest_version download_url checksum
    { read -r latest_version; read -r download_url; read -r checksum; } <<< "$parsed"

    if [[ -z "$latest_version" || -z "$download_url" ]]; then
        log "ERROR: Failed to parse API response."
        exit 1
    fi
    log "API version: $latest_version"

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
    curl -fL --progress-bar -o "$pkg_file" "$download_url"

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
