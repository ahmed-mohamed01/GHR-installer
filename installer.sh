#!/usr/bin/env bash

# Architecture patterns for binary matching
declare -a x86_64_patterns=(
    "x86[_-]64"
    "amd64"
    "linux64"
)

declare -a arm64_patterns=(
    "arm64"
    "aarch64"
    "arm[_-]64"
)

# Colors for output
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'  # No Color

# Function to print with color
print_color() {
    local color=$1
    local text=$2
    echo -e "${color}${text}${NC}"
}

# Configuration
INSTALL_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/ghr-installer"
DB_FILE="$DATA_DIR/packages.json"
CACHE_DIR="$DATA_DIR"
CACHE_FILE="$CACHE_DIR/api-cache.json"
ASSETS_CACHE_DIR="$CACHE_DIR/assets"
CACHE_TTL=3600  # 1 hour in seconds
OVERRIDE_CACHE=0
repos_file="repos.txt"
TEMP_DIR=$(mktemp -d)
SHELLS=("/bin/bash" "/bin/zsh")

# Function to lock database
lock_db() {
    local lock_file="$DATA_DIR/ghr-installer.lock"
    local pid
    
    # Try to acquire lock
    if [ -f "$lock_file" ]; then
        pid=$(cat "$lock_file")
        if kill -0 "$pid" 2>/dev/null; then
            print_color "$RED" "Error: Another instance is running (PID: $pid)"
            return 1
        fi
        # Stale lock file
        rm -f "$lock_file"
    fi
    
    echo $$ > "$lock_file"
    return 0
}

# Function to unlock database
unlock_db() {
    rm -f "$DATA_DIR/ghr-installer.lock"
}

# Database operations wrapper
db_ops() {
    local operation=$1
    shift

    case "$operation" in
        get)
            local key=$1
            if [ ! -f "$DB_FILE" ]; then
                echo '{}'
                return
            fi
            jq -r --arg key "$key" '.packages[$key] // empty' "$DB_FILE"
            ;;
        set)
            local key=$1
            local value=$2
            mkdir -p "$(dirname "$DB_FILE")"
            if [ ! -f "$DB_FILE" ]; then
                echo '{"version":1,"packages":{}}' > "$DB_FILE"
            fi
            local temp_file="${DB_FILE}.tmp"
            jq --arg key "$key" --argjson value "$value" '.packages[$key] = $value' "$DB_FILE" > "$temp_file"
            mv "$temp_file" "$DB_FILE"
            ;;
        delete)
            local key=$1
            if [ -f "$DB_FILE" ]; then
                local temp_file="${DB_FILE}.tmp"
                jq --arg key "$key" 'del(.packages[$key])' "$DB_FILE" > "$temp_file"
                mv "$temp_file" "$DB_FILE"
            fi
            ;;
        list)
            if [ ! -f "$DB_FILE" ]; then
                return
            fi
            jq -r '.packages | keys[]' "$DB_FILE"
            ;;
        query)
            local query=$1
            if [ ! -f "$DB_FILE" ]; then
                echo '{}'
                return
            fi
            jq "$query" "$DB_FILE"
            ;;
    esac
}

# Function to read database
read_db() {
    if [ ! -f "$DB_FILE" ]; then
        echo '{"version":1,"packages":{}}'
        return
    fi
    cat "$DB_FILE"
}

# Function to write database
write_db() {
    local content="$1"
    if [ -n "$content" ]; then
        echo "$content" > "$DB_FILE"
    fi
}

# Function to add entry to database
add_to_db() {
    local package=$1
    local version=$2
    shift 2
    local files=("$@")
    
    if ! lock_db; then
        return 1
    fi
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local entry=$(jq -n \
        --arg ver "$version" \
        --argjson files "$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)" \
        --arg ts "$timestamp" \
        '{version: $ver, files: $files, installed_at: $ts, updated_at: $ts}')
    
    db_ops set "$package" "$entry"
    unlock_db
}

# Function to remove from database
remove_from_db() {
    local package=$1
    
    if ! lock_db; then
        return 1
    fi
    
    db_ops delete "$package"
    unlock_db
}

# Function to get package info from database
get_package_info() {
    local package=$1
    db_ops get "$package"
}

# Function to check if a package is installed via ghr-installer
check_installed() {
    local package=$1
    if [ ! -f "$DB_FILE" ]; then
        echo "Database file not found. No packages installed via ghr-installer."
        return 1
    fi
    
    check_installation_status "$package"
    local status=$?
    
    case $status in
        0) return 0 ;;  # Properly installed
        *) return 1 ;;  # Any other status is considered not installed
    esac
}

# Function to get current installed version
get_installed_version() {
    local package=$1
    local info=$(get_package_info "$package")
    if [ -n "$info" ] && [ "$info" != "null" ]; then
        echo "$info" | jq -r '.version'
    fi
}

