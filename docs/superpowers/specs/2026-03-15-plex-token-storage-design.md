# Plex Token Storage Design

**Date:** 2026-03-15

## Summary

Add a `--set-token TOKEN` CLI parameter to `plex-update.sh` that persists a Plex authentication token to a local file. On every run, the script loads the token if present and uses it for both the API URL and the direct download URL. If the token file is absent, the direct download check is skipped and the user is informed via log output.

## CLI Interface

```
plex-update.sh --set-token <TOKEN>
```

- Strips leading/trailing whitespace from `TOKEN`; if the result is empty, prints an error and exits non-zero.
- Writes the trimmed token to `.plex-token` with permissions `600` (owner read/write only).
- Prints a confirmation message and exits immediately (no update check is performed).
- `--set-token` takes precedence over all other flags (e.g. `--dry-run`). If it appears anywhere in the argument list the script writes the token and exits, ignoring other arguments.

## Token File

- **Location:** Resolved via `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)` — the canonical directory of the script, reliable when invoked from cron with an absolute path.
- **File path:** `$SCRIPT_DIR/.plex-token`
- **Format:** The token string only, no trailing newline required (written with `printf '%s' "$token"`).
- **Permissions:** `600` (set explicitly after write, regardless of umask).
- **Git:** `.plex-token` is added to `.gitignore` to prevent accidental credential commits.

## Runtime Behaviour

On a normal run (no `--set-token`):

1. Script reads `.plex-token` from `$SCRIPT_DIR` and trims whitespace. If the result is empty or the file does not exist, the token is unset.
2. **Token present:** Append `&X-Plex-Token=<token>` to `API_URL`; replace the placeholder value in `DIRECT_URL` using bash parameter substitution:
   ```bash
   DIRECT_URL="${DIRECT_URL/xxxxxxxxxxxxxxxxxxxx/$PLEX_TOKEN}"
   ```
   The placeholder in the current script is the literal string `xxxxxxxxxxxxxxxxxxxx`.
3. **Token absent:** Log `"No Plex token found; skipping direct download check."` and skip `fetch_direct` entirely. The existing failure-path log (`"Direct endpoint check failed or returned no version; falling back to API."`) is preserved for the case where `fetch_direct` is called but returns no result.

## Error Handling

- `--set-token` with an empty or whitespace-only value: print error `"ERROR: --set-token requires a non-empty token value."` and exit 1.
- `.plex-token` exists but is empty/whitespace: treat as absent — log skip message, proceed with API-only check.

## Files Changed

| File | Change |
|---|---|
| `plex-update.sh` | Add `--set-token` handling, `SCRIPT_DIR` resolution, token loading, conditional `fetch_direct` |
| `.gitignore` | Add `.plex-token` |
| `CLAUDE.md` | Update "How It Works" to reflect token file and conditional direct check |
