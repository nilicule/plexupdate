# Design: `--install` / `-i` Flag and `--help`

**Date:** 2026-03-19
**File:** `plex-update.sh`

---

## Overview

Add `-i` / `--install` for first-time installation, and `--help` / `-h` for usage output.

Currently the script exits early with "Plex Media Server is not installed." when no installed version is found. With `--install`, it proceeds to fetch and install the latest version instead. If Plex is already installed and `--install` is passed, the script errors — the flag is strictly for fresh installs.

---

## Changes

### 1. New global

Add immediately after `DRY_RUN=false` at the top of the script:

```bash
INSTALL_MODE=false
```

### 2. Argument parsing

Add to the `while` loop in `main()`. Both are standalone flags (no value argument), so no inner `shift` is needed — the outer `shift` at the bottom of the loop handles them, exactly the same pattern as `--dry-run`:

```bash
-i|--install) INSTALL_MODE=true ;;
-h|--help) usage; exit 0 ;;
```

### 3. `usage()` function

New function, placed before `main()`:

```bash
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
```

### 4. Version check gate

Replace the existing early-exit block and its following log line:

```bash
if [[ -z "$installed_version" ]]; then
    log "Plex Media Server is not installed."
    exit 1
fi
log "Installed version: $installed_version"
```

With a three-way branch that subsumes the log line:

```bash
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
```

**Why `"0"` is safe as a sentinel:** `version_newer` splits on `.` and compares field by field. `iparts` becomes `("0")`. Real Plex versions always start with a major component `≥ 1` (e.g. `1.43.0.10492`), so `version_newer` always returns true. The existing non-empty check for `latest_version` a few lines later already prevents a `"0"` vs `"0"` tie.

### 5. macOS `launchctl load` guard in `install_package()`

The existing `launchctl unload ... 2>/dev/null || true` at the top of the macOS path is already safe — it no-ops silently if the plist is absent.

The `launchctl load` at the end currently runs unconditionally. Replace it with a three-way guard that:
- On a normal update: plist should always exist → load it (behaviour unchanged)
- On a fresh install: plist does not exist yet → print friendly guidance
- On an update where plist is unexpectedly missing: warn without crashing (safer than the current `set -e` crash)

```bash
if [[ -f "$LAUNCHD_PLIST" ]]; then
    log "Starting Plex Media Server..."
    launchctl load "$LAUNCHD_PLIST"
elif [[ "$INSTALL_MODE" == true ]]; then
    log "Plex Media Server installed. Open it once to register the LaunchAgent, then it will start automatically."
else
    log "WARNING: LaunchAgent plist not found at $LAUNCHD_PLIST; Plex may not start automatically."
fi
```

---

## Behaviour Matrix

| Installed | `--install` | Result |
|-----------|-------------|--------|
| yes       | no          | normal update run |
| yes       | yes         | error: already installed |
| no        | no          | error: not installed |
| no        | yes         | install latest version |

---

## Compatibility

- `--install --dry-run` (any privilege): `DRY_RUN=true` takes precedence; prints `[DRY-RUN] Would download/install` lines and exits 0. The "Re-run as root/sudo" message is suppressed because `if $NON_ROOT && ! $DRY_RUN` is false.
- `--install` without `--dry-run`, non-root (Linux) or no `/Applications` write (macOS): `NON_ROOT=true`, `DRY_RUN=false` → dry-run lines printed, then "Re-run as root / with sudo" message printed, exits 0.
- Any unrecognised argument hits the existing `*) log "Unknown option"; exit 1 ;;` catch-all — no change needed.

**Known limitation:** macOS zip extraction assumes the archive contains `Plex Media Server.app` at its root. A corrupt zip would leave no app installed. This is a pre-existing limitation, out of scope for this feature.
