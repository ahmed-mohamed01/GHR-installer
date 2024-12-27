# GitHub Release Installer Documentation

## Release Selection Process

### GitHub Release Selection
```bash
# From get_github_release() function
# If token is set
curl -sH "Authorization: Bearer $GITHUB_TOKEN" \
     "https://api.github.com/repos/$repo/releases/latest"
# If token is not set
curl -s "https://api.github.com/repos/$repo/releases/latest"
```
- Uses GitHub API's `/releases/latest` endpoint
- Token behavior:
  - With token: 5000 requests per hour
  - Without token: 60 requests per hour (rate-limited)
  - Unauthenticated requests may fail during high usage
  - Cache helps mitigate rate limiting
- Falls back to parsing tag if API fails

### Asset Selection Filters
```bash
# From find_binary_asset() function
local patterns=(
    # Architecture patterns
    "x86[_-]64"
    "amd64"
    "64[_-]bit"
    "64bit"
    
    # OS patterns
    "linux"
    "unknown[_-]linux"
    
    # Exclude patterns
    -e "aarch64"
    -e "arm64"
    -e "arm"
    -e "musl"
    -e "alpine"
    -e ".deb"
    -e ".rpm"
    -e ".sha256"
    -e ".asc"
)
```
- Prioritizes x86_64/amd64 Linux binaries
- Excludes ARM architectures
- Excludes package manager formats
- Excludes checksums and signatures

### Version Comparison Logic
```bash
# From version_compare() function
version_compare() {
    local ver1=$1
    local ver2=$2
    
    # Strip 'v' prefix if present
    ver1=${ver1#v}
    ver2=${ver2#v}
    
    # Compare versions
    if [ "$(printf '%s\n' "$ver1" "$ver2" | sort -V | tail -n1)" = "$ver1" ]; then
        if [ "$ver1" = "$ver2" ]; then
            echo "equal"
        else
            echo "newer"
        fi
    else
        echo "older"
    fi
}
```
- Handles version prefixes (e.g., 'v1.0.0')
- Uses semantic versioning comparison
- Returns relative age (newer/older/equal)

## Asset Selection

### Binary Detection
The script uses pattern matching to find appropriate binary assets:

1. Architecture Patterns:
   - x86_64: `linux-x86_64`, `linux-amd64`, `linux64`, etc.
   - arm64: `linux-aarch64`, `linux-arm64`, etc.
   - Fallback: `linux` (for simpler naming schemes)

2. Special Cases:
   - Some packages use simpler naming (e.g., tldr)
   - Handles various archive formats (.tar.gz, .tgz, .zip)
   - Falls back to more generic patterns if specific ones fail

3. Selection Priority:
   - Architecture-specific binaries first
   - Generic Linux binaries as fallback
   - Prefers static builds when available

## Binary Name Handling

### Repository Format
1. Basic Format: `owner/repo`
   - Assumes binary name matches repo name
   - Example: `sharkdp/bat` → binary should be `bat`

2. With Alias: `owner/repo | binary`
   - Uses specified binary name
   - Example: `tldr-pages/tldr-c-client | tldr`
   - Useful when binary name differs from repo name

### Binary Name Verification
- During installation, script verifies if binary name matches expectations
- If mismatch found:
  ```
  # For owner/repo format with mismatched binary
  Warning: Repository name 'repo-name' does not match installed binary 'actual-binary'
  Please verify this is the correct binary or specify explicitly in repos.txt as:
  owner/repo | actual-binary

  # For owner/repo | binary format with mismatch
  Warning: Specified binary name 'binary' does not match installed binary 'actual-binary'
  Please verify this is the correct binary
  ```
- No user confirmation required, just informational warning
- User can:
  1. Verify manually and continue using
  2. Update repos.txt with correct binary name
  3. Install manually if unsure

Note: Future versions may include automatic binary name detection and verification.

## Repository Configuration

### Repository Format
Repositories can be specified in two formats in `repos.txt`:

1. Basic Format:
   ```
   owner/repo
   ```
   Example: `sharkdp/bat`
   - Binary name will be 'bat'
   - Used when repository name matches binary name

