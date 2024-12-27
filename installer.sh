#!/usr/bin/env bash

# Architecture patterns for binary matching
declare -a x86_64_patterns=(
    ".*linux.*x86[_-]64"
    ".*linux.*amd64"
    ".*linux.*64.*bit"
    ".*linux.*64"
    ".*x86[_-]64.*linux"
    ".*amd64.*linux"
    ".*linux.*"  # More generic fallback
)

declare -a arm64_patterns=(
    ".*linux.*aarch64"
    ".*linux.*arm64"
    ".*aarch64.*linux"
    ".*arm64.*linux"
    ".*linux.*"  # More generic fallback
)

# Colors for output
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
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
REPOS_FILE="repos.txt"
TEMP_DIR=$(mktemp -d)
SHELLS=("/bin/bash" "/bin/zsh")

# Global variables
declare -A PACKAGE_INFO
declare -A REPO_ALIASES

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
    mkdir -p "$CACHE_DIR" "$ASSETS_CACHE_DIR"
    if [ ! -f "$CACHE_FILE" ]; then
        echo "{}" > "$CACHE_FILE"
    fi
}

# Function to get cached release
get_cached_release() {
    local cache_key="$1"
    local cache_file="$CACHE_DIR/releases/$cache_key"
    
    if [ -f "$cache_file" ]; then
        cat "$cache_file"
        return 0
    fi
    return 1
}

# Function to update cache
update_cache() {
    local cache_key="$1"
    local version="$2"
    local assets="$3"
    local cache_file="$CACHE_DIR/releases/$cache_key"
    
    # Create cache directory if it doesn't exist
    mkdir -p "$(dirname "$cache_file")"
    
    # Write version to first line
    echo "$version" > "$cache_file"
    
    # Write assets to subsequent lines
    if [ -n "$assets" ]; then
        echo "$assets" >> "$cache_file"
    fi
}

# Function to get latest GitHub release information
get_github_release() {
    local repo="$1"
    local cache_key="$repo"
    local release_info
    
    # Try to get from cache first
    if [ "$OVERRIDE_CACHE" != "1" ]; then
        release_info=$(get_cached_release "$cache_key")
        if [ -n "$release_info" ]; then
            echo "$release_info"
            return
        fi
    fi
    
    # Prepare API URL
    local api_url="https://api.github.com/repos/$repo/releases/latest"
    api_url="${api_url%"${api_url##*[![:space:]]}"}"  # Remove trailing spaces
    
    # Prepare headers array
    declare -a headers=()
    if [ -n "$GITHUB_TOKEN" ]; then
        headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    
    # Make API request
    local response
    response=$(curl -sL ${headers[@]+"${headers[@]}"} "$api_url")
    
    # Check if response is valid JSON and contains tag_name
    if ! echo "$response" | jq -e .tag_name > /dev/null 2>&1; then
        # Return empty string to indicate no release found
        echo ""
        return
    fi
    
    # Extract version and assets
    local version=$(echo "$response" | jq -r .tag_name)
    version="${version#v}"  # Remove leading 'v' if present
    local assets=$(echo "$response" | jq -r '.assets[] | .name + "," + .browser_download_url' 2>/dev/null)
    
    # Cache the result
    update_cache "$cache_key" "$version" "$assets"
    
    # Return the cached result
    get_cached_release "$cache_key"
}

# Function to find appropriate binary asset
find_binary_asset() {
    local release_info="$1"
    local version=$(echo "$release_info" | head -n1)
    local best_asset=""
    local best_score=0
    
    # If no assets section, return empty
    if [ "$(echo "$release_info" | wc -l)" -le 1 ]; then
        return
    fi
    
    # Skip first line (version) and process each asset
    while IFS=',' read -r name url; do
        [ -z "$name" ] && continue
        
        local score=0
        local matched_pattern=""
        
        # Check for architecture match
        for pattern in "${x86_64_patterns[@]}"; do
            if [[ "$name" =~ $pattern ]]; then
                score=$((score + 2))
                matched_pattern="$pattern"
                break
            fi
        done
        
        # Skip if no architecture match
        [ $score -eq 0 ] && continue
        
        # Prefer certain formats
        case "$name" in
            *.tar.gz|*.tgz)
                score=$((score + 2))
                ;;
            *.zip)
                score=$((score + 1))
                ;;
        esac
        
        # Update best match if we found a better score
        if [ $score -gt $best_score ]; then
            best_score=$score
            best_asset="$name,$url"
        fi
    done < <(echo "$release_info" | tail -n +2)
    
    # Return the best matching asset
    if [ -n "$best_asset" ]; then
        echo "$best_asset"
    fi
}