# Function to remove a package
remove_package() {
    local package=$1
    if ! check_installed "$package"; then
        return 1
    fi
    
    local info=$(get_package_info "$package")
    local version=$(echo "$info" | jq -r '.version')
    local files=$(echo "$info" | jq -r '.files[]')
    
    print_color "$BOLD" "Removing $package version $version..."
    
    # Remove all installed files
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            rm -f "$file"
            echo "Removed: $file"
        fi
    done <<< "$files"
    
    # Remove from database
    remove_from_db "$package"
    
    print_color "$GREEN" "Successfully removed $package"
    
    # Check for orphaned dependencies
    echo -e "\n${BOLD}Checking for orphaned dependencies...${NC}"
    if command -v apt >/dev/null 2>&1; then
        echo "You can check for orphaned packages using:"
        print_color "$YELLOW" "sudo apt autoremove"
    fi
}

# Function to check if binary exists in PATH
check_binary_exists() {
    local binary=$1
    if ! command -v "$binary" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Function to check if all files from installation exist
check_files_exist() {
    local package=$1
    local info=$(get_package_info "$package")
    
    if [ -z "$info" ] || [ "$info" = "null" ]; then
        return 1
    fi
    
    local all_files_exist=true
    while IFS= read -r file; do
        if [ ! -f "$file" ]; then
            all_files_exist=false
            break
        fi
    done <<< "$(echo "$info" | jq -r '.files[]')"
    
    if [ "$all_files_exist" = false ]; then
        return 1
    fi
    
    return 0
}

# Function to check installation status
check_installation_status() {
    local package=$1
    local info=$(get_package_info "$package")
    
    # First check if it's in our database
    if [ -z "$info" ] || [ "$info" = "null" ]; then
        # Not in database, check if binary exists
        if check_binary_exists "$package"; then
            print_color "$YELLOW" "Package $package is installed but not managed by ghr-installer"
            return 2  # Installed but not managed
        else
            print_color "$YELLOW" "Package $package is not installed"
            return 1  # Not installed
        fi
    fi
    
    # In database, verify all files exist
    if ! check_files_exist "$package"; then
        print_color "$YELLOW" "Package $package was installed via ghr-installer but files have been removed"
        return 3  # Files missing
    fi
    
    # Everything is good
    print_color "$GREEN" "Package $package is installed and managed by ghr-installer"
    return 0  # Properly installed
}

# Initialize database
init_db() {
    mkdir -p "$DATA_DIR"
    if [ ! -f "$DB_FILE" ]; then
        echo '{"packages":{}}' > "$DB_FILE"
    else
        # Check database version and migrate if needed
        local version=$(jq -r '.version // 0' "$DB_FILE")
        if [ "$version" = "0" ]; then
            # Migrate old format to new format
            local new_db='{"version":1,"packages":{}}'
            while IFS='|' read -r pkg ver files || [ -n "$pkg" ]; do
                [ -z "$pkg" ] && continue
                local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                local files_array=""
                IFS=',' read -ra file_list <<< "$files"
                for file in "${file_list[@]}"; do
                    files_array="$files_array\"$file\","
                done
                files_array="[${files_array%,}]"
                
                local new_entry=$(jq -n \
                    --arg ver "$ver" \
                    --argjson files "$files_array" \
                    --arg ts "$timestamp" \
                    '{version: $ver, files: $files, installed_at: $ts, updated_at: $ts}')
                new_db=$(echo "$new_db" | jq --arg pkg "$pkg" --argjson entry "$new_entry" '.packages[$pkg] = $entry')
            done < "$DB_FILE"
            write_db "$new_db"
        fi
    fi
}

# Function to check if a command exists
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check script dependencies
check_script_dependencies() {
    local missing_deps=()
    local required_commands=("curl" "grep" "sed" "awk" "jq" "tar" "file")
    
    for cmd in "${required_commands[@]}"; do
        if ! check_command "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_color "$RED" "Missing required dependencies:"
        printf '%s\n' "${missing_deps[@]}"
        
        read -p "Would you like to install these dependencies? (requires sudo) [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt-get update >/dev/null 2>&1
            sudo apt-get install -y "${missing_deps[@]}" >/dev/null 2>&1
            
            # Verify installation
            local still_missing=()
            for cmd in "${missing_deps[@]}"; do
                if ! check_command "$cmd"; then
                    still_missing+=("$cmd")
                fi
            done
            
            if [ ${#still_missing[@]} -ne 0 ]; then
                print_color "$RED" "Failed to install some dependencies:"
                printf '%s\n' "${still_missing[@]}"
                echo "Please install them manually and try again."
                exit 1
            fi
        else
            print_color "$RED" "Required dependencies must be installed to continue."
            exit 1
        fi
    fi
}

# Function to initialize cache
init_cache() {
    if [ ! -f "$CACHE_FILE" ]; then
        echo '{"cache_version":"1.0","repositories":{}}' > "$CACHE_FILE"
    fi
    mkdir -p "$ASSETS_CACHE_DIR"
    
    # Clean any orphaned cache entries (older than 30 days)
    find "$ASSETS_CACHE_DIR" -type f -mtime +30 -delete 2>/dev/null
}

# Function to get cached release
get_cached_release() {
    local repo=$1
    
    # If override cache is set, skip cache
    if [ "$OVERRIDE_CACHE" -eq 1 ]; then
        return 1
    fi
    
    local cache_data
    local last_checked
    local current_time
    
    # Check if cache exists and is readable
    if [ ! -r "$CACHE_FILE" ]; then
        return 1
    fi
    
    # Try to get cached data
    cache_data=$(jq -r --arg repo "$repo" '.repositories[$repo] // empty' "$CACHE_FILE")
    if [ -z "$cache_data" ]; then
        return 1
    fi
    
    # Check if cache is still valid
    last_checked=$(echo "$cache_data" | jq -r '.last_checked')
    current_time=$(date -u +%s)
    last_checked_ts=$(date -u -d "$last_checked" +%s 2>/dev/null)
    
    if [ $? -eq 0 ] && [ $((current_time - last_checked_ts)) -lt "$CACHE_TTL" ]; then
        # Cache is valid, return the cached release
        echo "$cache_data" | jq -r '.latest_release'
        return 0
    fi
    
    return 1
}

# Function to update cache
update_cache() {
    local repo=$1
    local release=$2
    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local temp_file=$(mktemp)
    
    # Update cache with new data
    jq --arg repo "$repo" \
       --arg time "$current_time" \
       --argjson release "$release" \
       '.repositories[$repo] = {
           "last_checked": $time,
           "latest_release": $release
       }' "$CACHE_FILE" > "$temp_file"
    
    # Move temporary file to cache file
    mv "$temp_file" "$CACHE_FILE"
}

# Function to get latest GitHub release information
get_github_release() {
    local repo=$1
    local response
    
    # Try to get from cache first
    response=$(get_cached_release "$repo")
    if [ $? -eq 0 ]; then
        echo "$response"
        return 0
    fi
    
    # If not in cache or expired, fetch from GitHub API
    local auth_header=""
    if [ -n "$GITHUB_TOKEN" ]; then
        auth_header="Authorization: Bearer $GITHUB_TOKEN"
    fi
    
    response=$(curl -s -H "$auth_header" \
        "https://api.github.com/repos/$repo/releases/latest")
    
    # If successful, update cache
    if [ $? -eq 0 ] && echo "$response" | jq -e . >/dev/null 2>&1; then
        if [ -z "$(echo "$response" | jq -r '.message // empty')" ]; then
            update_cache "$repo" "$response"
        fi
    fi
    
    echo "$response"
}

# Function to find appropriate binary asset
find_binary_asset() {
    local release=$1
    local package=$2
    local arch=$(uname -m)
    local patterns=()
    local debug_output=""
    
    # Select patterns based on architecture
    case "$arch" in
        x86_64|amd64)
            patterns=("${x86_64_patterns[@]}")
            ;;
        aarch64|arm64)
            patterns=("${arm64_patterns[@]}")
            ;;
        *)
            print_color "$RED" "Unsupported architecture: $arch" >&2
            return 1
            ;;
    esac
    
    # Store debug output
    debug_output="Architecture: $arch\nAvailable assets for $package:\n"
    debug_output+="$(echo "$release" | jq -r '.assets[].name' 2>/dev/null || echo "")\n"
    
    # First try exact package name match with architecture and linux
    for pattern in "${patterns[@]}"; do
        local asset_url=$(echo "$release" | jq -r --arg pattern "$pattern" \
            '.assets[] | select(.name | test("linux.*(" + $pattern + ")") or test("(" + $pattern + ").*linux") or test("linux[_-]?64")) | select(.name | endswith(".tar.gz") or endswith(".tgz") or endswith(".zip")) | .browser_download_url' 2>/dev/null | head -n1)
        if [ -n "$asset_url" ] && [ "$asset_url" != "null" ]; then
            local asset_name=$(echo "$release" | jq -r --arg url "$asset_url" \
                '.assets[] | select(.browser_download_url == $url) | .name' 2>/dev/null)
            echo "{\"name\": \"$asset_name\", \"url\": \"$asset_url\"}"
            return 0
        fi
    done
    
    # Try just architecture match if linux match fails
    for pattern in "${patterns[@]}"; do
        local asset_url=$(echo "$release" | jq -r --arg pattern "$pattern" \
            '.assets[] | select(.name | test($pattern)) | select(.name | endswith(".tar.gz") or endswith(".tgz") or endswith(".zip")) | .browser_download_url' 2>/dev/null | head -n1)
        if [ -n "$asset_url" ] && [ "$asset_url" != "null" ]; then
            local asset_name=$(echo "$release" | jq -r --arg url "$asset_url" \
                '.assets[] | select(.browser_download_url == $url) | .name' 2>/dev/null)
            echo "{\"name\": \"$asset_name\", \"url\": \"$asset_url\"}"
            return 0
        fi
    done
    
    # Try just the package name with common extensions
    local asset_url=$(echo "$release" | jq -r --arg pkg "$package" \
        '.assets[] | select(.name | test("^" + $pkg + "[-_.].*\\.(tar\\.gz|tgz|zip)$")) | .browser_download_url' 2>/dev/null | head -n1)
    if [ -n "$asset_url" ] && [ "$asset_url" != "null" ]; then
        local asset_name=$(echo "$release" | jq -r --arg url "$asset_url" \
            '.assets[] | select(.browser_download_url == $url) | .name' 2>/dev/null)
        echo "{\"name\": \"$asset_name\", \"url\": \"$asset_url\"}"
        return 0
    fi
    
    # If we get here, no suitable asset was found, show debug info
    print_color "$RED" "$debug_output" >&2
    return 1
}

