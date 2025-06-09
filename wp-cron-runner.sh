#!/bin/bash
#
# Centralized WordPress Cron Runner - Security Hardened
# Processes all WordPress sites from a registry file
# Usage: Run via system cron every 5 minutes

set -u  # Exit on undefined vars, but allow command failures

# --- Configuration ---
SITES_CONFIG="/etc/wordpress-sites.conf"
WP_CLI_BIN="/usr/local/bin/wp"
PHP_CLI_BIN="/bin/php8.2"
MAX_PARALLEL=5         # Max concurrent cron jobs (reduced from 10)
BATCH_DELAY=2          # Seconds between batches
JOB_START_DELAY=0.5    # Seconds between individual job starts
TIMEOUT=300            # 5 minutes timeout per site
CPU_THRESHOLD=80       # Pause if CPU usage exceeds this percentage
LOG_TAG="wp-cron"

# Security: Validate paths and prevent path traversal
readonly ALLOWED_PATHS=("/var/www" "/home")
readonly CONFIG_PERMISSIONS="600"
readonly SCRIPT_USER="root"

# --- Security validation functions ---
validate_config_security() {
    # Check config file ownership and permissions
    if [[ ! -f "$SITES_CONFIG" ]]; then
        log_message "ERROR: Sites config not found: $SITES_CONFIG"
        return 1
    fi
    
    local file_owner=$(stat -c '%U' "$SITES_CONFIG")
    local file_perms=$(stat -c '%a' "$SITES_CONFIG")
    
    if [[ "$file_owner" != "root" ]]; then
        log_message "ERROR: Config file must be owned by root (currently: $file_owner)"
        return 1
    fi
    
    if [[ "$file_perms" != "$CONFIG_PERMISSIONS" ]]; then
        log_message "WARNING: Config file permissions should be $CONFIG_PERMISSIONS (currently: $file_perms)"
        chmod "$CONFIG_PERMISSIONS" "$SITES_CONFIG"
    fi
    
    return 0
}

validate_site_path() {
    local site_path="$1"
    
    # Prevent path traversal
    if [[ "$site_path" =~ \.\. ]]; then
        log_message "SECURITY: Path traversal attempt blocked: $site_path"
        return 1
    fi
    
    # Ensure path is within allowed directories
    local path_allowed=false
    for allowed_path in "${ALLOWED_PATHS[@]}"; do
        if [[ "$site_path" == "$allowed_path"* ]]; then
            path_allowed=true
            break
        fi
    done
    
    if [[ "$path_allowed" != true ]]; then
        log_message "SECURITY: Path outside allowed directories blocked: $site_path"
        return 1
    fi
    
    # Resolve and validate real path
    local real_path
    if ! real_path=$(realpath "$site_path" 2>/dev/null); then
        log_message "SECURITY: Invalid path blocked: $site_path"
        return 1
    fi
    
    # Double-check resolved path is still allowed
    path_allowed=false
    for allowed_path in "${ALLOWED_PATHS[@]}"; do
        if [[ "$real_path" == "$allowed_path"* ]]; then
            path_allowed=true
            break
        fi
    done
    
    if [[ "$path_allowed" != true ]]; then
        log_message "SECURITY: Resolved path outside allowed directories blocked: $real_path"
        return 1
    fi
    
    return 0
}

validate_user() {
    local user_name="$1"
    
    # Prevent dangerous users
    case "$user_name" in
        root|bin|daemon|sys|sync|games|man|lp|mail|news|uucp|proxy|backup|list|irc|gnats|nobody|_*|systemd-*|messagebus|syslog)
            log_message "SECURITY: Blocked execution for system user: $user_name"
            return 1
            ;;
    esac
    
    # Validate user exists and has proper shell
    if ! id -u "$user_name" >/dev/null 2>&1; then
        log_message "SECURITY: User not found: $user_name"
        return 1
    fi
    
    local user_shell
    user_shell=$(getent passwd "$user_name" | cut -d: -f7)
    
    # Allow legitimate shells, block nologin/false
    case "$user_shell" in
        /bin/bash|/bin/sh|/bin/dash|/usr/bin/fish|/bin/zsh)
            return 0
            ;;
        /sbin/nologin|/bin/false|/usr/sbin/nologin)
            log_message "SECURITY: User has disabled shell: $user_name ($user_shell)"
            return 1
            ;;
        *)
            log_message "WARNING: User has unusual shell: $user_name ($user_shell)"
            return 0  # Allow but log
            ;;
    esac
}

