#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOKEN_FILE="$SCRIPT_DIR/.plex-token"
CLIENT_ID_FILE="$SCRIPT_DIR/.plex-client-id"
PLEX_PRODUCT="plex-update"

API_URL="https://plex.tv/api/downloads/5.json?channel=plexpass"
TMP_DIR="/tmp"
PLEX_PACKAGE="plexmediaserver"
DRY_RUN=false
NON_ROOT=false
INSTALL_MODE=false
PLEX_TOKEN=""
CLIENT_ID=""
PLATFORM=""

# Platform-specific variables (set by set_platform_constants after detect_platform)
PLATFORM_KEY=""
BUILD=""
DISTRO=""
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
        curl -sfL -H "X-Plex-Token: $PLEX_TOKEN" "$API_URL"
    else
        curl -sfL "$API_URL"
    fi
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
        printf '%s' "$CLIENT_ID" > "$CLIENT_ID_FILE"
        chmod 600 "$CLIENT_ID_FILE"
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
    pin_id=$(echo "$pin_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])")
    pin_code=$(echo "$pin_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['code'])")

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
        (( attempts++ ))
    done

    if [[ -z "$token" ]]; then
        log "ERROR: Authentication timed out. Run --login again."
        exit 1
    fi

    printf '%s' "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    log "Authentication successful. Token saved to $TOKEN_FILE"
    exit 0
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

        if [[ -f "$LAUNCHD_PLIST" ]]; then
            log "Starting Plex Media Server..."
            launchctl load "$LAUNCHD_PLIST"
        elif [[ "$INSTALL_MODE" == true ]]; then
            log "Plex Media Server installed. Open it once to register the LaunchAgent, then it will start automatically."
        else
            log "WARNING: LaunchAgent plist not found at $LAUNCHD_PLIST; Plex may not start automatically."
        fi
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
      --login         Authenticate with Plex via browser (PIN flow) and save token
      --set-token TOK Save a Plex token manually (advanced)
  -h, --help          Show this help message
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

    if [[ -n "$installed_version" && "$INSTALL_MODE" == true ]]; then
        log "ERROR: Plex Media Server is already installed ($installed_version). Run without --install to update."
        exit 1
    elif [[ -z "$installed_version" && "$INSTALL_MODE" == false ]]; then
        log "Plex Media Server is not installed."
        exit 1
    elif [[ -z "$installed_version" && "$INSTALL_MODE" == true ]]; then
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
    if command -v jq &>/dev/null; then
        parsed=$(parse_latest_jq "$api_json") || true
    else
        parsed=$(parse_latest "$api_json") || true
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