# Function to get cached asset
get_cached_asset() {
    local repo=$1
    local asset_name=$2
    local asset_url=$3
    local repo_dir="$ASSETS_CACHE_DIR/${repo//\//_}"
    local cached_path="$repo_dir/$asset_name"
    
    # If override cache is set or asset doesn't exist in cache, return empty
    if [ "$OVERRIDE_CACHE" -eq 1 ] || [ ! -f "$cached_path" ]; then
        return 1
    fi
    
    # Get cached metadata
    local meta_file="${cached_path}.meta"
    if [ -f "$meta_file" ]; then
        local cached_url=$(cat "$meta_file")
        # If URL matches, return cached path
        if [ "$cached_url" = "$asset_url" ]; then
            echo "$cached_path"
            return 0
        fi
    fi
    
    return 1
}

# Function to cache asset
cache_asset() {
    local repo=$1
    local asset_name=$2
    local asset_url=$3
    local downloaded_file=$4
    
    local repo_dir="$ASSETS_CACHE_DIR/${repo//\//_}"
    local cached_path="$repo_dir/$asset_name"
    local meta_file="${cached_path}.meta"
    
    # Clean old cache entries before adding new one
    clean_old_cache "$repo" "$cached_path"
    
    # Create repo directory if it doesn't exist
    mkdir -p "$repo_dir"
    
    # Copy file to cache
    cp "$downloaded_file" "$cached_path"
    # Store URL in metadata file
    echo "$asset_url" > "$meta_file"
}

