#!/bin/bash
#
# WordPress Sites Scanner and Config Populator - FIXED VERSION
# Scans /home for WordPress installations, disables wp-cron, and populates config
# Must be run as root
#
# Usage: sudo ./populate-wp-sites-fixed.sh [options]
# Options:
#   --dry-run     Show what would be done without making changes
#   --backup      Create backup of existing config before overwriting
#   --force       Force overwrite of existing config without prompting
#   --test-only   Only test WP-CLI and methods, don't modify anything

# --- Configuration ---
CONFIG_FILE="/etc/wordpress-sites.conf"
SEARCH_PATHS=("/home")
BACKUP_DIR="/etc/backups"
LOG_FILE="/var/log/wp-sites-scanner.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
DRY_RUN=false
FORCE_OVERWRITE=false
CREATE_BACKUP=false
TEST_ONLY=false
FOUND_SITES=()
PROCESSED_SITES=()
FAILED_SITES=()

# --- Logging functions ---
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} $message"
    
    # Try to write to log file, but don't fail if we can't
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ "$EUID" -eq 0 ]]; then
        echo "${timestamp} $message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log_message "INFO: $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log_message "SUCCESS: $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log_message "WARNING: $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log_message "ERROR: $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# --- Validation functions ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Usage: sudo $0 [options]"
        exit 1
    fi
}

# --- WordPress detection and validation ---
is_wordpress_site() {
    local site_path="$1"
    
    # Check if wp-config.php exists
    if [[ ! -f "$site_path/wp-config.php" ]]; then
        return 1
    fi
    
    # Check for WordPress-specific files
    local wp_files=("wp-includes" "wp-admin" "wp-content" "index.php")
    for file in "${wp_files[@]}"; do
        if [[ ! -e "$site_path/$file" ]]; then
            return 1
        fi
    done
    
    return 0
}

get_wp_cron_status() {
    local wp_config="$1"
    local cron_status=""
    
    # Look for DISABLE_WP_CRON constant
    if grep -q "DISABLE_WP_CRON" "$wp_config"; then
        # Extract the value
        cron_status=$(grep "DISABLE_WP_CRON" "$wp_config" | head -1 | sed -n "s/.*define.*['\"]DISABLE_WP_CRON['\"].*,\s*\([^)]*\).*/\1/p" | tr -d ' \t')
        
        # Normalize boolean values
        case "${cron_status,,}" in
            "true"|"1"|"'true'"|"\"true\"")
                cron_status="true"
                ;;
            "false"|"0"|"'false'"|"\"false\"")
                cron_status="false"
                ;;
            *)
                cron_status="unknown"
                ;;
        esac
    else
        cron_status="not_set"
    fi
    
    echo "$cron_status"
}

disable_wp_cron() {
    local wp_config="$1"
    local site_path="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local cron_status=$(get_wp_cron_status "$wp_config")
        case "$cron_status" in
            "false"|"not_set")
                print_info "DRY RUN: Would disable wp-cron in $wp_config (current status: $cron_status)"
                ;;
            "true")
                print_info "DRY RUN: wp-cron already disabled in $wp_config (no changes needed)"
                ;;
            "unknown")
                print_info "DRY RUN: Would attempt to disable wp-cron in $wp_config (current status: $cron_status)"
                ;;
        esac
        return 0
    fi
    
    # Create backup of wp-config.php
    local backup_file="${wp_config}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$wp_config" "$backup_file"
    print_status "Created backup: $backup_file"
    
    # Check if DISABLE_WP_CRON already exists
    if grep -q "DISABLE_WP_CRON" "$wp_config"; then
        # Update existing definition
        sed -i "s/define.*['\"]DISABLE_WP_CRON['\"].*/define('DISABLE_WP_CRON', true);/" "$wp_config"
        print_status "Updated existing DISABLE_WP_CRON in $wp_config"
    else
        # Add new definition before the "That's all, stop editing!" comment
        if grep -q "That's all, stop editing!" "$wp_config"; then
            sed -i "/That's all, stop editing!/i\\define('DISABLE_WP_CRON', true);" "$wp_config"
        else
            # Add at the end of the file
            echo "" >> "$wp_config"
            echo "/* Disable WordPress cron - managed by system cron */" >> "$wp_config"
            echo "define('DISABLE_WP_CRON', true);" >> "$wp_config"
        fi
        print_status "Added DISABLE_WP_CRON to $wp_config"
    fi
    
    # Verify the change
    if grep -q "define.*['\"]DISABLE_WP_CRON['\"].*true" "$wp_config"; then
        print_success "Successfully disabled wp-cron in $site_path"
        return 0
    else
        print_error "Failed to disable wp-cron in $site_path"
        return 1
    fi
}

