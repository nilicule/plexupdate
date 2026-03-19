# Plex Media Server Updater

Automatic updater for Plex Media Server on Linux (CentOS/RPM) and macOS. Compares the installed version against the Plex API and performs an in-place upgrade when a newer version is available.

## How It Works

1. Auto-detects the platform (`uname -s`) — Linux uses `rpm`, macOS reads the app bundle's plist
2. Fetches the latest Plex Pass release from the Plex downloads API
3. If a Plex token is configured, also checks the direct download endpoint for builds not yet in the API
4. Compares version strings field-by-field
5. Downloads the package, verifies the SHA-1 checksum, and installs it
   - **Linux:** `rpm -Uvh`
   - **macOS:** stops the LaunchAgent, replaces the app bundle, restarts the LaunchAgent

## Requirements

**Linux (CentOS 7 / RPM-based)**
- `curl`, `rpm`
- `jq` (preferred) or `python3` for JSON parsing
- Root privileges

**macOS**
- `curl`, `unzip`
- `jq` (preferred) or `python3` for JSON parsing
- Write access to `/Applications` (run with `sudo`)

## Usage

```bash
# Save your Plex token (one-time setup, stored in .plex-token with 600 permissions)
./plex-update.sh --set-token YOUR_PLEX_TOKEN

# First-time install (errors if Plex is already installed)
sudo ./plex-update.sh --install

# Update an existing installation
sudo ./plex-update.sh

# Dry run — shows what would happen without making changes
sudo ./plex-update.sh --dry-run

# Override platform detection (linux or macos)
sudo ./plex-update.sh --platform linux

# Show all options
./plex-update.sh --help
```

Without a token the script falls back to the public Plex API, which covers most releases. The direct download endpoint (which can surface builds slightly ahead of the API) requires authentication and is skipped when no token is present.

> **macOS fresh install note:** After `--install` completes, open Plex Media Server once manually to register the LaunchAgent. Subsequent runs will start/stop it automatically.

### Cron Example

```cron
0 4 * * * /path/to/plex-update.sh >> /var/log/plex-update.log 2>&1
```

## License

MIT