# --- Logging function ---
log_message() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# --- System monitoring functions ---
get_cpu_usage() {
    # Get current CPU usage (1-minute average)
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    echo "${cpu_usage%.*}"  # Return as integer
}

get_load_average() {
    # Get 1-minute load average
    cut -d' ' -f1 < /proc/loadavg
}

should_throttle() {
    local current_cpu=$(get_cpu_usage)
    local load_avg=$(get_load_average)
    local cpu_cores=$(nproc)
    
    # Check if CPU usage is too high
    if [[ $current_cpu -gt $CPU_THRESHOLD ]]; then
        log_message "THROTTLE: CPU usage ${current_cpu}% exceeds threshold ${CPU_THRESHOLD}%"
        return 0
    fi
    
    # Check if load average is too high (more than 2x CPU cores)
    local threshold=$((cpu_cores * 2))
    if (( $(echo "$load_avg" | cut -d'.' -f1) > threshold )); then
        log_message "THROTTLE: Load average $load_avg exceeds safe threshold (${cpu_cores} cores)"
        return 0
    fi
    
    return 1
}

wait_for_slot() {
    # Wait until we have fewer than MAX_PARALLEL jobs running
    while (( $(jobs -r | wc -l) >= MAX_PARALLEL )); do
        sleep 1
        
        # Also check if we should throttle due to system load
        if should_throttle; then
            log_message "INFO: Throttling due to high system load"
            sleep 5
        fi
    done
}

# --- Process individual site with enhanced security ---
process_site() {
    local site_path="$1"
    local user_name="$2"
    local method="$3"
    
    local start_time=$(date +%s)
    
    # Security validations
    if ! validate_site_path "$site_path"; then
        return 1
    fi
    
    if ! validate_user "$user_name"; then
        return 1
    fi
    
    # Additional WordPress-specific security checks
    if [[ ! -f "$site_path/wp-config.php" ]]; then
        log_message "SECURITY: wp-config.php not found in $site_path"
        return 1
    fi
    
    # Ensure the user actually owns the WordPress directory
    local dir_owner
    dir_owner=$(stat -c '%U' "$site_path" 2>/dev/null)
    if [[ "$dir_owner" != "$user_name" ]]; then
        log_message "SECURITY: Directory owner mismatch - path: $site_path, expected: $user_name, actual: $dir_owner"
        return 1
    fi
    
    case "$method" in
        "wp-cli")
            # Use explicit paths and secure sudo options
            if sudo -u "$user_name" -H --preserve-env=PATH timeout "$TIMEOUT" "$PHP_CLI_BIN" "$WP_CLI_BIN" --path="$site_path" cron event run --all --skip-plugins --skip-themes >/dev/null 2>&1; then
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                log_message "SUCCESS: $site_path (${duration}s, wp-cli, user: $user_name)"
                return 0
            else
                log_message "FAILED: $site_path (wp-cli timeout/error, user: $user_name)"
                return 1
            fi
            ;;
        "php-direct")
            # Validate wp-cron.php exists and is readable
            if [[ ! -f "$site_path/wp-cron.php" ]]; then
                log_message "SECURITY: wp-cron.php not found in $site_path"
                return 1
            fi
            
            if sudo -u "$user_name" -H timeout "$TIMEOUT" "$PHP_CLI_BIN" "$site_path/wp-cron.php" >/dev/null 2>&1; then
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                log_message "SUCCESS: $site_path (${duration}s, php-direct, user: $user_name)"
                return 0
            else
                log_message "FAILED: $site_path (php-direct timeout/error, user: $user_name)"
                return 1
            fi
            ;;
        *)
            log_message "SECURITY: Unknown/invalid method '$method' for $site_path"
            return 1
            ;;
    esac
}

