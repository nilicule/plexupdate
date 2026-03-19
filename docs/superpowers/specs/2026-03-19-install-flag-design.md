# Design: `--install` / `-i` Flag and `--help`

**Date:** 2026-03-19
**File:** `plex-update.sh`

---

## Overview

Add `-i` / `--install` for first-time installation and `--help` for usage output.

Currently the script exits early with "Plex Media Server is not installed." when no installed version is found. With `--install`, it proceeds to fetch and install the latest version instead. If Plex is already installed and `--install` is passed, the script errors — the flag is strictly for fresh installs.

---

## Changes

### 1. New global

```bash
INSTALL_MODE=false
```

### 2. Argument parsing

Add to the `while` loop in `main()`:

```bash
-i|--install) INSTALL_MODE=true ;;
--help) usage; exit 0 ;;
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
      --help          Show this help message
EOF
}
```

### 4. Version check gate

Replace the existing two-line early-exit block:

```bash
if [[ -z "$installed_version" ]]; then
    log "Plex Media Server is not installed."
    exit 1
fi
```

With a three-way branch:

```bash
if [[ -n "$installed_version" && "$INSTALL_MODE" == true ]]; then
    log "ERROR: Plex Media Server is already installed ($installed_version). Run without --install to update."
    exit 1
elif [[ -z "$installed_version" && "$INSTALL_MODE" == false ]]; then
    log "Plex Media Server is not installed."
    exit 1
elif [[ -z "$installed_version" && "$INSTALL_MODE" == true ]]; then
    installed_version="0"
fi
```

Setting `installed_version="0"` means `version_newer` will return true for any real version, so the download/install flow proceeds unchanged.

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

- `--install --dry-run`: works — shows what would be downloaded/installed without touching anything
- `--install` + non-root / no `/Applications` write access on macOS: `NON_ROOT=true` path taken, dry-run output shown
- No changes to download, checksum, or install logic
