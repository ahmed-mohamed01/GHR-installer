# GitHub Releases Installer

A powerful bash script to manage and install binaries from GitHub releases alongside their APT package alternatives.

## Features

- Install binaries directly from GitHub releases
- Compare versions between GitHub releases and APT packages
- Manage multiple installation sources (GitHub/APT)
- Track installed packages with metadata
- Automatic dependency handling
- File locking for concurrent access safety
- JSON-based package database

./installer.sh --update: Checks for updates from installed source (GitHub or APT) for all installed packages
./installer.sh --update fzf: Checks for updates for fzf from its current source
./installer.sh --update --all-sources: Checks for updates from both GitHub and APT for all installed packages
./installer.sh --list: Shows only packages installed by ghr-installer
./installer.sh (no args): Enters interactive mode, which shows available packages from repos.txt


## Installation

1. Clone this repository:
```bash
git clone <repository-url>
cd <repository-name>
```

2. Make the installer executable:
```bash
chmod +x installer.sh
```

3. (Optional) Add your GitHub token to avoid rate limits:
```bash
export GITHUB_TOKEN=your_token_here
```

## Usage

Run the installer:
```bash
./installer.sh
```

The script will:
1. Check available GitHub releases and APT versions
2. Compare versions and show what's available
3. Handle dependencies automatically
4. Present installation options:
   - Install all newer versions
   - Install all GitHub versions
   - Install all APT versions
   - Choose individually
   
## Database

The installer maintains a JSON database at `~/.local/ghr-installer/ghr-installer.db` containing:
- Installed package versions
- Installation timestamps
- File locations
- Version tracking

## Requirements

- jq (for JSON processing)


## Security

- Uses file locking to prevent concurrent access issues
- Verifies downloads using checksums when available
- Supports GITHUB_TOKEN for authenticated API access

## Example
Istalling fzf from Github.

```
Processing repositories:
junegunn/fzf
zyedidia/micro
ajeetdsouza/zoxide
eza-community/eza
sharkdp/fd

Checking versions...
Binary          Github       APT          Dependencies    Asset                                   
------------------------------------------------------------------------------------------------
fzf             0.57.0*      0.29.0       No, static      fzf-0.57.0-linux_amd64.tar.gz           
micro           2.0.14       2.0.9        No, static      micro-2.0.14-linux64-static.tar.gz      
zoxide          0.9.6        0.4.3        Yes, satisfied  zoxide-0.9.6-x86_64-unknown-linux-mus...
eza             0.20.14      not found    Yes, satisfied  eza_x86_64-unknown-linux-gnu.tar.gz     
fd              10.2.0       not found    Yes, satisfied  fd-v10.2.0-x86_64-unknown-linux-gnu.t...

Dependencies needed:
No additional dependencies required

Installation options:
1. Install all newer versions
2. Install all GitHub versions (to /home/user/.local/bin)
3. Install all APT versions
4. Choose individually
5. Cancel

fzf:
1. Install GitHub version (v0.57.0)
2. Install APT version (0.29.0-1)
3. Skip

Successfully installed fzf v0.57.0
```

The asterisk (*) next to the GitHub version indicates that it's newer than the APT version.

## Last Updated

2024-12-26

## License

[Your chosen license]
