# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash-based automatic updater for Plex Media Server, designed to run from cron on CentOS 7. Compares the installed RPM version against the Plex API and performs an in-place upgrade when a newer version is available.

## How It Works

1. Query installed version via `rpm -qi --nosignature plexmediaserver`
2. Fetch latest release from `https://plex.tv/api/downloads/5.json?channel=plexpass`
3. Extract the `linux-x86_64` / `redhat` release from `.computer.Linux.releases[]`
4. Compare version strings numerically (e.g. `1.43.0.10492-121068a07`)
5. Download RPM, verify SHA-1 checksum, install with `rpm -Uvh --nosignature`

## Key Files

- `plex-update.sh` — the updater script (entry point)

## Development Notes

- Development happens on macOS; target runtime is CentOS 7
- `rpm`, `sha1sum`, and `systemctl` commands won't work locally on macOS
- JSON parsing prefers `jq` if available, falls back to `python3` (CentOS 7 has python available but may not have jq)
- The API response nests releases under `.computer.Linux.releases[]` — filter by `build == "linux-x86_64"` and `distro == "redhat"`
- Version comparison uses the numeric prefix before the `-` hash suffix, split on `.` and compared field by field

## Testing Locally

```bash
# Syntax check
bash -n plex-update.sh

# ShellCheck
shellcheck plex-update.sh

# Test version comparison (source the functions)
source plex-update.sh  # will fail at main, but functions are loaded in subshell
```
