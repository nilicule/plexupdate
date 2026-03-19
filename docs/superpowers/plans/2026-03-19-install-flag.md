# Install Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `-i`/`--install` for first-time Plex installation and `-h`/`--help` for usage output.

**Architecture:** All changes are in `plex-update.sh`. Four small, sequential edits: add a global + `usage()`, extend the argument parser, replace the installed-version early-exit with a three-way branch, and guard `launchctl load` in `install_package()`.

**Tech Stack:** Bash 4+, shellcheck for static analysis.

---

## File to Modify

- `plex-update.sh` — sole entry point, all changes here

---

### Task 1: Add `INSTALL_MODE` global and `usage()` function

**Files:**
- Modify: `plex-update.sh:10-13` (globals block), `plex-update.sh:211` (just before `main()`)

- [ ] **Step 1: Add `INSTALL_MODE=false` after `NON_ROOT=false`**

Replace (lines 10–13 — include all four lines to avoid accidentally deleting any):
```bash
DRY_RUN=false
NON_ROOT=false
PLEX_TOKEN=""
PLATFORM=""
```
With:
```bash
DRY_RUN=false
NON_ROOT=false
INSTALL_MODE=false
PLEX_TOKEN=""
PLATFORM=""
```

- [ ] **Step 2: Add `usage()` function immediately before `main()`**

Insert this block in the blank line between the closing `}` of `install_package()` (line 210) and `main() {` (line 212). The result should look like:

```bash
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
```

- [ ] **Step 3: Verify syntax and static analysis**

```bash
bash -n plex-update.sh && echo "Syntax OK"
shellcheck plex-update.sh && echo "ShellCheck OK"
```

Expected: both print OK with no warnings.

- [ ] **Step 4: Commit**

```bash
git add plex-update.sh
git commit -m "feat: add INSTALL_MODE global and usage() function"
```

---

### Task 2: Extend argument parser with `-i`/`--install` and `-h`/`--help`

**Files:**
- Modify: `plex-update.sh` — `while` loop inside `main()`

- [ ] **Step 1: Add two cases to the `while` loop**

The loop currently has:
```bash
            --dry-run) DRY_RUN=true ;;
            --platform)
```

Add the two new cases directly after `--dry-run`:
```bash
            --dry-run) DRY_RUN=true ;;
            -i|--install) INSTALL_MODE=true ;;
            -h|--help) usage; exit 0 ;;
            --platform)
```

Both are standalone flags (no value argument). The outer `shift` at the bottom of the loop handles them — same pattern as `--dry-run`. No inner `shift` needed.

- [ ] **Step 2: Verify syntax and static analysis**

```bash
bash -n plex-update.sh && echo "Syntax OK"
shellcheck plex-update.sh && echo "ShellCheck OK"
```

- [ ] **Step 3: Smoke-test `--help` and `-h` with exit code check**

```bash
bash plex-update.sh --help; echo "Exit: $?"
bash plex-update.sh -h; echo "Exit: $?"
```

Expected: both print the usage block, then `Exit: 0`.

- [ ] **Step 4: Commit**

```bash
git add plex-update.sh
git commit -m "feat: add -i/--install and -h/--help flags to argument parser"
```

---

### Task 3: Replace installed-version early-exit with three-way branch

**Files:**
- Modify: `plex-update.sh` — version check block inside `main()`

- [ ] **Step 1: Replace the existing block (and its following log line)**

Current code:
```bash
    if [[ -z "$installed_version" ]]; then
        log "Plex Media Server is not installed."
        exit 1
    fi
    log "Installed version: $installed_version"
```

Replace with:
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

- [ ] **Step 2: Verify syntax and static analysis**

```bash
bash -n plex-update.sh && echo "Syntax OK"
shellcheck plex-update.sh && echo "ShellCheck OK"
```

- [ ] **Step 3: Smoke-test the three paths**

```bash
# Path A: no --install, Plex not installed → should error with exit code 1
bash plex-update.sh --dry-run 2>&1; echo "Exit: $?"
# Expected last lines: "Plex Media Server is not installed." / "Exit: 1"

# Path B: --install, Plex not installed → proceeds past version check
bash plex-update.sh --install --dry-run 2>&1; echo "Exit: $?"
# Expected: "No version installed; will install latest." then API/dry-run lines, "Exit: 0"

# Path C: --install when Plex IS installed (skip on dev machine if not installed)
# On macOS: defaults read "/Applications/Plex Media Server.app/Contents/Info.plist" CFBundleVersion
# If a version is returned, run:
#   bash plex-update.sh --install --dry-run 2>&1; echo "Exit: $?"
# Expected: "ERROR: Plex Media Server is already installed (X.Y.Z)..." / "Exit: 1"
```

- [ ] **Step 4: Commit**

```bash
git add plex-update.sh
git commit -m "feat: replace installed-version early-exit with three-way branch for --install"
```

---

### Task 4: Guard `launchctl load` in `install_package()`

**Files:**
- Modify: `plex-update.sh` — end of the macOS branch in `install_package()`

Note: the `launchctl unload ... 2>/dev/null || true` line at the top of the same block is intentionally left unchanged — it already no-ops safely when the plist is absent.

- [ ] **Step 1: Replace the unconditional `launchctl load` with a three-way guard**

Current code:
```bash
        log "Starting Plex Media Server..."
        launchctl load "$LAUNCHD_PLIST"
```

Replace with:
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

- [ ] **Step 2: Verify syntax and static analysis**

```bash
bash -n plex-update.sh && echo "Syntax OK"
shellcheck plex-update.sh && echo "ShellCheck OK"
```

- [ ] **Step 3: Verify guard is in place**

```bash
grep -c 'if \[\[ -f "\$LAUNCHD_PLIST' plex-update.sh
# Expected: 1

grep -c 'launchctl load' plex-update.sh
# Expected: 1  (only inside the guard, not unconditionally)
```

- [ ] **Step 4: Commit**

```bash
git add plex-update.sh
git commit -m "fix: guard launchctl load in install_package for fresh macOS installs"
```

---

## Verification Checklist

After all tasks complete:

```bash
# Full static analysis
bash -n plex-update.sh && shellcheck plex-update.sh && echo "All checks OK"

# --help and -h both work and exit 0
bash plex-update.sh --help; echo "Exit: $?"
bash plex-update.sh -h; echo "Exit: $?"

# Normal run without Plex still errors (exit 1)
bash plex-update.sh --dry-run 2>&1; echo "Exit: $?"

# --install without Plex proceeds past the version check (exits 0 with dry-run)
bash plex-update.sh --install --dry-run 2>&1; echo "Exit: $?"
```
