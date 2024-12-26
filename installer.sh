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

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/.local/share/ghr-installer"
DB_FILE="$DATA_DIR/packages.json"
INSTALL_DIR="$HOME/.local/bin"
repos_file="$SCRIPT_DIR/repos.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Function to print with color
print_color() {
    local color=$1
    local text=$2
    echo -e "${color}${text}${NC}"
}

# Configuration
TEMP_DIR=$(mktemp -d)
SHELLS=("/bin/bash" "/bin/zsh")

# Function to initialize database
init_db() {
    # Create database directory if it doesn't exist
    local db_dir=$(dirname "$DB_FILE")
    if [ ! -d "$db_dir" ]; then
        mkdir -p "$db_dir"
    fi
    
    # Create or validate database file
    if [ ! -f "$DB_FILE" ]; then
        echo '{"packages":{}}' > "$DB_FILE"
        chmod 600 "$DB_FILE"
    else
        # Validate JSON structure
        if ! jq -e . "$DB_FILE" >/dev/null 2>&1; then
            print_color "$RED" "Database file is corrupted. Reinitializing..."
            echo '{"packages":{}}' > "$DB_FILE"
            chmod 600 "$DB_FILE"
        elif ! jq -e '.packages' "$DB_FILE" >/dev/null 2>&1; then
            print_color "$RED" "Database file is missing required structure. Reinitializing..."
            echo '{"packages":{}}' > "$DB_FILE"
            chmod 600 "$DB_FILE"
        fi
    fi
}

# Function to add package to database
add_to_db() {
    local package=$1
    local version=$2
    local binary_path=$3
    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create temporary file
    local temp_file=$(mktemp)
    
    # Update or add package entry
    jq --arg pkg "$package" \
       --arg ver "$version" \
       --arg path "$binary_path" \
       --arg time "$current_time" \
       '.packages[$pkg] = {
           "version": $ver,
           "binary_path": $path,
           "installed_at": $time,
           "updated_at": $time
       }' "$DB_FILE" > "$temp_file"
    
    # Check if jq command succeeded
    if [ $? -eq 0 ]; then
        mv "$temp_file" "$DB_FILE"
        chmod 600 "$DB_FILE"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Function to get package info from database
get_package_info() {
    local package=$1
    if [ ! -f "$DB_FILE" ]; then
        return 1
    fi
    jq -r --arg pkg "$package" '.packages[$pkg]' "$DB_FILE" 2>/dev/null
}