# Function to get cached asset
get_cached_asset() {
    local repo=$1
    local filename=$2
    local cache_path="$ASSETS_CACHE_DIR/${repo//\//_}_$filename"
    
    if [ -f "$cache_path" ]; then
        # Check if cache is still valid
        local mtime=$(stat -c %Y "$cache_path")
        local now=$(date +%s)
        local age=$((now - mtime))
        
        if [ $age -lt $CACHE_TTL ] && [ ! $OVERRIDE_CACHE -eq 1 ]; then
            echo "$cache_path"
            return 0
        fi
    fi
    
    return 1
}

# Function to cache asset
cache_asset() {
    local repo=$1
    local filename=$2
    local filepath=$3
    local cache_path="$ASSETS_CACHE_DIR/${repo//\//_}_$filename"
    
    mkdir -p "$ASSETS_CACHE_DIR"
    cp "$filepath" "$cache_path"
}

# Function to download and extract asset
download_and_extract() {
    local url=$1
    local filename=$2
    local target_dir=$3
    local repo=$4
    local cached_path
    
    # Check cache first
    cached_path=$(get_cached_asset "$repo" "$filename")
    if [ $? -eq 0 ] && [ -n "$cached_path" ] && [ -f "$cached_path" ]; then
        cp "$cached_path" "$target_dir/$filename"
        USED_CACHE=1
    else
        USED_CACHE=0
        # Download if not in cache
        if ! curl -sL -H "Accept: application/octet-stream" "$url" -o "$target_dir/$filename"; then
            print_color "$RED" "Failed to download $filename" >&2
            return 1
        fi
        # Cache the downloaded asset
        cache_asset "$repo" "$filename" "$target_dir/$filename"
    fi
    
    # Extract based on file extension
    case "$filename" in
        *.tar.gz|*.tgz)
            tar -xzf "$target_dir/$filename" -C "$target_dir"
            ;;
        *.zip)
            unzip -q "$target_dir/$filename" -d "$target_dir"
            ;;
        *.gz)
            gunzip -c "$target_dir/$filename" > "$target_dir/${filename%.gz}"
            chmod +x "$target_dir/${filename%.gz}"
            ;;
        *)
            if [ -f "$target_dir/$filename" ]; then
                chmod +x "$target_dir/$filename"
                return 0
            fi
            print_color "$RED" "Unsupported archive format: $filename" >&2
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