# --- Main execution ---
main() {
    local script_start=$(date +%s)
    
    # Security: Verify we're running as expected user
    if [[ "$(whoami)" != "$SCRIPT_USER" ]]; then
        log_message "ERROR: Script must run as $SCRIPT_USER (currently: $(whoami))"
        exit 1
    fi
    
    # Security: Validate config file
    if ! validate_config_security; then
        exit 1
    fi
    
    # Count total sites
    local total_sites=$(grep -v '^#' "$SITES_CONFIG" | grep -v '^$' | wc -l)
    
    if [[ $total_sites -eq 0 ]]; then
        log_message "INFO: No sites found in config"
        exit 0
    fi
    
    # Security: Reasonable limits
    if [[ $total_sites -gt 1000 ]]; then
        log_message "ERROR: Too many sites in config ($total_sites). Maximum: 1000"
        exit 1
    fi
    
    log_message "INFO: Starting secure cron run for $total_sites sites (max parallel: $MAX_PARALLEL, CPU threshold: ${CPU_THRESHOLD}%)"
    
    local processed=0
    local failed=0
    local security_blocked=0
    
    # Array to track job PIDs for better management
    declare -a job_pids=()
    
    # Process sites with improved concurrency control
    while IFS='|' read -r site_path user_name method; do
        # Skip comments and empty lines
        [[ "$site_path" =~ ^#.*$ ]] && continue
        [[ -z "$site_path" ]] && continue
        
        # Basic input validation
        if [[ -z "$user_name" || -z "$method" ]]; then
            log_message "WARNING: Invalid config line - missing fields: $site_path|$user_name|$method"
            ((failed++))
            continue
        fi
        
        # Wait for available slot and check system load
        wait_for_slot
        
        # Additional throttling check before starting new job
        if should_throttle; then
            log_message "INFO: Pausing due to high system load before starting $site_path"
            sleep 5
        fi
        
        # Launch background job with improved tracking
        {
            if process_site "$site_path" "$user_name" "$method"; then
                echo "SUCCESS:$site_path"
            else
                case $? in
                    1) echo "SECURITY:$site_path" ;;
                    *) echo "FAILED:$site_path" ;;
                esac
            fi
        } &
        
        local job_pid=$!
        job_pids+=($job_pid)
        
        # Small delay between job starts to prevent thundering herd
        if [[ $JOB_START_DELAY > 0 ]]; then
            sleep "$JOB_START_DELAY"
            fi
            
        # Clean up completed jobs periodically
        if (( ${#job_pids[@]} % 20 == 0 )); then
            local new_pids=()
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=($pid)
                fi
            done
            job_pids=("${new_pids[@]}")
        fi
        
    done < "$SITES_CONFIG"
    
    # Wait for all remaining jobs
    log_message "INFO: Waiting for remaining jobs to complete..."
    
    # Simple approach: wait for all background jobs
    wait
    
    # Get final statistics from recent log entries
    local recent_log_time=$(date -d "1 minute ago" '+%Y-%m-%d %H:%M:%S')
    local success_count=$(journalctl -t "$LOG_TAG" --since "$recent_log_time" | grep -c "SUCCESS:" || echo 0)
    local failed_count=$(journalctl -t "$LOG_TAG" --since "$recent_log_time" | grep -c "FAILED:" || echo 0)
    local security_count=$(journalctl -t "$LOG_TAG" --since "$recent_log_time" | grep -c "SECURITY:" || echo 0)
    
    local script_end=$(date +%s)
    local total_duration=$((script_end - script_start))
    
    log_message "INFO: Secure cron run completed in ${total_duration}s - Success: $success_count, Failed: $failed_count, Security Blocked: $security_count, Total Sites: $total_sites"
    
    # Alert if many security blocks
    if [[ $security_count -gt $((total_sites / 10)) ]]; then
        log_message "ALERT: High number of security blocks ($security_count). Possible attack or config issues."
    fi
}

# --- Signal handling ---
cleanup() {
    log_message "INFO: Received termination signal, cleaning up..."
    # Kill all child processes
    jobs -p | xargs -r kill 2>/dev/null
    exit 130
}

trap cleanup SIGTERM SIGINT

# --- Execute ---
main "$@" 