# Function to remove package from database
remove_from_db() {
    local package=$1
    
    # Create lock file
    local lock_file="$DB_FILE.lock"
    if ! mkdir "$lock_file" 2>/dev/null; then
        print_color "$RED" "Database is locked. Another process might be using it."
        return 1
    fi
    
    # Remove package from database
    local temp_file=$(mktemp)
    jq --arg pkg "$package" 'del(.packages[$pkg])' "$DB_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && [ -s "$temp_file" ]; then
        mv "$temp_file" "$DB_FILE"
        rm -rf "$lock_file"
        return 0
    else
        print_color "$RED" "Failed to update database"
        rm -f "$temp_file"
        rm -rf "$lock_file"
        return 1
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

# Function to get GitHub release information
get_github_release() {
    local repo=$1
    local response
    
    if [ -n "$GITHUB_TOKEN" ]; then
        response=$(curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
    else
        response=$(curl -sL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
    fi
    
    # Check for rate limit
    if echo "$response" | jq -e 'has("message")' > /dev/null 2>&1; then
        local message=$(echo "$response" | jq -r '.message')
        if [[ "$message" == *"rate limit"* ]]; then
            print_color "$RED" "GitHub API rate limit exceeded. Please set GITHUB_TOKEN environment variable." >&2
            return 1
        elif [[ "$message" == *"Bad credentials"* ]]; then
            print_color "$RED" "Invalid GitHub token. Please check your GITHUB_TOKEN." >&2
            return 1
        fi
    fi
    
    # Check for valid JSON response
    if ! echo "$response" | jq -e . > /dev/null 2>&1; then
        print_color "$RED" "Invalid JSON response from GitHub API" >&2
        return 1
    fi
    
    echo "$response"
}

# Function to find a suitable binary asset from release assets
find_binary_asset() {
    local release=$1
    local package=$2
    
    # Find suitable asset
    local asset=""
    while IFS= read -r a; do
        local name=$(echo "$a" | jq -r '.name')
        local url=$(echo "$a" | jq -r '.browser_download_url')
        
        # Skip invalid assets
        [ "$name" = "null" ] && continue
        [ "$url" = "null" ] && continue
        
        # Check if asset matches our architecture
        if [[ "$name" =~ linux.*(x86_64|amd64) ]] && [[ "$name" =~ .*$package.* ]]; then
            asset="$a"
            break
        fi
    done < <(echo "$release" | jq -c '.assets[]')
    
    echo "$asset"
}

# Function to download and extract asset
download_and_extract() {
    local asset_url=$1
    local asset_name=$2
    local package_dir=$3
    
    # Use -L to follow redirects and get the direct download URL
    if ! curl -sL "$asset_url" -o "$package_dir/$asset_name"; then
        print_color "$RED" "Failed to download $asset_name" >&2
        return 1
    fi
    
    case "$asset_name" in
        *.tar.gz|*.tgz)
            if ! tar xf "$package_dir/$asset_name" -C "$package_dir"; then
                print_color "$RED" "Failed to extract $asset_name" >&2
                return 1
            fi
            ;;
        *.zip)
            if ! command -v unzip >/dev/null 2>&1; then
                print_color "$YELLOW" "Installing unzip..."
                sudo apt-get update >/dev/null 2>&1
                sudo apt-get install -y unzip >/dev/null 2>&1
            fi
            if ! unzip -q "$package_dir/$asset_name" -d "$package_dir"; then
                print_color "$RED" "Failed to extract $asset_name" >&2
                return 1
            fi
            ;;
        *)
            chmod +x "$package_dir/$asset_name"
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
    
    if [ -z "$info" ]; then
        print_color "$RED" "No installation info found for $package"
        return 1
    fi
    
    # Parse package info
    IFS='|' read -r apt_version github_version status asset_url binary_path deps missing_deps completions <<< "$info"
    
    print_color "$GREEN" "Installing $package version $github_version..."
    
    # Create temp directory
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit
    
    # Download asset
    if [ -n "$GITHUB_TOKEN" ]; then
        curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" "$asset_url" -o "$package.tar.gz" 2>/dev/null
    else
        curl -sL "$asset_url" -o "$package.tar.gz" 2>/dev/null
    fi
    
    # Extract package
    tar xf "$package.tar.gz" 2>/dev/null || true
    
    # Find binary
    local binary=$(find . -type f -executable -name "$package" 2>/dev/null)
    if [ -z "$binary" ]; then
        # Try finding any executable that matches common binary patterns
        while IFS= read -r file; do
            if [[ "$file" =~ /bin/|/dist/|/target/|/build/ ]] || [[ "$file" =~ .*$package.* ]]; then
                if ! [[ "$file" =~ \.sh$ ]] && ! [[ "$file" =~ /test/ ]]; then
                    binary="$file"
                    break
                fi
            fi
        done < <(find . -type f -executable 2>/dev/null)
        
        # If still no binary found, try any executable
        if [ -z "$binary" ]; then
            binary=$(find . -type f -executable 2>/dev/null | head -n1)
        fi
    fi
    
    if [ -z "$binary" ]; then
        print_color "$RED" "Binary not found for $package"
        cd - > /dev/null || exit
        rm -rf "$temp_dir"
        return 1
    fi
    
    print_color "$GREEN" "Found binary: $binary"
    
    # Create install directory
    mkdir -p "$INSTALL_DIR"
    
    # Install binary
    if ! cp "$binary" "$INSTALL_DIR/$package"; then
        print_color "$RED" "Failed to install binary to $INSTALL_DIR"
        cd - > /dev/null || exit
        rm -rf "$temp_dir"
        return 1
    fi
    
    chmod +x "$INSTALL_DIR/$package"
    
    # Install completions if available
    if [ -n "$completions" ]; then
        print_color "$GREEN" "Installing completions..."
        while IFS= read -r comp_file; do
            [ -z "$comp_file" ] && continue
            
            local comp_name=$(basename "$comp_file")
            case "$comp_file" in
                *bash*)
                    mkdir -p "$HOME/.local/share/bash-completion/completions"
                    cp "$comp_file" "$HOME/.local/share/bash-completion/completions/$package"
                    ;;
                *zsh*)
                    mkdir -p "$HOME/.local/share/zsh/site-functions"
                    cp "$comp_file" "$HOME/.local/share/zsh/site-functions/_$package"
                    ;;
                *.1|*.1.gz)
                    mkdir -p "$HOME/.local/share/man/man1"
                    cp "$comp_file" "$HOME/.local/share/man/man1/"
                    ;;
            esac
        done <<< "$completions"
    fi
    
    # Add to database
    add_to_db "$package" "$github_version" "$INSTALL_DIR/$package"
    
    print_color "$GREEN" "Successfully installed $package v$github_version"
    
    # Clean up
    cd - > /dev/null || exit
    rm -rf "$temp_dir"
    return 0
}