2. With Alias:
   ```
   owner/repo | alias
   ```
   Example: `tldr-pages/tldr-c-client | tldr`
   - Binary name will be 'tldr'
   - Used when:
     - Binary name differs from repository name
     - Want to install under different name
     - Repository produces multiple binaries

### Examples
```
# Basic format - binary name matches repo
sharkdp/bat
junegunn/fzf

# With alias - custom binary name
tldr-pages/tldr-c-client | tldr
```

## Package Installation States

### Location and Structure
- State file: `$HOME/.local/share/ghr-installer/packages.json`
```json
{
  "packages": {
    "package-name": {
      "version": "v1.2.3",
      "binary_path": "/home/user/.local/bin/package-name",
      "installed_at": "2024-12-26T23:58:37Z",
      "updated_at": "2024-12-26T23:58:37Z"
    }
  }
}
```

### Tracking
- Installation time
- Last update time
- Current version
- Binary location

## Error Handling & Recovery

### Cache Corruption
- Delete corrupted cache files to force regeneration
- Cache files:
  1. `api-cache.json` - GitHub API responses
  2. `assets/*` - Downloaded binaries
  3. `packages.json` - Installation state

### Recovery Steps
1. Clear API cache: `rm $HOME/.local/share/ghr-installer/api-cache.json`
2. Clear asset cache: `rm -rf $HOME/.local/share/ghr-installer/assets/*`
3. Rebuild state: Re-run installer with `--override-cache`

### Interrupted Downloads
- Temporary files used for atomic writes
- Failed downloads automatically retried
- Partial downloads cleaned up

## Cache System

### 1. GitHub Release Cache

#### Location and Structure
- Cache file: `$HOME/.local/share/ghr-installer/api-cache.json`
```json
{
  "cache_version": "1.0",
  "repositories": {
    "owner/repo": {
      "last_checked": "2024-12-27T00:13:14Z",
      "latest_release": {
        // Full GitHub API response for latest release
      }
    }
  }
}
```

#### Behavior
- Cache TTL: 1 hour (configurable via `CACHE_TTL`)
- Before making a GitHub API call, checks if:
  1. Cache exists for the repository
  2. Cache is less than 1 hour old
- If cache is valid, uses cached release data
- If cache is invalid or missing, makes new API call and updates cache

### 2. Downloaded Assets Cache

#### Location and Structure
- Base directory: `$HOME/.local/share/ghr-installer/assets/`
```
assets/
├── owner_repo/
│   ├── asset-name.tar.gz
│   └── asset-name.tar.gz.meta
```

#### Behavior
- One asset per repository
- Assets cleaned after 30 days
- Old assets removed on update
- Metadata files track original URLs

## Cache Management

### Cache Structure
- GitHub API responses cached in: `$DATA_DIR/api-cache`
- Downloaded assets cached in: `$DATA_DIR/api-cache/assets`
- Cache TTL: 1 hour (3600 seconds)

### Cache Control
- `--clear-cache`: Remove all cached GitHub API responses and assets
- `--override-cache`: Bypass cache for current operation only

## Security Considerations

### GitHub Token
- Optional but recommended for better rate limits
- If set, stored in environment: `GITHUB_TOKEN`
- Used only for API requests, not for downloads
- Never cached or written to disk
- Without token:
  - Limited to 60 requests per hour
  - May experience rate limiting during peak times
  - Cache becomes more important
  - Some operations may fail if rate limited

### Cache Permissions
- All cache files: `600` (user read/write only)
- Cache directories: `700` (user access only)
- Binary files: `755` (executable by all)

## Maintenance

### Manual Cache Cleanup
```bash
# Clear all caches
rm -rf $HOME/.local/share/ghr-installer/*

# Clear specific repo's assets
rm -rf $HOME/.local/share/ghr-installer/assets/owner_repo

# Clear API cache only
rm $HOME/.local/share/ghr-installer/api-cache.json
```

### Backup Considerations
- Cache can be safely excluded from backups
- `packages.json` should be backed up to preserve installation state
- All cache data can be regenerated if needed