# Function to clean old cache entries
clean_old_cache() {
    local repo=$1
    local new_asset=$2
    local repo_dir="$ASSETS_CACHE_DIR/${repo//\//_}"
    
    # Skip if repo directory doesn't exist
    [ ! -d "$repo_dir" ] && return 0
    
    # Remove all files except the new asset and its metadata
    find "$repo_dir" -type f ! -name "$(basename "$new_asset")" ! -name "$(basename "$new_asset").meta" -delete 2>/dev/null
}

# Function to download and extract asset
download_and_extract() {
    local url=$1
    local filename=$2
    local target_dir=$3
    local repo=$4
    
    # Try to get from cache first
    local cached_file
    cached_file=$(get_cached_asset "$repo" "$filename" "$url")
    local download_path
    
    if [ $? -eq 0 ] && [ -f "$cached_file" ]; then
        download_path="$cached_file"
        # Set global variable to indicate cache was used
        USED_CACHE=1
    else
        # Download if not in cache
        print_color "$YELLOW" "Downloading $filename..."
        download_path="$TEMP_DIR/$filename"
        if ! curl -sL --progress-bar -o "$download_path" "$url"; then
            print_color "$RED" "Failed to download $filename"
            return 1
        fi
        # Cache the downloaded file
        cache_asset "$repo" "$filename" "$url" "$download_path"
        USED_CACHE=0
    fi
    
    # Extract based on file extension
    case "$filename" in
        *.tar.gz|*.tgz)
            tar xzf "$download_path" -C "$target_dir"
            ;;
        *.zip)
            unzip -q "$download_path" -d "$target_dir"
            ;;
        *)
            print_color "$RED" "Unsupported archive format: $filename"
            return 1
            ;;
    esac
    
    return 0
}