# Function to load repositories
load_repos() {
    if [ ! -f "$repos_file" ]; then
        print_color "$RED" "Repository file $repos_file not found"
        return 1
    fi
    
    # Read repositories into array, skipping comments and empty lines
    REPOS=()
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        
        REPOS+=("$line")
    done < "$repos_file"
    
    if [ ${#REPOS[@]} -eq 0 ]; then
        print_color "$RED" "No repositories found in $repos_file"
        return 1
    fi
    
    return 0
}

# Interactive mode function
interactive_mode() {
    # Check script dependencies
    check_script_dependencies
    
    # Load repositories
    if ! load_repos; then
        print_color "$RED" "Failed to load repositories"
        return 1
    fi
    
    print_color "$GREEN" "Available packages:"
    printf '%s\n' "${REPOS[@]}"
    echo
    
    # Initialize package info array
    declare -A PACKAGE_INFO
    declare -A ALL_DEPENDENCIES
    
    # Print table header
    print_color "$BOLD" "Checking versions..."
    printf "${BOLD}%-15s %-12s %-12s %-15s %-40s${NC}\n" \
        "Binary" "Github" "APT" "Dependencies" "Asset"
    echo "------------------------------------------------------------------------------------------------"
    
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
        
        # Find suitable asset
        local asset_name=""
        local asset_url=""
        while IFS= read -r asset; do
            local name=$(echo "$asset" | jq -r '.name')
            local url=$(echo "$asset" | jq -r '.browser_download_url')
            
            # Skip invalid assets
            [ "$name" = "null" ] && continue
            [ "$url" = "null" ] && continue
            
            # Check if asset matches our architecture
            if [[ "$name" =~ linux.*(x86_64|amd64) ]] && [[ "$name" =~ .*$package.* ]]; then
                asset_name="$name"
                asset_url="$url"
                break
            fi
        done < <(echo "$release" | jq -c '.assets[]')
        
        if [ -z "$asset_url" ]; then
            # Try tarball URL as fallback
            asset_url=$(echo "$release" | jq -r '.tarball_url')
            if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
                return 1
            fi
        fi
        
        # Format display strings
        local apt_display_ver="${apt_version:-not found}"
        local gh_display_ver="${github_version#v}"
        local version_info
        if [ "$apt_version" != "not found" ] && [ "$status" = "GitHub" ]; then
            version_info="$gh_display_ver*"
        else
            version_info="$gh_display_ver"
        fi
        
        # Format asset name for display
        local display_asset
        if [ ${#asset_name} -gt 35 ]; then
            display_asset="${asset_name:0:32}..."
        else
            display_asset="$asset_name"
        fi
        
        # Display package information
        printf "%-14s %-12s %-12s %-15s %-40s\n" \
            "$package" \
            "$version_info" \
            "$apt_display_ver" \
            "${binary_info["dependencies"]}" \
            "$display_asset"
        
        # Store information for installation
        PACKAGE_INFO["$package"]="$apt_version|$github_version|$status|$asset_url|$binary_path|${binary_info["dependencies"]}|${binary_info["missing_deps"]}|${binary_info["completions"]}"
    }
    
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
                    for package in "${!PACKAGE_INFO[@]}"; do
                        IFS='|' read -r apt_ver gh_ver status asset path deps missing_deps completions <<< "${PACKAGE_INFO[$package]}"
                        if [[ "$status" == "GitHub" ]]; then
                            install_github_version "$package"
                        elif [[ "$status" == "APT" ]]; then
                            install_apt_version "$package"
                        fi
                    done
                    ;;
                2) # Install all GitHub versions
                    for package in "${!PACKAGE_INFO[@]}"; do
                        install_github_version "$package"
                    done
                    ;;
                3) # Install all APT versions
                    for package in "${!PACKAGE_INFO[@]}"; do
                        IFS='|' read -r apt_ver gh_ver status asset path deps missing_deps completions <<< "${PACKAGE_INFO[$package]}"
                        if [[ "$apt_ver" != "not found" ]]; then
                            install_apt_version "$package"
                        fi
                    done
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
    local ver1=$1
    local ver2=$2
    
    # Remove 'v' prefix if present
    ver1=${ver1#v}
    ver2=${ver2#v}
    
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
        
        # Remove any non-numeric characters for comparison
        v1=$(echo "$v1" | tr -dc '0-9')
        v2=$(echo "$v2" | tr -dc '0-9')
        
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

# Function to find suitable asset
find_suitable_asset() {
    local release_info=$1
    local package=$2
    local arch=$3
    local asset_url=""
    
    # First try to find an exact match for the architecture
    while IFS= read -r asset; do
        local name=$(echo "$asset" | jq -r '.name')
        local url=$(echo "$asset" | jq -r '.browser_download_url')
        
        # Skip invalid assets
        [ "$name" = "null" ] && continue
        [ "$url" = "null" ] && continue
        
        # Check if asset matches our architecture
        if [[ "$name" =~ linux.*(x86_64|amd64) ]] && [[ "$name" =~ .*$package.* ]]; then
            asset_url="$url"
            break
        fi
    done < <(echo "$release_info" | jq -c '.assets[]')
    
    # If no exact match found, try tarball URL
    if [ -z "$asset_url" ]; then
        asset_url=$(echo "$release_info" | jq -r '.tarball_url')
        if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
            return 1
        fi
    fi
    
    echo "$asset_url"
    return 0
}

# Function to check a single package for updates
check_single_package() {
    local package=$1
    local check_all_sources=$2
    local current_version
    local latest_version
    local status="Up to date"
    local update_available=0
    
    # Get current version
    local info=$(get_package_info "$package")
    if [ -z "$info" ] || [ "$info" = "null" ]; then
        return 0
    fi
    
    current_version=$(echo "$info" | jq -r '.version')
    if [ -z "$current_version" ] || [ "$current_version" = "null" ]; then
        return 0
    fi
    
    # Remove 'v' prefix for version comparison
    current_version=${current_version#v}
    
    # Check GitHub version if package is in repos.txt or check_all_sources is true
    if [ "$check_all_sources" = "true" ] || grep -q "$package" "$repos_file" 2>/dev/null; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ .*"$package".* ]]; then
                local release_info=$(get_github_release "$line" 2>/dev/null)
                if [ $? -eq 0 ]; then
                    latest_version=$(echo "$release_info" | jq -r '.tag_name')
                    if [ -n "$latest_version" ] && [ "$latest_version" != "null" ]; then
                        # Remove 'v' prefix for version comparison
                        latest_version=${latest_version#v}
                        if version_gt "$latest_version" "$current_version"; then
                            status="v$latest_version available (GH)"
                            update_available=1
                        fi
                    fi
                fi
                break
            fi
        done < "$repos_file"
    fi
    
    # Format version with 'v' prefix for display
    printf "%-14s %-14s %s\n" \
        "$package" \
        "v$current_version" \
        "$status"
    
    return $update_available
}

# Function to list all installed packages
list_installed() {
    if [ ! -f "$DB_FILE" ]; then
        print_color "$RED" "No packages installed via ghr-installer"
        return 1
    fi
    
    # Check if database is empty or invalid
    if ! jq -e '.packages' "$DB_FILE" >/dev/null 2>&1; then
        print_color "$YELLOW" "No packages installed yet"
        return 0
    fi
    
    # Get count of packages
    local count=$(jq '.packages | length' "$DB_FILE")
    if [ "$count" -eq 0 ]; then
        print_color "$YELLOW" "No packages installed yet"
        return 0
    fi
    
    # Print header
    echo -e "\nInstalled packages:"
    print_color "$BOLD" "Package         Version         Migration"
    echo "--------------------------------------------"
    
    # Get all packages and their info
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        
        # Get package info
        local version=$(jq -r --arg pkg "$pkg" '.packages[$pkg].version' "$DB_FILE")
        [ "$version" = "null" ] && continue
        
        local migration=""
        # Check if APT version is available
        if command -v apt-cache >/dev/null 2>&1; then
            local apt_version=$(apt-cache policy "$pkg" 2>/dev/null | grep Candidate | cut -d' ' -f4)
            if [ -n "$apt_version" ] && [ "$apt_version" != "(none)" ]; then
                migration="APT v$apt_version available"
            fi
        fi
        
        # Format and print package info
        printf "%-14s %-14s %s\n" \
            "$pkg" \
            "$version" \
            "$migration"
    done < <(jq -r '.packages | keys[]' "$DB_FILE")
    
    echo
}

# Function to install available updates
install_updates() {
    local package
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        check_single_package "$pkg" "false"
        if [ $? -eq 1 ]; then
            install_github_version "$pkg"
        fi
    done < <(jq -r '.packages | keys[]' "$DB_FILE" 2>/dev/null)
}

# Function to check for updates and provide migration advice
check_updates() {
    local package=$1
    local check_all_sources=$2
    local current_version
    local latest_version
    local apt_version
    local updates_available=false
    declare -A package_updates
    
    if [ -z "$package" ]; then
        # Check all installed packages
        echo -e "\nChecking for updates:"
        print_color "$BOLD" "Package         Version         Status"
        echo "----------------------------------------"
        
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            check_single_package "$pkg" "$check_all_sources"
            if [ $? -eq 1 ]; then
                updates_available=true
            fi
        done < <(jq -r '.packages | keys[]' "$DB_FILE" 2>/dev/null)
        
        if [ "$updates_available" = true ]; then
            echo -e "\nUpdates available. Install? [y/N] "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                install_updates
            fi
        else
            echo -e "\nAll packages are up to date."
        fi
        return 0
    else
        # Single package update
        echo -e "\nChecking for updates:"
        print_color "$BOLD" "Package         Version         Status"
        echo "----------------------------------------"
        
        check_single_package "$package" "$check_all_sources"
        local update_available=$?
        
        if [ $update_available -eq 1 ]; then
            echo -e "\nUpdates available for $package. Install? [y/N] "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                install_github_version "$package"
            fi
        else
            echo -e "\nNo updates available."
        fi
    fi
}

# Print usage information
usage() {
    print_color "$BOLD" "Usage: $0 [OPTIONS]"
    print_color "$BOLD" "Options:"
    print_color "$BOLD" "  --update PACKAGE    Update specified package"
    print_color "$BOLD" "  --remove PACKAGE    Remove specified package"
    print_color "$BOLD" "  --check-updates     Check for updates"
    print_color "$BOLD" "  --list             List installed packages"
    print_color "$BOLD" "  --help             Show this help message"
    echo
    print_color "$BOLD" "Without options, runs in interactive mode"
}

# Main function
main() {
    # Initialize database
    init_db
    
    # Initialize environment
    check_script_dependencies
    
    # Parse command line arguments
    case "$1" in
        --update|-u)
            shift
            if [ "$1" = "--all-sources" ]; then
                check_updates "" "true"
            elif [ -n "$1" ]; then
                check_updates "$1" "false"
            else
                check_updates "" "false"
            fi
            exit 0
            ;;
        --remove|-r)
            if [ -z "$2" ]; then
                print_color "$RED" "Error: Package name required for removal"
                usage
                exit 1
            fi
            shift
            remove_package "$1"
            exit 0
            ;;
        --list|-l)
            list_installed
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            interactive_mode
            ;;
    esac
}

# Execute main function with all arguments
main "$@"

# Function to check package version
check_package_version() {
    local package=$1
    local repo=${package#*/}
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
    
    # Find suitable asset
    local asset=$(find_binary_asset "$release" "$package")
    if [ -z "$asset" ] || [ "$asset" = "null" ]; then
        # Try tarball URL as fallback
        local asset_url=$(echo "$release" | jq -r '.tarball_url')
        if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
            return 1
        fi
    else
        local asset_name=$(echo "$asset" | jq -r '.name')
        local asset_url=$(echo "$asset" | jq -r '.browser_download_url')
    fi
    
    # If we got the browser_download_url, use that directly
    if [ -n "$asset_url" ]; then
        # Process binary information
        local temp_dir=$(mktemp -d)
        cd "$temp_dir" || exit
        
        # Download and extract the asset
        print_color "$GREEN" "Downloading $asset_url..."
        if [ -n "$GITHUB_TOKEN" ]; then
            curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" "$asset_url" -o "$package.tar.gz" 2>/dev/null
        else
            curl -sL "$asset_url" -o "$package.tar.gz" 2>/dev/null
        fi
        
        tar xf "$package.tar.gz" 2>/dev/null || true
        
        # Find the binary
        binary_path=$(find . -type f -executable -name "$package" 2>/dev/null)
        
        if [ -z "$binary_path" ]; then
            # Try finding any executable
            binary_path=$(find . -type f -executable 2>/dev/null | head -n1)
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
            binary_info["completions"]=$(find . -type f \( -name "*completion*" -o -name "*man1*" -o -name "*.1" -o -name "*.1.gz" \) -print0 2>/dev/null | tr '\0' '\n')
        else
            print_color "$RED" "Could not find binary in extracted files for $package" >&2
            cd - > /dev/null || exit
            rm -rf "$temp_dir"
            return 1
        fi
        
        cd - > /dev/null || exit
        rm -rf "$temp_dir"
    else
        print_color "$RED" "Failed to get download URL for $package" >&2
        return 1
    fi
    
    # Format display strings
    local apt_display_ver="${apt_version:-not found}"
    local gh_display_ver="${github_version#v}"
    local version_info
    if [ "$apt_version" != "not found" ] && [ "$status" = "GitHub" ]; then
        version_info="$gh_display_ver*"
    else
        version_info="$gh_display_ver"
    fi
    
    # Format asset name for display
    local display_asset
    if [ ${#asset_name} -gt 35 ]; then
        display_asset="${asset_name:0:32}..."
    else
        display_asset="$asset_name"
    fi
    
    # Display package information
    printf "%-14s %-12s %-12s %-15s %-40s\n" \
        "$package" \
        "$version_info" \
        "$apt_display_ver" \
        "${binary_info["dependencies"]}" \
        "$display_asset"
    
    # Store information for installation
    PACKAGE_INFO["$package"]="$apt_version|$github_version|$status|$asset_url|$binary_path|${binary_info["dependencies"]}|${binary_info["missing_deps"]}|${binary_info["completions"]}"
}

# Function to check if version1 is greater than version2
version_gt() {
    local ver1=$1
    local ver2=$2
    local result=$(version_compare "$ver1" "$ver2")
    [ "$result" = "newer" ]
}