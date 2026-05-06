# Plex Media Server Updater

Automatic updater for Plex Media Server on Linux (CentOS/RPM) and macOS. Checks the Plex API and upgrades when a newer version is available.

## Requirements

- `curl`, plus `jq` or `python3` for JSON parsing
- **Linux:** `rpm`, root privileges
- **macOS:** `unzip`, write access to `/Applications` (`sudo`)

## Usage

```bash
# Authenticate with Plex (one-time setup)
./plex-update.sh --login

# First-time install
sudo ./plex-update.sh --install

# Update an existing installation
sudo ./plex-update.sh

# Dry run — shows what would happen without making changes
./plex-update.sh --dry-run

# Override platform detection
sudo ./plex-update.sh --platform linux

# List available Plex versions
./plex-update.sh --list-versions

# Show all options
./plex-update.sh --help
```

A Plex token (set via `--login`) is required for Plex Pass builds; without one the script falls back to the public API.

> **macOS:** After `--install`, open Plex Media Server once manually to register the LaunchAgent.

### Cron Example

```cron
0 4 * * * /path/to/plex-update.sh >> /var/log/plex-update.log 2>&1
```

## License

MIT