# Function to check and install dependencies
check_dependencies() {
    local binary_path=$1
    local -a missing_deps=()
    local -a satisfied_deps=()
    
    if ! command -v ldd >/dev/null 2>&1; then
        print_color "$RED" "ldd not found, cannot check dependencies"
        return 1
    fi
    
    # Check if static or dynamic
    if ldd "$binary_path" 2>&1 | grep -q "not a dynamic executable"; then
        echo "static"
        return 0
    fi
    
    # Get all dependencies
    while IFS= read -r line; do
        if [[ $line == *"not found"* ]]; then
            local dep=$(echo "$line" | awk '{print $1}')
            missing_deps+=("$dep")
        elif [[ $line == *"=>"* ]]; then
            local dep=$(echo "$line" | awk '{print $1}')
            satisfied_deps+=("$dep")
        fi
    done < <(ldd "$binary_path" 2>/dev/null)
    
    if [ ${#missing_deps[@]} -eq 0 ]; then
        echo "satisfied"
        return 0
    fi
    
    # Convert missing deps to package names if possible
    local -a missing_packages=()
    for dep in "${missing_deps[@]}"; do
        local pkg=$(apt-file search "$dep" 2>/dev/null | head -n1 | cut -d: -f1)
        if [ ! -z "$pkg" ]; then
            missing_packages+=("$pkg")
        else
            missing_packages+=("$dep")
        fi
    done
    
    printf "%s\n" "${missing_packages[@]}"
    return 1
}

# Function to install via apt
install_apt_version() {
    local package=$1
    print_color "$GREEN" "Installing $package via apt..."
    sudo apt-get install -y "$package"
}

# Function to install GitHub version
install_github_version() {
    local package=$1
    local info="${PACKAGE_INFO[$package]}"
    local IFS='|'
    local fields=($info)
    local binary_path="${fields[4]}"
    local github_version="${fields[1]}"
    local target_dir="$HOME/.local/bin"
    
    if [ ! -f "$binary_path" ]; then
        print_color "$RED" "Error: Binary file not found at $binary_path"
        return 1
    fi
    
    # Create target directory if it doesn't exist
    mkdir -p "$target_dir"
    
    # Install binary
    print_color "$GREEN" "Installing $package to $target_dir..."
    local target_path="$target_dir/$package"
    if ! cp "$binary_path" "$target_path"; then
        print_color "$RED" "Failed to install $package"
        return 1
    fi
    
    # Make binary executable
    chmod +x "$target_path"
    
    # Check if binary works
    if ! "$target_path" --version >/dev/null 2>&1; then
        print_color "$RED" "Warning: Installed binary may not work correctly"
        return 1
    fi
    
    # Record the installation
    record_installation "$package" "$github_version" "$target_path"
    
    print_color "$GREEN" "Successfully installed $package"
    return 0
}

# Function to install completions and man pages
install_completions() {
    local package=$1
    local completions=$2
    
    if [ -z "$completions" ]; then
        return 0
    fi
    
    # Create completion directories if they don't exist
    local bash_comp_dir="$HOME/.local/share/bash-completion/completions"
    local zsh_comp_dir="$HOME/.local/share/zsh/site-functions"
    local man_dir="$HOME/.local/share/man/man1"
    
    mkdir -p "$bash_comp_dir" "$zsh_comp_dir" "$man_dir"
    
    local installed_files=()
    while IFS= read -r file; do
        case "$file" in
            *bash-completion*|*bash_completion*)
                cp "$file" "$bash_comp_dir/$package"
                installed_files+=("$bash_comp_dir/$package")
                ;;
            *zsh-completion*|*zsh_completion*)
                cp "$file" "$zsh_comp_dir/_$package"
                installed_files+=("$zsh_comp_dir/_$package")
                ;;
            *.1|*.1.gz)
                cp "$file" "$man_dir/"
                installed_files+=("$man_dir/$(basename "$file")")
                ;;
        esac
    done <<< "$completions"
    
    echo "${installed_files[@]}"
}

# Function to setup PATH if needed
setup_path() {
    local shell_rc=""
    case "$SHELL" in
        */bash) shell_rc="$HOME/.bashrc" ;;
        */zsh)  shell_rc="$HOME/.zshrc" ;;
        *)      print_color "$RED" "Unsupported shell: $SHELL"; return 1 ;;
    esac
    
    if ! grep -q "$INSTALL_DIR" "$shell_rc"; then
        echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$shell_rc"
        print_color "$GREEN" "Added $INSTALL_DIR to PATH in $shell_rc"
    fi
}

