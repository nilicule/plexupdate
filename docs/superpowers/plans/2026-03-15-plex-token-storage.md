# Plex Token Storage Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--set-token TOKEN` to `plex-update.sh` so the Plex auth token is stored in a local file and used automatically on each run; skip the direct download check when no token is present.

**Architecture:** All changes are confined to `plex-update.sh`. A `SCRIPT_DIR` variable resolves the canonical script directory (reliable for cron). `--set-token` is handled via a pre-scan of all arguments before the main `while` loop so it takes precedence regardless of argument position. Token loading and URL injection happen after the pre-scan. The direct download block is wrapped in an `if [[ -n "$PLEX_TOKEN" ]]` guard.

**Tech Stack:** Bash, shellcheck (lint), bash -n (syntax check)

**Spec:** `docs/superpowers/specs/2026-03-15-plex-token-storage-design.md`

---

## Chunk 1: All changes

### Task 1: Add `.plex-token` to `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add the token file to `.gitignore`**

  Append to `.gitignore`:
  ```
  .plex-token
  ```

- [ ] **Step 2: Verify**

  Run: `cat .gitignore`
  Expected: `.plex-token` appears in the file.

- [ ] **Step 3: Commit**

  ```bash
  git add .gitignore
  git commit -m "chore: ignore .plex-token credential file"
  ```

---

### Task 2: Add `SCRIPT_DIR`, `TOKEN_FILE`, and `PLEX_TOKEN` globals

**Files:**
- Modify: `plex-update.sh` — after line 8 (`DRY_RUN=false`)

- [ ] **Step 1: Insert three variables after `DRY_RUN=false`**

  The current top of the file (lines 4–8):
  ```bash
  API_URL="https://plex.tv/api/downloads/5.json?channel=plexpass"
  DIRECT_URL="https://plex.tv/downloads/latest/5?channel=8&build=linux-x86_64&distro=redhat&X-Plex-Token=xxxxxxxxxxxxxxxxxxxx"
  TMP_DIR="/tmp"
  PLEX_PACKAGE="plexmediaserver"
  DRY_RUN=false
  ```

  After `DRY_RUN=false` add:
  ```bash
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  TOKEN_FILE="$SCRIPT_DIR/.plex-token"
  PLEX_TOKEN=""
  ```

- [ ] **Step 2: Syntax check**

  Run: `bash -n plex-update.sh`
  Expected: no output (exit 0).

- [ ] **Step 3: ShellCheck**

  Run: `shellcheck plex-update.sh`
  Expected: no errors.

- [ ] **Step 4: Commit**

  ```bash
  git add plex-update.sh
  git commit -m "feat: add SCRIPT_DIR and TOKEN_FILE variables"
  ```

---

### Task 3: Add `--set-token` pre-scan at the top of `main()`

**Files:**
- Modify: `plex-update.sh:115` — `main()` function, before the existing `while` loop

The spec requires `--set-token` to take precedence over all other flags regardless of position in the argument list. This is implemented as a pre-scan loop before the main `while` loop.

- [ ] **Step 1: Insert pre-scan block at the top of `main()`, before the existing `while` loop**

  The current start of `main()` (line 115 onwards):
  ```bash
  main() {
      while [[ $# -gt 0 ]]; do
  ```

  Insert between `main() {` and the existing `while` loop:
  ```bash
      # --set-token takes precedence over all other flags; pre-scan all args
      local _args=("$@")
      local _i
      for _i in "${!_args[@]}"; do
          if [[ "${_args[$_i]}" == "--set-token" ]]; then
              local _token="${_args[$_i+1]:-}"
              # trim leading/trailing whitespace
              _token="${_token#"${_token%%[![:space:]]*}"}"
              _token="${_token%"${_token##*[![:space:]]}"}"
              if [[ -z "$_token" ]]; then
                  log "ERROR: --set-token requires a non-empty token value."
                  exit 1
              fi
              printf '%s' "$_token" > "$TOKEN_FILE"
              chmod 600 "$TOKEN_FILE"
              log "Plex token saved to $TOKEN_FILE"
              exit 0
          fi
      done
  ```

- [ ] **Step 2: Syntax check**

  Run: `bash -n plex-update.sh`
  Expected: no output (exit 0).

- [ ] **Step 3: ShellCheck**

  Run: `shellcheck plex-update.sh`
  Expected: no new errors.

- [ ] **Step 4: Functional test — empty token rejected**

  Run from the repo root (the directory containing `plex-update.sh`):
  ```bash
  bash plex-update.sh --set-token ""
  ```
  Expected output contains: `ERROR: --set-token requires a non-empty token value.`
  Expected exit code: 1

