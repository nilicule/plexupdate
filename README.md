# Plex Media Server Updater

Automatic updater for Plex Media Server on CentOS 7. Compares the installed RPM version against the Plex API and performs an in-place upgrade when a newer version is available.

## How It Works

1. Queries the installed version via `rpm`
2. Fetches the latest Plex Pass release from the Plex downloads API
3. Compares version strings field-by-field
4. Downloads the RPM, verifies the SHA-1 checksum, and installs it

## Requirements

- CentOS 7 (or compatible RPM-based distro)
- `curl`
- `jq` (preferred) or `python3` for JSON parsing
- Root privileges (for `rpm -Uvh`)

## Usage

```bash
# Run the updater
sudo ./plex-update.sh

# Dry run — shows what would happen without making changes
sudo ./plex-update.sh --dry-run
```

### Cron Example

```cron
0 4 * * * /path/to/plex-update.sh >> /var/log/plex-update.log 2>&1
```

## License

MIT