# Function to process GitHub binary with version comparison
process_github_binary() {
    local repo=$1
    local package=${repo#*/}
    local release binary_path=""
    local apt_version github_version status
    local -A binary_info
    local update_mode=${2:-""}
    
    # Get APT version
    apt_version=$(get_apt_version "$package")
    
    # Get GitHub version
    release=$(get_github_release "$repo")
    if [ "$release" = "{}" ]; then
        print_color "$RED" "Failed to get release info for $package" >&2
        return 1
    fi
    github_version=$(echo "$release" | jq -r '.tag_name')
    
    # Compare versions
    if [ "$apt_version" != "not found" ]; then
        status=$(version_compare "$github_version" "$apt_version")
        case $status in
            "newer") status="GitHub";;
            "older") status="APT";;
            "equal") status="Equal";;
        esac
    else
        status="GitHub only"
    fi
    
    # If in update mode and not newer version available, skip
    if [ "$update_mode" = "update" ] && [ "$status" != "GitHub" ]; then
        print_color "$YELLOW" "No update available for $package" >&2
        return 0
    fi
    
    # Find appropriate binary asset
    local asset=$(find_binary_asset "$release" "$package")
    if [ -z "$asset" ] || [ "$asset" = "null" ]; then
        print_color "$RED" "No suitable binary found for $package" >&2
        return 1
    fi
    
    # Parse asset JSON
    local asset_name=$(echo "$asset" | jq -r '.name')
    local asset_url=$(echo "$asset" | jq -r '.url')
    
    # If we got the browser_download_url, use that directly
    if [ -n "$asset_url" ] && [ "$asset_url" != "null" ]; then
        # Process binary information
        local package_dir="$TEMP_DIR/packages/$package"
        mkdir -p "$package_dir"
        
        # Download and extract the asset
        USED_CACHE=0
        if ! download_and_extract "$asset_url" "$asset_name" "$package_dir" "$repo"; then
            print_color "$RED" "Failed to process asset for $package" >&2
            return 1
        fi
        
        # Find the binary - first try exact name match
        binary_path=$(find "$package_dir" -type f -executable -name "$package" 2>/dev/null)
        
        if [ -z "$binary_path" ]; then
            # Try finding binary in common locations
            for subdir in "" "bin/" "$package/" "${package}-"*"/"; do
                if [ -x "$package_dir/$subdir$package" ]; then
                    binary_path="$package_dir/$subdir$package"
                    break
                fi
            done
        fi
        
        if [ -z "$binary_path" ]; then
            # Try finding any executable as last resort
            binary_path=$(find "$package_dir" -type f -executable 2>/dev/null | head -n1)
        fi
        
        if [ -n "$binary_path" ]; then
            # Check dependencies
            local deps_status=$(check_dependencies "$binary_path")
            case "$deps_status" in
                "static")
                    binary_info["dependencies"]="No, static"
                    ;;
                "satisfied")
                    binary_info["dependencies"]="Yes, satisfied"
                    ;;
                *)
                    binary_info["dependencies"]="Yes, needed"
                    binary_info["missing_deps"]="$deps_status"
                    ;;
            esac
            
            # Look for completions and man pages
            binary_info["completions"]=$(find "$package_dir" -type f \( -name "*completion*" -o -name "*man1*" -o -name "*.1" -o -name "*.1.gz" \) -print0 2>/dev/null | tr '\0' '\n')
        else
            print_color "$RED" "Could not find binary in extracted files for $package" >&2
            return 1
        fi
    else
        print_color "$RED" "Failed to get download URL for $package" >&2
        return 1
    fi
    
    # Create version comparison string with color
    local gh_display_ver="${github_version#v}"
    local version_info
    if [ "$apt_version" != "not found" ] && [ "$status" = "GitHub" ]; then
        version_info="$gh_display_ver*"
    else
        version_info="$gh_display_ver"
    fi

    # Clean up APT version display
    local apt_display_ver
    if [ "$apt_version" != "not found" ]; then
        apt_display_ver=$(extract_version_numbers "$apt_version")
    else
        apt_display_ver="not found"
    fi

    # Truncate asset name if too long
    local display_asset="${asset_name:0:40}"
    if [ "${#asset_name}" -gt 40 ]; then
        display_asset="${display_asset:0:37}..."
    fi
    
    # Add (cached) indicator if asset was from cache
    if [ "$USED_CACHE" -eq 1 ]; then
        display_asset="$display_asset (cached)"
    fi

    # Print table row with fixed width columns
    printf "%-15s %-12s %-12s %-40s\n" \
        "$package" \
        "$version_info" \
        "$apt_display_ver" \
        "$display_asset"
    
    # Store information for installation
    PACKAGE_INFO["$package"]="$apt_version|$github_version|$status|$asset_name|$binary_path|${binary_info["dependencies"]}|${binary_info["missing_deps"]}|${binary_info["completions"]}"
}

# Function to print version table header
print_version_table_header() {
    echo "Checking versions..."
    printf "%-15s %-12s %-12s %-40s\n" \
        "Binary" \
        "Github" \
        "APT" \
        "Asset"
    echo "------------------------------------------------------------------------------------------------"
}