- [ ] **Step 5: Functional test — `--set-token` with no value rejected**

  Run:
  ```bash
  bash plex-update.sh --set-token
  ```
  Expected output contains: `ERROR: --set-token requires a non-empty token value.`

- [ ] **Step 6: Functional test — valid token written, other flags ignored**

  Run:
  ```bash
  bash plex-update.sh --dry-run --set-token testtoken123
  ```
  Expected: output contains `Plex token saved to`, script exits without performing an update check.

  Verify file and permissions (run from repo root where the script lives):
  ```bash
  cat .plex-token && ls -la .plex-token
  ```
  Expected: `testtoken123` and permissions `-rw-------` (600).

- [ ] **Step 7: Clean up test file**

  ```bash
  rm -f .plex-token
  ```

- [ ] **Step 8: Commit**

  ```bash
  git add plex-update.sh
  git commit -m "feat: add --set-token flag to persist Plex auth token"
  ```

---

### Task 4: Load token and inject into URLs; guard `fetch_direct`

**Files:**
- Modify: `plex-update.sh` — `main()` body, after the existing `while` loop

- [ ] **Step 1: Add token loading and URL injection after the `while` loop's `done`**

  After the `done` that closes the existing `while [[ $# -gt 0 ]]` loop, insert:
  ```bash
      # Load token from file if present
      if [[ -f "$TOKEN_FILE" ]]; then
          PLEX_TOKEN=$(< "$TOKEN_FILE")
          # trim leading/trailing whitespace only
          PLEX_TOKEN="${PLEX_TOKEN#"${PLEX_TOKEN%%[![:space:]]*}"}"
          PLEX_TOKEN="${PLEX_TOKEN%"${PLEX_TOKEN##*[![:space:]]}"}"
      fi

      if [[ -n "$PLEX_TOKEN" ]]; then
          API_URL="${API_URL}&X-Plex-Token=${PLEX_TOKEN}"
          DIRECT_URL="${DIRECT_URL/xxxxxxxxxxxxxxxxxxxx/${PLEX_TOKEN}}"
      fi
  ```

- [ ] **Step 2: Replace the unconditional `fetch_direct` block with a token-guarded version**

  The current block in `main()` (around lines 155–170):
  ```bash
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
          fi
      else
          log "Direct endpoint check failed or returned no version; falling back to API."
      fi
      log "Latest version: $latest_version"
  ```

  Replace with:
  ```bash
      if [[ -n "$PLEX_TOKEN" ]]; then
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
              fi
          else
              log "Direct endpoint check failed or returned no version; falling back to API."
          fi
      else
          log "No Plex token found; skipping direct download check."
      fi
      log "Latest version: $latest_version"
  ```

  Note: `log "Latest version: $latest_version"` must be preserved outside and after the `if/fi` block.

- [ ] **Step 3: Syntax check**

  Run: `bash -n plex-update.sh`
  Expected: no output (exit 0).

- [ ] **Step 4: ShellCheck**

  Run: `shellcheck plex-update.sh`
  Expected: no new errors.

- [ ] **Step 5: Verify skip message is present in script**

  ```bash
  grep -q "No Plex token found; skipping direct download check." plex-update.sh && echo "PASS"
  ```
  Expected: `PASS`

- [ ] **Step 6: Commit**

  ```bash
  git add plex-update.sh
  git commit -m "feat: load token from .plex-token and guard direct download check"
  ```

---

### Task 5: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Read the current CLAUDE.md**

  Run: `cat CLAUDE.md`

- [ ] **Step 2: Update the "How It Works" numbered list**

  The current list starts:
  ```
  1. Query installed version via `rpm -qi --nosignature plexmediaserver`
  2. Fetch latest release from `https://plex.tv/api/downloads/5.json?channel=plexpass`
  ```

  Insert a new step 2, shifting existing steps 2–5 to 3–6:
  ```
  2. Load Plex auth token from `.plex-token` in the script directory (if present)
  ```

- [ ] **Step 3: Add token file note to "Development Notes"**

  Append to the "Development Notes" bullet list:
  ```
  - A `.plex-token` file in the script directory enables the direct download endpoint check.
    If absent, the direct check is skipped. Store your token with:
    `./plex-update.sh --set-token <YOUR_PLEX_TOKEN>`
  ```

- [ ] **Step 4: Verify**

  Run: `cat CLAUDE.md`

- [ ] **Step 5: Commit**

  ```bash
  git add CLAUDE.md
  git commit -m "docs: document .plex-token and --set-token in CLAUDE.md"
  ```