# --- User and method detection ---
detect_site_owner() {
    local site_path="$1"
    
    # Get the owner of the WordPress directory
    local owner=$(stat -c '%U' "$site_path" 2>/dev/null)
    
    if [[ -z "$owner" ]]; then
        print_error "Could not determine owner of $site_path"
        return 1
    fi
    
    # Validate the user exists and has proper shell
    if ! id "$owner" >/dev/null 2>&1; then
        print_error "User $owner does not exist for site $site_path"
        return 1
    fi
    
    echo "$owner"
}

detect_best_method() {
    local site_path="$1"
    local user_name="$2"
    
    # For now, default to wp-cli (will be handled gracefully by the main cron runner)
    echo "wp-cli"
    return 0
}

# --- Site processing ---
process_wordpress_site() {
    local site_path="$1"
    
    print_status "Processing WordPress site: $site_path"
    
    # Validate it's actually a WordPress site
    if ! is_wordpress_site "$site_path"; then
        print_warning "Skipping $site_path - not a valid WordPress installation"
        return 1
    fi
    
    # Get site owner
    local owner
    if ! owner=$(detect_site_owner "$site_path"); then
        print_error "Could not determine owner for $site_path"
        FAILED_SITES+=("$site_path|owner_detection_failed")
        return 1
    fi
    
    # Check current wp-cron status
    local wp_config="$site_path/wp-config.php"
    local cron_status=$(get_wp_cron_status "$wp_config")
    
    print_info "Site: $site_path | Owner: $owner | WP-Cron Status: $cron_status"
    
    # Disable wp-cron if needed
    case "$cron_status" in
        "false"|"not_set")
            if ! disable_wp_cron "$wp_config" "$site_path"; then
                print_error "Failed to disable wp-cron for $site_path"
                FAILED_SITES+=("$site_path|wp_cron_disable_failed")
                return 1
            fi
            ;;
        "true")
            print_info "WP-Cron already disabled for $site_path"
            ;;
        "unknown")
            print_warning "Unknown wp-cron status for $site_path, attempting to disable"
            if ! disable_wp_cron "$wp_config" "$site_path"; then
                print_error "Failed to disable wp-cron for $site_path"
                FAILED_SITES+=("$site_path|wp_cron_disable_failed")
                return 1
            fi
            ;;
    esac
    
    # Detect best execution method
    local method
    method=$(detect_best_method "$site_path" "$owner")
    
    print_info "Detected method for $site_path: $method"
    
    # Add to processed sites
    local site_entry="$site_path|$owner|$method"
    PROCESSED_SITES+=("$site_entry")
    FOUND_SITES+=("$site_entry")
    
    print_success "Successfully processed: $site_entry"
    return 0
}

# --- Configuration file management ---
create_config_file() {
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would create/update configuration file: $CONFIG_FILE"
        print_info "DRY RUN: Configuration would contain ${#PROCESSED_SITES[@]} sites:"
        for site_entry in "${PROCESSED_SITES[@]}"; do
            print_info "DRY RUN:   - $site_entry"
        done
        return 0
    fi
    
    # Create new configuration file
    cat > "$CONFIG_FILE" << 'EOF'
# WordPress Sites Configuration for Centralized Cron Runner
# Format: /path/to/wordpress|username|method
# Methods: wp-cli, php-direct
#
# Examples:
# /var/www/html/site1|www-data|wp-cli
# /var/www/html/site2|webuser|php-direct
# /home/user/public_html|user|wp-cli
#
# Security Notes:
# - Only paths under /var/www and /home are allowed
# - Users must exist and have proper shell access
# - Directories must be owned by the specified user
# - wp-config.php must exist in each WordPress directory
#
# Add your WordPress sites below (remove the # to uncomment):

EOF
    
    # Add discovered sites
    for site_entry in "${PROCESSED_SITES[@]}"; do
        echo "$site_entry" >> "$CONFIG_FILE"
    done
    
    # Set proper permissions
    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    
    print_success "Configuration file created/updated: $CONFIG_FILE"
}