# Function to load repositories
load_repos() {
    declare -g REPOS=()
    # Check if repos.txt exists in the same directory as the script
    if [ -f "$repos_file" ]; then
        while IFS= read -r repo || [ -n "$repo" ]; do
            # Skip empty lines and comments
            [[ -z "$repo" || "$repo" =~ ^[[:space:]]*# ]] && continue
            # Validate repo format
            if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
                REPOS+=("$repo")
            else
                print_color "$YELLOW" "Warning: Invalid repository format in repos.txt: $repo"
            fi
        done < "$repos_file"
    else
        print_color "$YELLOW" "No repos.txt found. Please enter repository URLs (format: owner/repo-name)"
        print_color "$YELLOW" "Enter an empty line when done."
        
        while true; do
            read -p "Repository (owner/repo-name): " repo
            [[ -z "$repo" ]] && break
            
            if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
                REPOS+=("$repo")
            else
                print_color "$YELLOW" "Invalid format. Please use format: owner/repo-name (e.g., junegunn/fzf)"
            fi
        done
    fi

    # Check if we have any repos to process
    if [ ${#REPOS[@]} -eq 0 ]; then
        print_color "$RED" "No valid repositories found. Exiting."
        exit 1
    fi

    print_color "$GREEN" "Processing repositories:"
    printf '%s\n' "${REPOS[@]}"
    echo
}

# Function to extract version numbers
extract_version_numbers() {
    local version=$1
    # Remove 'v' prefix if present
    version="${version#v}"
    # Remove Ubuntu/Debian specific parts (e.g., -1ubuntu0.1)
    version="${version%%-*}"
    # Extract only numbers and dots, remove any other characters
    version=$(echo "$version" | sed -E 's/[^0-9.]//g')
    echo "$version"
}

# Function to compare version strings
version_compare() {
    local ver1=$(extract_version_numbers "$1")
    local ver2=$(extract_version_numbers "$2")
    
    if [[ "$ver1" == "$ver2" ]]; then
        echo "equal"
        return
    fi
    
    # Convert versions to arrays
    local IFS=.
    read -ra VER1 <<< "$ver1"
    read -ra VER2 <<< "$ver2"
    
    # Get the maximum length
    local max_length=$(( ${#VER1[@]} > ${#VER2[@]} ? ${#VER1[@]} : ${#VER2[@]} ))
    
    # Compare each component
    for ((i=0; i<max_length; i++)); do
        local v1=${VER1[$i]:-0}
        local v2=${VER2[$i]:-0}
        
        if (( v1 > v2 )); then
            echo "newer"
            return
        elif (( v1 < v2 )); then
            echo "older"
            return
        fi
    done
    
    # If we get here, versions are equal
    echo "equal"
}

# Function to get APT package version
get_apt_version() {
    local package=$1
    local version
    
    # Try to get version from both provided name and mapped name
    version=$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2}')
    
    # Return "not found" if package isn't available or installed
    if [ -z "$version" ]; then
        echo "not found"
    else
        echo "$version"
    fi
}

# Function to parse version from --version output
parse_binary_version() {
    local binary=$1
    local version_output=$2
    local version=""
    
    case "$(basename "$binary")" in
        "bat")
            version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            ;;
        "eza")
            version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            if [ -z "$version" ]; then
                # Try getting version from binary directly
                version=$("$binary" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            fi
            ;;
        "fd")
            version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            ;;
        "fzf")
            version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            ;;
        "micro")
            version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            ;;
        "zoxide")
            version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            ;;
        *)
            # Generic version number extraction
            version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
            ;;
    esac
    
    echo "${version:-Unknown}"
}

# Function to list installed packages
list_installed_packages() {
    local target_dir="$HOME/.local/bin"
    local db_file="$DATA_DIR/installed.db"
    
    echo "Packages managed by ghr-installer:"
    echo
    printf "%-15s %-12s %-20s\n" "Package" "Version" "Location"
    echo "-------------------------------------------------------"
    
    # Read each line from installed.db if it exists
    if [ -f "$db_file" ]; then
        while IFS='|' read -r package version path timestamp; do
            if [ -f "$path" ]; then
                # Try to get current version
                local version_output=$("$path" --version 2>/dev/null | head -n1 || echo "Unknown")
                local current_version=$(parse_binary_version "$path" "$version_output")
                printf "%-15s %-12s %-20s\n" \
                    "$package" \
                    "$current_version" \
                    "$path"
            fi
        done < "$db_file"
    else
        echo "No packages installed yet."
    fi
}

# Function to record installation in database
record_installation() {
    local package=$1
    local version=$2
    local path=$3
    local timestamp=$(date +%s)
    local db_file="$DATA_DIR/installed.db"
    local temp_file="$DATA_DIR/installed.db.tmp"
    
    # Create data directory if it doesn't exist
    mkdir -p "$DATA_DIR"
    
    # Remove existing entry for this package
    if [ -f "$db_file" ]; then
        grep -v "^$package|" "$db_file" > "$temp_file" 2>/dev/null
    fi
    
    # Add new entry
    echo "$package|$version|$path|$timestamp" >> "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$db_file"
}

# Function to install selected packages
install_selected_packages() {
    local mode=$1
    local install_count=0
    local error_count=0
    
    for package in "${!PACKAGE_INFO[@]}"; do
        local info="${PACKAGE_INFO[$package]}"
        local IFS='|'
        local fields=($info)
        local apt_version="${fields[0]}"
        local github_version="${fields[1]}"
        local status="${fields[2]}"
        
        case "$mode" in
            "newer")
                if [ "$status" != "GitHub" ]; then
                    continue
                fi
                ;;
            "github")
                # Always install GitHub version
                ;;
            "apt")
                if [ "$apt_version" = "not found" ]; then
                    continue
                fi
                ;;
            *)
                continue
                ;;
        esac
        
        if [ "$mode" = "apt" ]; then
            if ! sudo apt-get install -y "$package"; then
                print_color "$RED" "Failed to install $package via APT"
                ((error_count++))
            else
                ((install_count++))
            fi
        else
            if install_github_version "$package"; then
                ((install_count++))
            else
                ((error_count++))
            fi
        fi
    done
    
    if [ $install_count -gt 0 ]; then
        print_color "$GREEN" "\nSuccessfully installed $install_count package(s)"
    fi
    if [ $error_count -gt 0 ]; then
        print_color "$RED" "Failed to install $error_count package(s)"
    fi
    
    return $error_count
}

