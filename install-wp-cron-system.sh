#!/bin/bash
#
# WordPress Cron System Installer
# Installs and configures the centralized WordPress cron runner
# Must be run as root

set -euo pipefail

# --- Configuration ---
SCRIPT_NAME="wp-cron-runner.sh"
INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/wordpress-sites.conf"
LOG_FILE="/var/log/wp-cron-install.log"
CRON_USER="root"
CRON_SCHEDULE="*/5 * * * *"  # Every 5 minutes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Logging function ---
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} $message" | tee -a "$LOG_FILE"
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

# --- Validation functions ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Usage: sudo $0"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    local required_commands=("wp" "php" "crontab" "systemctl")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                "wp")
                    missing_deps+=("WP-CLI (https://wp-cli.org/)")
                    ;;
                "php")
                    missing_deps+=("PHP CLI")
                    ;;
                *)
                    missing_deps+=("$cmd")
                    ;;
            esac
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing required dependencies:"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

# --- Installation functions ---
install_script() {
    print_status "Installing wp-cron-runner.sh to $INSTALL_DIR"
    
    if [[ ! -f "$SCRIPT_NAME" ]]; then
        print_error "wp-cron-runner.sh not found in current directory"
        exit 1
    fi
    
    # Copy script to install directory
    cp "$SCRIPT_NAME" "$INSTALL_DIR/"
    chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"
    chown root:root "$INSTALL_DIR/$SCRIPT_NAME"
    
    print_success "Script installed to $INSTALL_DIR/$SCRIPT_NAME"
}

create_config_file() {
    print_status "Creating WordPress sites configuration file"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        print_warning "Configuration file already exists at $CONFIG_FILE"
        
        # Backup existing config
        local backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        print_status "Backed up existing config to $backup_file"
    fi
    
    # Create configuration file with examples
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

# Example entries (uncomment and modify as needed):
# /var/www/html/wordpress|www-data|wp-cli
# /var/www/html/site1|www-data|wp-cli
# /home/username/public_html|username|php-direct
EOF
    
    # Set proper permissions
    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    
    print_success "Configuration file created at $CONFIG_FILE"
    print_status "Edit $CONFIG_FILE to add your WordPress sites"
}

setup_logging() {
    print_status "Setting up logging"
    
    # Create log directory if it doesn't exist
    local log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir"
    fi
    
    # Create log file with proper permissions
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    chown root:root "$LOG_FILE"
    
    # Setup logrotate for wp-cron logs
    cat > /etc/logrotate.d/wp-cron << EOF
/var/log/wp-cron*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF
    
    print_success "Logging configured"
}

install_cron_job() {
    print_status "Installing cron job"
    
    local cron_command="$INSTALL_DIR/$SCRIPT_NAME"
    local cron_entry="$CRON_SCHEDULE $cron_command >/dev/null 2>&1"
    
    # Check if cron job already exists
    if crontab -u "$CRON_USER" -l 2>/dev/null | grep -q "$SCRIPT_NAME"; then
        print_warning "Cron job already exists, removing old entry"
        crontab -u "$CRON_USER" -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab -u "$CRON_USER" -
    fi
    
    # Add new cron job
    (crontab -u "$CRON_USER" -l 2>/dev/null; echo "$cron_entry") | crontab -u "$CRON_USER" -
    
    print_success "Cron job installed: $cron_entry"
}

setup_systemd_timer() {
    print_status "Setting up systemd timer as alternative to cron"
    
    # Create systemd service file
    cat > /etc/systemd/system/wp-cron-runner.service << EOF
[Unit]
Description=WordPress Cron Runner
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/$SCRIPT_NAME
User=root
StandardOutput=journal
StandardError=journal
EOF
    
    # Create systemd timer file
    cat > /etc/systemd/system/wp-cron-runner.timer << EOF
[Unit]
Description=Run WordPress Cron Runner every 5 minutes
Requires=wp-cron-runner.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Reload systemd and enable timer
    systemctl daemon-reload
    systemctl enable wp-cron-runner.timer
    
    print_success "Systemd timer configured (alternative to cron)"
    print_status "To use systemd timer instead of cron:"
    echo "  - Start: systemctl start wp-cron-runner.timer"
    echo "  - Stop cron: remove cron job manually if needed"
}