# Function to verify binary name matches expectations
verify_binary_name() {
    local repo=$1          # Full repo path (e.g., tldr-pages/tldr-c-client)
    local binary_path=$2   # Path to found binary
    local alias=$3         # Specified alias if any (e.g., tldr)
    
    # Get actual binary name from path
    local actual_binary=$(basename "$binary_path")
    
    # Get repo name (part after /)
    local repo_name=${repo#*/}
    
    # If alias is specified (owner/repo | binary format)
    if [ -n "$alias" ]; then
        if [ "$actual_binary" != "$alias" ]; then
            print_color "$YELLOW" "Warning: Specified binary name '$alias' does not match installed binary '$actual_binary'"
            print_color "$YELLOW" "Please verify this is the correct binary"
        fi
        return 0
    fi
    
    # No alias specified (owner/repo format)
    if [ "$actual_binary" != "$repo_name" ]; then
        print_color "$YELLOW" "Warning: Repository name '$repo_name' does not match installed binary '$actual_binary'"
        print_color "$YELLOW" "Please verify this is the correct binary or specify explicitly in repos.txt as:"
        print_color "$YELLOW" "$repo | $actual_binary"
    fi
    
    return 0
}

# Function to process GitHub binary with version comparison
process_github_binary() {
    local repo="$1"
    local mode="${2:-check}"  # Default mode is check
    local alias="${REPO_ALIASES[$repo]}"
    local binary_name="$alias"
    
    # Special case for tldr which has different binary name
    if [[ "$repo" == "tldr-pages/tldr-c-client" ]]; then
        binary_name="tldr"
    fi
    
    # Get GitHub release info
    local github_info=$(get_github_release "$repo")
    local github_version=""
    local asset_info=""
    local asset_name="-"  # Default to "-" for asset name
    
    if [ -n "$github_info" ]; then
        github_version=$(echo "$github_info" | head -n1)
        asset_info=$(find_binary_asset "$github_info")
        if [ -n "$asset_info" ]; then
            asset_name=$(echo "$asset_info" | cut -d',' -f1)
        else
            # No binary assets found or empty release info, mark as source only
            github_version="source"
        fi
    else
        # No GitHub release info at all
        github_version="source"
    fi
    
    # Get APT version
    local apt_version=$(get_apt_version "$binary_name")
    local installed_version=$(get_installed_version "$binary_name")
    local deps_needed="No"
    local missing_deps=""
    
    # Check dependencies only if we have binary assets and not source-only
    if [ "$mode" = "check" ] && [ -n "$github_version" ] && [ "$github_version" != "source" ] && [ -n "$asset_info" ]; then
        deps_needed=$(check_dependencies "$repo" "$asset_info")
        if [ "$deps_needed" = "Yes" ]; then
            missing_deps=$(check_dependencies "$repo" "$asset_info" "list")
        fi
    fi
    
    # Format asset display name
    local display_asset="$asset_name"
    if [ "$github_version" = "source" ]; then
        display_asset="-"
    elif [ -n "$asset_name" ] && [ "$asset_name" != "-" ] && [ -f "$CACHE_DIR/assets/$asset_name" ]; then
        display_asset="$asset_name (cached)"
    fi
    
    # Add to results array using a format that's easier to parse
    RESULTS+=("binary_name=$binary_name github_version=$github_version apt_version=$apt_version asset=$display_asset dependencies=$deps_needed missing_deps=$missing_deps installed_version=$installed_version")
}

# Function to print version table header
print_version_table_header() {
    printf "%-15s %-12s %-12s %-40s\n" "Binary" "Github" "APT" "Asset"
    printf "%s\n" "------------------------------------------------------------------------------------------------"
}

# Function to print version table row
print_version_table_row() {
    local result="$1"
    declare -A info
    
    # Parse result string into associative array
    while IFS='=' read -r key value; do
        # Remove leading/trailing spaces and quotes
        key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        value=$(echo "$value" | sed -e "s/^['\"]*//" -e "s/['\"]$//")
        info[$key]="$value"
    done < <(echo "$result" | tr ' ' '\n')
    
    # Format GitHub version
    if [ -n "${info[github_version]}" ]; then
        if [ "${info[apt_version]}" != "not found" ] && [ "${info[github_version]}" != "source" ]; then
            info[github_version]="${info[github_version]}*"
        fi
    fi
    
    # Format asset name
    if [ -n "${info[asset]}" ] && [ "${info[asset]}" != "-" ]; then
        if [ ${#info[asset]} -gt 37 ]; then
            info[asset]="${info[asset]:0:34}..."
        fi
    fi
    
    # Ensure "not found" is displayed in full
    if [ "${info[apt_version]}" = "not" ]; then
        info[apt_version]="not found"
    fi
    
    printf "%-15s %-12s %-12s %-40s\n" \
        "${info[binary_name]}" \
        "${info[github_version]:-}" \
        "${info[apt_version]}" \
        "${info[asset]:-}"
}

# Function to process results and print table
process_results() {
    print_version_table_header
    
    # Print each result
    for result in "${RESULTS[@]}"; do
        print_version_table_row "$result"
    done
    
    # Check for missing dependencies
    local missing_deps=0
    local deps_output=""
    
    for result in "${RESULTS[@]}"; do
        local dependencies missing_deps_list
        eval "$(echo "$result" | tr ' ' '\n' | while IFS='=' read -r key value; do
            if [[ "$key" =~ ^(dependencies|missing_deps)$ ]]; then
                echo "$key=${value//\'/}"
            fi
        done)"
        
        if [ "$dependencies" = "Yes" ]; then
            deps_output+="$missing_deps_list\n"
            missing_deps=1
        fi
    done
    
    echo -e "\nDependencies needed:"
    if [ "$missing_deps" = "1" ]; then
        echo -e "$deps_output"
    else
        echo "No additional dependencies required"
    fi
}

# Function to load repositories
load_repos() {
    declare -g REPOS=()
    local repo alias
    
    # Create repos file if it doesn't exist
    if [ ! -f "$REPOS_FILE" ]; then
        mkdir -p "$(dirname "$REPOS_FILE")"
        touch "$REPOS_FILE"
    fi
    
    echo "Processing repositories:"
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        if [[ "$line" =~ ^([^|]+)[[:space:]]*\|[[:space:]]*([^[:space:]]+)$ ]]; then
            # Has explicit alias: "repo | alias"
            repo="${BASH_REMATCH[1]}"
            alias="${BASH_REMATCH[2]}"
        else
            # No alias: "owner/repo"
            repo="$line"
            alias="${line#*/}"  # Gets part after /
        fi
        
        REPOS+=("$repo")
        REPO_ALIASES["$repo"]="$alias"
        echo "$repo"
    done < "$REPOS_FILE"
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
    local package="$1"
    local version
    
    # Get version from apt-cache policy, preferring Candidate if not installed
    version=$(apt-cache policy "$package" 2>/dev/null | awk '/Installed:/ {i=$2} /Candidate:/ {c=$2} END {print (i!="(none)")?i:c}')
    
    # Return "not found" if no version found
    if [ -z "$version" ] || [ "$version" = "(none)" ]; then
        echo "not found"
        return
    fi
    
    # Strip Ubuntu-specific version parts (everything after the first hyphen)
    version="${version%%-*}"
    
    echo "$version"
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
        local apt_ver="${fields[0]}"
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
                if [ "$apt_ver" = "not found" ]; then
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

# Function to clear cache
clear_cache() {
    print_color "$BLUE" "Purging cache..."
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR" "$ASSETS_CACHE_DIR"
    touch "$CACHE_DIR/api-cache.json"
    print_color "$GREEN" "Cache purged!"
    exit 0  # Exit after clearing cache
}

# Print usage information
usage() {
    print_color "$BOLD" "Usage: $0 [OPTIONS]"
    print_color "$BOLD" "Options:"
    print_color "$BOLD" "  --update PACKAGE    Update specified package"
    print_color "$BOLD" "  --remove PACKAGE    Remove specified package"
    print_color "$BOLD" "  --list             List installed packages"
    print_color "$BOLD" "  --clear-cache      Clear GitHub API and asset cache"
    print_color "$BOLD" "  --override-cache   Bypass cache and fetch fresh data"
    print_color "$BOLD" "  --help             Show this help message"
    echo
    print_color "$BOLD" "Without options, runs in interactive mode"
}

# Print system information at start
print_system_info() {
    local arch=$(uname -m)
    echo "System Architecture: $arch"
    echo
}

# Main function
main() {
    # Initialize database
    init_db
    
    # Initialize cache
    init_cache
    
    # Print system info once at start
    print_system_info
    
    # Parse command line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --update|-u)
                if [ -z "$2" ]; then
                    print_color "$RED" "Error: Package name required for update"
                    usage
                    exit 1
                fi
                local repo=$(grep -l "$2" "$REPOS_FILE" | xargs grep -l "/" | head -n1)
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
            --clear-cache)
                clear_cache
                shift
                ;;
            --override-cache)
                OVERRIDE_CACHE=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                print_color "$RED" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Check script dependencies
    check_script_dependencies
    
    # Load repositories
    load_repos
    
    # Initialize results array
    declare -g RESULTS=()
    
    # Process each repository
    for repo in "${REPOS[@]}"; do
        process_github_binary "$repo"
    done
    
    # Process and print results
    process_results
    
    # Print installation options
    print_color "$BOLD" "\nInstallation options:"
    echo "1. Install all newer versions"
    echo "2. Install all GitHub versions (to $INSTALL_DIR)"
    echo "3. Install all APT versions"
    echo "4. Choose individually"
    echo "5. Cancel"
    
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