# Print usage information
usage() {
    print_color "$BOLD" "Usage: $0 [OPTIONS]"
    print_color "$BOLD" "Options:"
    print_color "$BOLD" "  --update PACKAGE    Update specified package"
    print_color "$BOLD" "  --remove PACKAGE    Remove specified package"
    print_color "$BOLD" "  --list             List installed packages"
    print_color "$BOLD" "  --override-cache   Bypass cache and fetch fresh data"
    print_color "$BOLD" "  --help             Show this help message"
    echo
    print_color "$BOLD" "Without options, runs in interactive mode"
}

# Main function
main() {
    # Initialize database
    init_db
    
    # Initialize cache
    init_cache
    
    # Parse command line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --update|-u)
                if [ -z "$2" ]; then
                    print_color "$RED" "Error: Package name required for update"
                    usage
                    exit 1
                fi
                local repo=$(grep -l "$2" "$repos_file" | xargs grep -l "/" | head -n1)
                if [ -z "$repo" ]; then
                    print_color "$RED" "Package $2 not found in repos.txt"
                    exit 1
                fi
                process_github_binary "$repo" "update"
                shift 2
                ;;
            --remove|-r)
                if [ -z "$2" ]; then
                    print_color "$RED" "Error: Package name required for removal"
                    usage
                    exit 1
                fi
                remove_package "$2"
                shift 2
                ;;
            --list|-l)
                list_installed_packages
                exit 0
                ;;
            --override-cache)
                OVERRIDE_CACHE=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            -*)
                print_color "$RED" "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Check script dependencies
    check_script_dependencies
    
    # Load repositories
    load_repos
    
    # Initialize package info array
    declare -A PACKAGE_INFO
    declare -A ALL_DEPENDENCIES
    
    # Print table header
    print_version_table_header
    
    # Process each repository
    for repo in "${REPOS[@]}"; do
        process_github_binary "$repo"
    done
    
    # Collect all needed dependencies
    print_color "$BOLD" "\nDependencies needed:"
    for package in "${!PACKAGE_INFO[@]}"; do
        IFS='|' read -r _ _ _ _ _ deps missing_deps _ <<< "${PACKAGE_INFO[$package]}"
        if [ "$deps" = "Yes, needed" ]; then
            for dep in $missing_deps; do
                ALL_DEPENDENCIES["$dep"]=1
            done
        fi
    done
    
    if [ ${#ALL_DEPENDENCIES[@]} -gt 0 ]; then
        printf "%s\n" "${!ALL_DEPENDENCIES[@]}"
    else
        print_color "$GREEN" "No additional dependencies required"
    fi
    
    # Print installation options
    print_color "$BOLD" "\nInstallation options:"
    print_color "$BOLD" "1. Install all newer versions"
    print_color "$BOLD" "2. Install all GitHub versions (to $INSTALL_DIR)"
    print_color "$BOLD" "3. Install all APT versions"
    print_color "$BOLD" "4. Choose individually"
    print_color "$BOLD" "5. Cancel"
    
    read -p "Select installation method [1-5]: " choice
    
    case $choice in
        1|2|3|4)
            case $choice in
                1) # Install newer versions
                    install_selected_packages "newer"
                    ;;
                2) # Install all GitHub versions
                    install_selected_packages "github"
                    ;;
                3) # Install all APT versions
                    install_selected_packages "apt"
                    ;;
                4) # Choose individually
                    for package in "${!PACKAGE_INFO[@]}"; do
                        IFS='|' read -r apt_ver gh_ver status asset path deps missing_deps completions <<< "${PACKAGE_INFO[$package]}"
                        print_color "$BOLD" "\n$package:"
                        print_color "$BOLD" "1. Install GitHub version ($gh_ver)"
                        if [[ "$apt_ver" != "not found" ]]; then
                            print_color "$BOLD" "2. Install APT version ($apt_ver)"
                        fi
                        print_color "$BOLD" "3. Skip"
                        
                        read -p "Choose version to install [1-3]: " ver_choice
                        case $ver_choice in
                            1) install_github_version "$package";;
                            2) install_apt_version "$package";;
                            *) print_color "$YELLOW" "Skipping $package";;
                        esac
                    done
                    ;;
            esac
            ;;
        *)
            print_color "$YELLOW" "${BOLD}Exit, no changes made${NC}"
            ;;
    esac
    
    # Clean up
    rm -rf "$TEMP_DIR"
}

# Execute main function with all arguments
main "$@"