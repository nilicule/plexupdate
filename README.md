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
# Authenticate with Plex (one-time setup — opens a browser URL, then polls until you sign in)
./plex-update.sh --login

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

### Authentication

Run `--login` once to authenticate with your Plex account. The script will:

1. Print a URL — open it in any browser and sign in to Plex
2. Poll automatically until authentication completes
3. Save the token to `.plex-token` (mode 600) and a client identifier to `.plex-client-id`

The token is reused on every subsequent run. If it ever expires the script will warn you and fall back to the public API until you run `--login` again.

Without a token the script falls back to the public Plex API, which covers most releases. A token is required to access Plex Pass builds.

> **Advanced:** If you already have a token from another source you can set it directly with `--set-token YOUR_TOKEN`.

> **macOS fresh install note:** After `--install` completes, open Plex Media Server once manually to register the LaunchAgent. Subsequent runs will start/stop it automatically.

### Cron Example

```cron
0 4 * * * /path/to/plex-update.sh >> /var/log/plex-update.log 2>&1
```

## License

MIT