create_management_script() {
    print_status "Creating management script"
    
    local mgmt_script="/usr/local/bin/wp-cron-manage"
    
    cat > "$mgmt_script" << 'EOF'
#!/bin/bash
#
# WordPress Cron Management Script
# Provides easy management of the WordPress cron system

CONFIG_FILE="/etc/wordpress-sites.conf"
RUNNER_SCRIPT="/usr/local/bin/wp-cron-runner.sh"

show_help() {
    echo "WordPress Cron Management Script"
    echo ""
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  status      - Show current status and recent logs"
    echo "  test        - Test run (dry-run mode)"
    echo "  run         - Run cron manually"
    echo "  config      - Edit configuration file"
    echo "  logs        - Show recent logs"
    echo "  sites       - List configured sites"
    echo "  validate    - Validate configuration"
    echo "  help        - Show this help"
}

show_status() {
    echo "=== WordPress Cron System Status ==="
    echo ""
    
    # Check if files exist
    echo "Configuration file: $CONFIG_FILE"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  Status: ✓ Exists"
        echo "  Sites configured: $(grep -v '^#' "$CONFIG_FILE" | grep -v '^$' | wc -l)"
    else
        echo "  Status: ✗ Missing"
    fi
    
    echo ""
    echo "Runner script: $RUNNER_SCRIPT"
    if [[ -f "$RUNNER_SCRIPT" ]]; then
        echo "  Status: ✓ Exists"
    else
        echo "  Status: ✗ Missing"
    fi
    
    echo ""
    echo "Cron job:"
    if crontab -l 2>/dev/null | grep -q "wp-cron-runner.sh"; then
        echo "  Status: ✓ Installed"
        crontab -l | grep "wp-cron-runner.sh"
    else
        echo "  Status: ✗ Not found"
    fi
    
    echo ""
    echo "Recent logs (last 10 entries):"
    journalctl -t wp-cron --no-pager -n 10 || echo "No recent logs found"
}

list_sites() {
    echo "=== Configured WordPress Sites ==="
    echo ""
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    echo "Format: Path | User | Method"
    echo "----------------------------------------"
    
    while IFS='|' read -r path user method; do
        [[ "$path" =~ ^#.*$ ]] && continue
        [[ -z "$path" ]] && continue
        
        echo "$path | $user | $method"
    done < "$CONFIG_FILE"
}

validate_config() {
    echo "=== Configuration Validation ==="
    echo ""
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "❌ Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    local issues=0
    local line_num=0
    
    while IFS='|' read -r path user method; do
        ((line_num++))
        
        [[ "$path" =~ ^#.*$ ]] && continue
        [[ -z "$path" ]] && continue
        
        # Check path exists
        if [[ ! -d "$path" ]]; then
            echo "❌ Line $line_num: Directory does not exist: $path"
            ((issues++))
        fi
        
        # Check wp-config.php exists
        if [[ ! -f "$path/wp-config.php" ]]; then
            echo "❌ Line $line_num: wp-config.php not found in: $path"
            ((issues++))
        fi
        
        # Check user exists
        if ! id "$user" >/dev/null 2>&1; then
            echo "❌ Line $line_num: User does not exist: $user"
            ((issues++))
        fi
        
        # Check method is valid
        if [[ "$method" != "wp-cli" && "$method" != "php-direct" ]]; then
            echo "❌ Line $line_num: Invalid method '$method' (should be wp-cli or php-direct)"
            ((issues++))
        fi
        
        echo "✓ Line $line_num: $path | $user | $method"
    done < "$CONFIG_FILE"
    
    echo ""
    if [[ $issues -eq 0 ]]; then
        echo "✅ Configuration validation passed"
    else
        echo "❌ Found $issues issues in configuration"
        return 1
    fi
}

case "${1:-help}" in
    "status")
        show_status
        ;;
    "test")
        echo "Running test (this would be a dry-run mode)"
        echo "Not implemented yet - run manually: $RUNNER_SCRIPT"
        ;;
    "run")
        echo "Running WordPress cron manually..."
        "$RUNNER_SCRIPT"
        ;;
    "config")
        if command -v nano >/dev/null 2>&1; then
            nano "$CONFIG_FILE"
        elif command -v vi >/dev/null 2>&1; then
            vi "$CONFIG_FILE"
        else
            echo "No editor found. Edit manually: $CONFIG_FILE"
        fi
        ;;
    "logs")
        journalctl -t wp-cron --no-pager -n 50
        ;;
    "sites")
        list_sites
        ;;
    "validate")
        validate_config
        ;;
    "help"|*)
        show_help
        ;;
esac
EOF
    
    chmod 755 "$mgmt_script"
    chown root:root "$mgmt_script"
    
    print_success "Management script created at $mgmt_script"
}

# --- Main installation process ---
main() {
    print_status "Starting WordPress Cron System installation"
    print_status "Log file: $LOG_FILE"
    
    # Pre-installation checks
    check_root
    check_dependencies
    
    # Installation steps
    install_script
    create_config_file
    setup_logging
    install_cron_job
    setup_systemd_timer
    create_management_script
    
    print_success "Installation completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Edit the configuration file: $CONFIG_FILE"
    echo "2. Add your WordPress sites to the configuration"
    echo "3. Validate configuration: wp-cron-manage validate"
    echo "4. Test manually: wp-cron-manage run"
    echo "5. Check status: wp-cron-manage status"
    echo ""
    echo "The cron job will run automatically every 5 minutes."
    echo "Use 'wp-cron-manage help' for management options."
}

# --- Execute main function ---
main "$@" 