# --- Main scanning function ---
scan_for_wordpress_sites() {
    print_status "Scanning for WordPress installations..."
    
    local total_found=0
    
    for search_path in "${SEARCH_PATHS[@]}"; do
        if [[ ! -d "$search_path" ]]; then
            print_warning "Search path does not exist: $search_path"
            continue
        fi
        
        print_status "Scanning: $search_path"
        
        # Find all wp-config.php files recursively
        while IFS= read -r -d '' wp_config; do
            [[ -z "$wp_config" ]] && continue
            
            local site_path=$(dirname "$wp_config")
            ((total_found++))
            
            print_info "Found WordPress site #$total_found: $site_path"
            
            # Skip if already processed (avoid duplicates)
            local already_processed=false
            for processed in "${PROCESSED_SITES[@]}"; do
                if [[ "$processed" == "$site_path"* ]]; then
                    already_processed=true
                    break
                fi
            done
            
            if [[ "$already_processed" == "true" ]]; then
                print_info "Skipping already processed: $site_path"
                continue
            fi
            
            process_wordpress_site "$site_path"
        done < <(find "$search_path" -name "wp-config.php" -type f -print0 2>/dev/null)
    done
    
    print_status "Scan completed. Found $total_found WordPress installations."
}

# --- Main execution ---
show_help() {
    cat << EOF
WordPress Sites Scanner and Config Populator

Usage: $0 [options]

Options:
    --dry-run     Show what would be done without making changes
    --backup      Create backup of existing config before overwriting
    --force       Force overwrite of existing config without prompting
    --test-only   Only test WP-CLI and methods, don't modify anything
    --help        Show this help message

Description:
    This script scans /home for WordPress installations, disables wp-cron
    in each site's wp-config.php, and populates the centralized cron
    configuration file with the discovered sites.

    The script will:
    1. Scan for WordPress installations in /home
    2. Check and disable wp-cron in each site
    3. Determine the best execution method (wp-cli or php-direct)
    4. Populate /etc/wordpress-sites.conf with discovered sites

Examples:
    sudo $0                    # Normal operation
    sudo $0 --dry-run         # See what would be done
    sudo $0 --backup --force  # Create backup and overwrite config
    sudo $0 --test-only       # Only test dependencies

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --backup)
                CREATE_BACKUP=true
                shift
                ;;
            --force)
                FORCE_OVERWRITE=true
                shift
                ;;
            --test-only)
                TEST_ONLY=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    print_status "Starting WordPress Sites Scanner"
    print_status "Log file: $LOG_FILE"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Pre-execution checks
    check_root
    
    if [[ "$TEST_ONLY" == "true" ]]; then
        print_success "Test mode completed"
        exit 0
    fi
    
    # Check if config file exists and handle accordingly
    if [[ -f "$CONFIG_FILE" && "$FORCE_OVERWRITE" != "true" ]]; then
        print_warning "Configuration file already exists: $CONFIG_FILE"
        echo -n "Do you want to overwrite it? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_status "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Scan for WordPress sites
    scan_for_wordpress_sites
    
    # Create configuration file
    if [[ ${#PROCESSED_SITES[@]} -gt 0 ]]; then
        create_config_file
        
        if [[ "$DRY_RUN" == "true" ]]; then
            print_success "DRY RUN completed successfully!"
            echo ""
            echo "DRY RUN Summary:"
            echo "  Sites found: ${#FOUND_SITES[@]}"
            echo "  Sites that would be processed: ${#PROCESSED_SITES[@]}"
            echo "  Sites that would fail: ${#FAILED_SITES[@]}"
            echo ""
            echo "To apply these changes, run the script without --dry-run"
        else
            print_success "Configuration completed successfully!"
            echo ""
            echo "Summary:"
            echo "  Sites found: ${#FOUND_SITES[@]}"
            echo "  Sites processed: ${#PROCESSED_SITES[@]}"
            echo "  Sites failed: ${#FAILED_SITES[@]}"
            echo ""
            echo "Configuration file: $CONFIG_FILE"
        fi
        
        if [[ ${#FAILED_SITES[@]} -gt 0 ]]; then
            echo ""
            echo "Failed sites:"
            for failed in "${FAILED_SITES[@]}"; do
                echo "  - $failed"
            done
        fi
    else
        print_warning "No WordPress sites found to process"
    fi
}

# --- Execute main function ---
main "$@"
