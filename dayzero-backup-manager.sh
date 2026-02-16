#!/bin/bash
set -euo pipefail

VERSION="1.0.0"
CONFIG_DIR="/etc/dayzero-backup"
CONFIGS_DIR="$CONFIG_DIR/configs"
ENV_DIR="$CONFIG_DIR/env"
SCRIPTS_DIR="$CONFIG_DIR/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root (use sudo)${NC}"
        exit 1
    fi
}

draw_line() {
    local char="${1:-─}"
    local width="${2:-50}"
    local color="${3:-$GRAY}"
    local line=""
    for ((i=0; i<width; i++)); do line+="$char"; done
    echo -e "${color}${line}${NC}"
}

print_header() {
    clear
    echo ""
    echo -e "${CYAN}  ┌──────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}  │${NC}${BOLD}${WHITE}     ____             _____                   ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}  │${NC}${BOLD}${WHITE}    / __ \____ ___  _/__  /  ___  _________   ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}  │${NC}${BOLD}${WHITE}   / / / / __ \`/ / / / / /  / _ \/ ___/ __ \  ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}  │${NC}${BOLD}${WHITE}  / /_/ / /_/ / /_/ / / /__/  __/ /  / /_/ /  ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}  │${NC}${BOLD}${WHITE} /_____/\__,_/\__, / /____/\___/_/   \____/   ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}  │${NC}${BOLD}${WHITE}            /____/                            ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}  │${NC}${DIM}${CYAN}             Backup Manager v${VERSION}            ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}  └──────────────────────────────────────────────┘${NC}"
    echo ""
}

print_section() {
    local title="$1"
    local title_len=${#title}
    local pad=$((45 - title_len))
    local right_pad=""
    for ((i=0; i<pad; i++)); do right_pad+=" "; done
    echo ""
    echo -e "${BLUE}  ┌──────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}  │${NC} ${BOLD}${WHITE}${title}${NC}${right_pad}${BLUE}│${NC}"
    echo -e "${BLUE}  └──────────────────────────────────────────────┘${NC}"
    echo ""
}

success() {
    echo -e "  ${GREEN}│ ✓ ${NC}$1"
}

error() {
    echo -e "  ${RED}│ ✗ ${NC}$1"
}

warning() {
    echo -e "  ${YELLOW}│ ⚠ ${NC}$1"
}

info() {
    echo -e "  ${CYAN}│ ℹ ${NC}$1"
}

init_directories() {
    mkdir -p "$CONFIGS_DIR" "$ENV_DIR" "$SCRIPTS_DIR"
    chmod 700 "$ENV_DIR"
}

check_and_install_command() {
    if ! command -v dayzerobackup &> /dev/null; then
        local script_path="$(readlink -f "$0")"
        
        echo ""
        info "First-time setup detected"
        echo ""
        echo -e "  ${CYAN}│${NC} Would you like to install ${WHITE}dayzerobackup${NC} command?"
        echo -e "  ${CYAN}│${NC} ${DIM}This allows you to run: ${WHITE}dayzerobackup${NC} ${DIM}from anywhere${NC}"
        echo ""
        read -r -p "Install system command? (y/n): " install_cmd
        
        if [[ "$install_cmd" =~ ^[Yy]$ ]]; then
            if [ -w "/usr/local/bin" ] || sudo -n true 2>/dev/null; then
                cp "$script_path" /usr/local/bin/dayzerobackup 2>/dev/null || \
                    sudo cp "$script_path" /usr/local/bin/dayzerobackup
                chmod +x /usr/local/bin/dayzerobackup 2>/dev/null || \
                    sudo chmod +x /usr/local/bin/dayzerobackup
                
                success "Installed! You can now run: ${WHITE}dayzerobackup${NC}"
                echo ""
                info "Press Enter to continue to the main menu..."
                read -r
            else
                error "Unable to install (permission denied)"
                warning "You can manually copy the script to /usr/local/bin/"
                read -r -p "Press Enter to continue..."
            fi
        fi
    fi
}

get_current_crontab() {
    crontab -l 2>/dev/null || true
}

check_restic() {
    if ! command -v restic &> /dev/null; then
        warning "Restic is not installed"
        read -r -p "Would you like to install restic now? (y/n): " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            install_restic
        else
            error "Restic is required for backups. Exiting."
            exit 1
        fi
    else
        success "Restic is installed: $(restic version | head -n1)"
    fi
}

install_restic() {
    print_section "Installing Restic"

    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install restic -y
    elif command -v yum &> /dev/null; then
        yum install epel-release -y && yum install restic -y
    else
        warning "Package manager not recognized. Installing manually..."
        RESTIC_VERSION="0.16.4"
        wget "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"
        bunzip2 "restic_${RESTIC_VERSION}_linux_amd64.bz2"
        chmod +x "restic_${RESTIC_VERSION}_linux_amd64"
        mv "restic_${RESTIC_VERSION}_linux_amd64" /usr/local/bin/restic
    fi

    if command -v restic &> /dev/null; then
        success "Restic installed successfully"
    else
        error "Failed to install restic"
        exit 1
    fi
}

prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [ -n "$default" ]; then
        echo -ne "  ${CYAN}│${NC} ${WHITE}${prompt}${NC} ${DIM}[${default}]${NC}: "
        read -r input
        printf -v "$var_name" '%s' "${input:-$default}"
    else
        echo -ne "  ${CYAN}│${NC} ${WHITE}${prompt}${NC}: "
        read -r input
        printf -v "$var_name" '%s' "$input"
    fi
}

prompt_password() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"

    if [ -n "$default" ]; then
        echo -ne "  ${CYAN}│${NC} ${WHITE}${prompt}${NC} ${DIM}[hidden, enter to keep]${NC}: "
        read -r -s input
        echo ""
        if [ -z "$input" ]; then
            printf -v "$var_name" '%s' "$default"
        else
            printf -v "$var_name" '%s' "$input"
        fi
    else
        echo -ne "  ${CYAN}│${NC} ${WHITE}${prompt}${NC}: "
        read -r -s input
        echo ""
        printf -v "$var_name" '%s' "$input"
    fi
}

list_backup_jobs() {
    print_header
    print_section "Configured Backup Jobs"

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR" 2>/dev/null)" ]; then
        warning "No backup jobs configured yet"
        return
    fi

    echo -e "  ${CYAN}┌──────────────────────┬─────────────────────────┬────────────┬────────────┬─────────────────┐${NC}"
    printf "  ${CYAN}│${NC} ${BOLD}%-20s${NC} ${CYAN}│${NC} ${BOLD}%-23s${NC} ${CYAN}│${NC} ${BOLD}%-10s${NC} ${CYAN}│${NC} ${BOLD}%-10s${NC} ${CYAN}│${NC} ${BOLD}%-15s${NC} ${CYAN}│${NC}\n" "Name" "Path" "Tag" "Retention" "Cron"
    echo -e "  ${CYAN}├──────────────────────┼─────────────────────────┼────────────┼────────────┼─────────────────┤${NC}"

    for config_file in "$CONFIGS_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            source "$config_file"
            printf "  ${CYAN}│${NC} %-20s ${CYAN}│${NC} %-23s ${CYAN}│${NC} %-10s ${CYAN}│${NC} %-10s ${CYAN}│${NC} %-15s ${CYAN}│${NC}\n" \
                "$BACKUP_NAME" \
                "${FOLDER_PATH:0:23}" \
                "$BACKUP_TAG" \
                "$RETENTION_METHOD" \
                "${CRON_SCHEDULE:-Not set}"
        fi
    done

    echo -e "  ${CYAN}└──────────────────────┴─────────────────────────┴────────────┴────────────┴─────────────────┘${NC}"
    echo ""
}

show_s3_examples() {
    echo ""
    echo -e "  ${CYAN}┌──────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC} ${BOLD}${WHITE}S3 Endpoint Examples${NC}                                             ${CYAN}│${NC}"
    echo -e "  ${CYAN}├──────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC} ${GREEN}iDrive E2${NC}  ${DIM}s3:https://s3.us-central-1.idrivee2.com/bucket${NC}        ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC} ${GREEN}AWS S3${NC}     ${DIM}s3:https://s3.amazonaws.com/bucket${NC}                    ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC} ${GREEN}Wasabi${NC}     ${DIM}s3:https://s3.wasabisys.com/bucket${NC}                    ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC} ${GREEN}Backblaze${NC}  ${DIM}s3:https://s3.us-west-004.backblazeb2.com/bucket${NC}      ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC} ${GREEN}Cloudflare${NC} ${DIM}s3:https://<id>.r2.cloudflarestorage.com/bucket${NC}       ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC} ${GREEN}MinIO${NC}      ${DIM}s3:https://your-minio-server:9000/bucket${NC}              ${CYAN}│${NC}"
    echo -e "  ${CYAN}└──────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

add_backup_job() {
    print_header
    print_section "Add New Backup Job"

    echo -e "  ${CYAN}│${NC} ${BOLD}${WHITE}Basic Configuration${NC}"
    echo -e "  ${CYAN}│${NC}"
    prompt_with_default "Backup job name (e.g., minecraft-server)" "" "BACKUP_NAME"

    BACKUP_NAME=$(echo "$BACKUP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

    if [ -f "$CONFIGS_DIR/${BACKUP_NAME}.conf" ]; then
        error "A backup job with this name already exists!"
        read -r -p "Press Enter to continue..."
        return
    fi

    prompt_with_default "Folder path to backup" "" "FOLDER_PATH"

    if [ ! -d "$FOLDER_PATH" ]; then
        warning "Warning: Directory $FOLDER_PATH does not exist"
        read -r -p "Continue anyway? (y/n): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    prompt_with_default "Backup tag (for categorization)" "general" "BACKUP_TAG"

    echo ""
    echo -e "  ${CYAN}│${NC} ${BOLD}${WHITE}File Paths${NC} ${DIM}(leave empty for defaults)${NC}"
    echo -e "  ${CYAN}│${NC}"
    prompt_with_default "Environment file path" "/root/.env_${BACKUP_NAME}" "ENV_FILE"
    prompt_with_default "Log file path" "/var/log/backup_${BACKUP_NAME}.log" "LOG_FILE"

    echo ""
    read -r -p "Enable LVM snapshot support? (y/n): " lvm_choice
    if [[ "$lvm_choice" =~ ^[Yy]$ ]]; then
        USE_LVM="yes"
        prompt_with_default "LVM Volume Group name" "" "LVM_VG"
        prompt_with_default "LVM Logical Volume name" "" "LVM_LV"
        prompt_with_default "Snapshot size" "5G" "SNAPSHOT_SIZE"
        prompt_with_default "Snapshot mount point" "/mnt/backup_snapshot_${BACKUP_NAME}" "SNAPSHOT_MOUNT"
    else
        USE_LVM="no"
    fi

    echo ""
    read -r -p "Enable Discord notifications? (y/n): " discord_choice
    if [[ "$discord_choice" =~ ^[Yy]$ ]]; then
        USE_DISCORD="yes"
        prompt_with_default "Discord webhook URL" "" "DISCORD_WEBHOOK_URL"

        echo ""
        info "Optional: Discord role IDs for pinging (leave empty to skip)"
        prompt_with_default "Role ID to ping on backup start" "" "PING_ON_START"
        prompt_with_default "Role ID to ping on backup success" "" "PING_ON_SUCCESS"
        prompt_with_default "Role ID to ping on backup failure" "" "PING_ON_FAILURE"
    else
        USE_DISCORD="no"
    fi

    print_section "S3 Storage Configuration"
    show_s3_examples

    prompt_with_default "S3 Access Key ID" "" "AWS_ACCESS_KEY_ID"
    prompt_password "S3 Secret Access Key" "AWS_SECRET_ACCESS_KEY" ""
    prompt_with_default "S3 Repository URL (see examples above)" "" "RESTIC_REPOSITORY"
    prompt_password "Restic encryption password" "RESTIC_PASSWORD" ""

    print_section "Retention Policy"
    echo -e "  ${CYAN}│${NC}  ${WHITE}1)${NC} ${GREEN}simple${NC}     ${DIM}─ Keep last N backups${NC}"
    echo -e "  ${CYAN}│${NC}  ${WHITE}2)${NC} ${GREEN}time${NC}       ${DIM}─ Keep within time period (e.g., 6 months)${NC}"
    echo -e "  ${CYAN}│${NC}  ${WHITE}3)${NC} ${GREEN}count${NC}      ${DIM}─ Keep specific daily/weekly/monthly/yearly${NC}"
    echo -e "  ${CYAN}│${NC}  ${WHITE}4)${NC} ${GREEN}unlimited${NC}  ${DIM}─ Keep all backups (no cleanup)${NC}"
    echo ""

    read -r -p "Select retention method (1-4): " retention_choice
    case $retention_choice in
        1)
            RETENTION_METHOD="simple"
            prompt_with_default "Number of backups to keep" "10" "KEEP_LAST"
            ;;
        2)
            RETENTION_METHOD="time"
            echo "Examples: 7d (7 days), 4w (4 weeks), 6m (6 months), 1y (1 year)"
            prompt_with_default "Keep backups within period" "6m" "KEEP_WITHIN"
            ;;
        3)
            RETENTION_METHOD="count"
            prompt_with_default "Daily backups to keep" "7" "KEEP_DAILY"
            prompt_with_default "Weekly backups to keep" "4" "KEEP_WEEKLY"
            prompt_with_default "Monthly backups to keep" "6" "KEEP_MONTHLY"
            prompt_with_default "Yearly backups to keep" "1" "KEEP_YEARLY"
            ;;
        4)
            RETENTION_METHOD="unlimited"
            ;;
        *)
            error "Invalid choice. Defaulting to 'simple' with 10 backups"
            RETENTION_METHOD="simple"
            KEEP_LAST="10"
            ;;
    esac

    print_section "Backup Schedule"
    echo -e "  ${CYAN}│${NC}  ${GREEN}0 2 * * *${NC}    ${DIM}─ Daily at 2 AM${NC}"
    echo -e "  ${CYAN}│${NC}  ${GREEN}0 */6 * * *${NC}  ${DIM}─ Every 6 hours${NC}"
    echo -e "  ${CYAN}│${NC}  ${GREEN}0 0 * * 0${NC}    ${DIM}─ Weekly on Sunday at midnight${NC}"
    echo -e "  ${CYAN}│${NC}  ${GREEN}0 3 1 * *${NC}    ${DIM}─ Monthly on 1st at 3 AM${NC}"
    echo ""

    prompt_with_default "Cron schedule" "0 2 * * *" "CRON_SCHEDULE"

    print_section "Configuration Summary"
    echo -e "  ${CYAN}│${NC}  ${DIM}Backup Name${NC}  ${WHITE}$BACKUP_NAME${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}Folder${NC}       ${WHITE}$FOLDER_PATH${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}Tag${NC}          ${WHITE}$BACKUP_TAG${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}Env File${NC}     ${WHITE}$ENV_FILE${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}Log File${NC}     ${WHITE}$LOG_FILE${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}LVM Support${NC}  ${WHITE}$USE_LVM${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}Discord${NC}      ${WHITE}$USE_DISCORD${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}Retention${NC}    ${WHITE}$RETENTION_METHOD${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}Schedule${NC}     ${WHITE}$CRON_SCHEDULE${NC}"
    echo ""

    read -r -p "Save this backup job? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warning "Backup job cancelled"
        read -r -p "Press Enter to continue..."
        return
    fi

    save_backup_config

    echo ""
    read -r -p "Test S3 connection now? (y/n): " test_choice
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        test_backup_connection "$BACKUP_NAME"
    fi

    success "Backup job '$BACKUP_NAME' created successfully!"
    read -r -p "Press Enter to continue..."
}

save_backup_config() {
    cat > "$ENV_DIR/${BACKUP_NAME}.env" << EOF
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export RESTIC_PASSWORD="$RESTIC_PASSWORD"
export RESTIC_REPOSITORY="$RESTIC_REPOSITORY"
EOF
    chmod 600 "$ENV_DIR/${BACKUP_NAME}.env"

    cat > "$CONFIGS_DIR/${BACKUP_NAME}.conf" << EOF
BACKUP_NAME="$BACKUP_NAME"
FOLDER_PATH="$FOLDER_PATH"
BACKUP_TAG="$BACKUP_TAG"
ENV_FILE="$ENV_DIR/${BACKUP_NAME}.env"
LOG_FILE="$LOG_FILE"
USE_LVM="$USE_LVM"
USE_DISCORD="$USE_DISCORD"
RETENTION_METHOD="$RETENTION_METHOD"
CRON_SCHEDULE="$CRON_SCHEDULE"
EOF

    if [ "$RETENTION_METHOD" = "simple" ]; then
        echo "KEEP_LAST=\"$KEEP_LAST\"" >> "$CONFIGS_DIR/${BACKUP_NAME}.conf"
    elif [ "$RETENTION_METHOD" = "time" ]; then
        echo "KEEP_WITHIN=\"$KEEP_WITHIN\"" >> "$CONFIGS_DIR/${BACKUP_NAME}.conf"
    elif [ "$RETENTION_METHOD" = "count" ]; then
        cat >> "$CONFIGS_DIR/${BACKUP_NAME}.conf" << EOF
KEEP_DAILY="$KEEP_DAILY"
KEEP_WEEKLY="$KEEP_WEEKLY"
KEEP_MONTHLY="$KEEP_MONTHLY"
KEEP_YEARLY="$KEEP_YEARLY"
EOF
    fi

    if [ "$USE_LVM" = "yes" ]; then
        cat >> "$CONFIGS_DIR/${BACKUP_NAME}.conf" << EOF
LVM_VG="$LVM_VG"
LVM_LV="$LVM_LV"
SNAPSHOT_SIZE="$SNAPSHOT_SIZE"
SNAPSHOT_MOUNT="$SNAPSHOT_MOUNT"
EOF
    fi

    if [ "$USE_DISCORD" = "yes" ]; then
        cat >> "$CONFIGS_DIR/${BACKUP_NAME}.conf" << EOF
DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL"
PING_ON_START="$PING_ON_START"
PING_ON_SUCCESS="$PING_ON_SUCCESS"
PING_ON_FAILURE="$PING_ON_FAILURE"
EOF
    fi

    download_backup_script
    setup_cron_job
}

download_backup_script() {
    local script_name

    if [ "$USE_LVM" = "yes" ] && [ "$USE_DISCORD" = "yes" ]; then
        script_name="s3_backup_lvm_discord.sh"
    elif [ "$USE_LVM" = "yes" ]; then
        script_name="s3_backup_lvm.sh"
    elif [ "$USE_DISCORD" = "yes" ]; then
        script_name="s3_backup_discord.sh"
    else
        script_name="s3_backup.sh"
    fi

    local script_path="$SCRIPTS_DIR/${BACKUP_NAME}.sh"
    local github_url="https://raw.githubusercontent.com/DayZero-Dev/DayZero-Backup/main/$script_name"

    info "Downloading backup script: $script_name"

    if wget -q "$github_url" -O "$script_path" 2>/dev/null; then
        success "Downloaded from GitHub"
    else
        local local_script="$(dirname "$0")/$script_name"
        if [ -f "$local_script" ]; then
            cp "$local_script" "$script_path"
            success "Copied from local directory"
        else
            warning "Could not download script. You'll need to manually place $script_name at $script_path"
            return 1
        fi
    fi

    sed -i "s|ENV_FILE=\".*\"|ENV_FILE=\"$ENV_DIR/${BACKUP_NAME}.env\"|g" "$script_path"
    sed -i "s|BACKUP_NAME=\".*\"|BACKUP_NAME=\"$BACKUP_NAME\"|g" "$script_path"
    sed -i "s|FOLDER_PATH=\".*\"|FOLDER_PATH=\"$FOLDER_PATH\"|g" "$script_path"
    sed -i "s|BACKUP_TAG=\".*\"|BACKUP_TAG=\"$BACKUP_TAG\"|g" "$script_path"
    sed -i "s|LOG_FILE=\".*\"|LOG_FILE=\"$LOG_FILE\"|g" "$script_path"
    sed -i "s|RETENTION_METHOD=\".*\"|RETENTION_METHOD=\"$RETENTION_METHOD\"|g" "$script_path"

    if [ "$RETENTION_METHOD" = "simple" ]; then
        sed -i "s|KEEP_LAST=.*|KEEP_LAST=$KEEP_LAST|g" "$script_path"
    elif [ "$RETENTION_METHOD" = "time" ]; then
        sed -i "s|KEEP_WITHIN=\".*\"|KEEP_WITHIN=\"$KEEP_WITHIN\"|g" "$script_path"
    elif [ "$RETENTION_METHOD" = "count" ]; then
        sed -i "s|KEEP_DAILY=.*|KEEP_DAILY=$KEEP_DAILY|g" "$script_path"
        sed -i "s|KEEP_WEEKLY=.*|KEEP_WEEKLY=$KEEP_WEEKLY|g" "$script_path"
        sed -i "s|KEEP_MONTHLY=.*|KEEP_MONTHLY=$KEEP_MONTHLY|g" "$script_path"
        sed -i "s|KEEP_YEARLY=.*|KEEP_YEARLY=$KEEP_YEARLY|g" "$script_path"
    fi

    if [ "$USE_LVM" = "yes" ]; then
        sed -i "s|LVM_VG=\".*\"|LVM_VG=\"$LVM_VG\"|g" "$script_path"
        sed -i "s|LVM_LV=\".*\"|LVM_LV=\"$LVM_LV\"|g" "$script_path"
        sed -i "s|SNAPSHOT_SIZE=\".*\"|SNAPSHOT_SIZE=\"$SNAPSHOT_SIZE\"|g" "$script_path"
        sed -i "s|SNAPSHOT_MOUNT=\".*\"|SNAPSHOT_MOUNT=\"$SNAPSHOT_MOUNT\"|g" "$script_path"
    fi

    if [ "$USE_DISCORD" = "yes" ]; then
        sed -i "s|DISCORD_WEBHOOK_URL=\".*\"|DISCORD_WEBHOOK_URL=\"$DISCORD_WEBHOOK_URL\"|g" "$script_path"
        sed -i "s|PING_ON_START=\".*\"|PING_ON_START=\"$PING_ON_START\"|g" "$script_path"
        sed -i "s|PING_ON_SUCCESS=\".*\"|PING_ON_SUCCESS=\"$PING_ON_SUCCESS\"|g" "$script_path"
        sed -i "s|PING_ON_FAILURE=\".*\"|PING_ON_FAILURE=\"$PING_ON_FAILURE\"|g" "$script_path"
    fi

    chmod +x "$script_path"
    success "Backup script customized and saved"
}

setup_cron_job() {
    local cron_entry="$CRON_SCHEDULE $SCRIPTS_DIR/${BACKUP_NAME}.sh >> $LOG_FILE 2>&1"
    local existing
    existing=$(get_current_crontab)

    if echo "$existing" | grep -q "$SCRIPTS_DIR/${BACKUP_NAME}.sh"; then
        existing=$(echo "$existing" | grep -v "$SCRIPTS_DIR/${BACKUP_NAME}.sh")
    fi

    if [ -n "$existing" ]; then
        printf '%s\n%s\n' "$existing" "$cron_entry" | crontab -
    else
        echo "$cron_entry" | crontab -
    fi

    success "Cron job configured: $CRON_SCHEDULE"
}

edit_backup_job() {
    print_header
    print_section "Edit Backup Job"

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR" 2>/dev/null)" ]; then
        error "No backup jobs configured yet"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo -e "  ${CYAN}│${NC} Available backup jobs:"
    echo -e "  ${CYAN}│${NC}"
    local i=1
    declare -a job_names
    for config_file in "$CONFIGS_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            local name
            name=$(basename "$config_file" .conf)
            job_names[$i]=$name
            echo -e "  ${CYAN}│${NC}  ${WHITE}$i)${NC} $name"
            ((i++))
        fi
    done
    echo ""

    echo -ne "  ${CYAN}▸${NC} ${WHITE}Select job to edit${NC} ${DIM}(0 to cancel)${NC}: "
    read -r job_num

    if [ "$job_num" -eq 0 ] 2>/dev/null; then
        return
    fi

    if [ -z "${job_names[$job_num]:-}" ]; then
        error "Invalid selection"
        read -r -p "  Press Enter to continue..."
        return
    fi

    BACKUP_NAME="${job_names[$job_num]}"

    source "$CONFIGS_DIR/${BACKUP_NAME}.conf"
    source "$ENV_DIR/${BACKUP_NAME}.env"

    print_section "Editing: $BACKUP_NAME"
    info "Press Enter to keep current value"
    echo ""

    prompt_with_default "Folder path to backup" "$FOLDER_PATH" "FOLDER_PATH"
    prompt_with_default "Backup tag" "$BACKUP_TAG" "BACKUP_TAG"
    prompt_with_default "Environment file path" "$ENV_FILE" "ENV_FILE"
    prompt_with_default "Log file path" "$LOG_FILE" "LOG_FILE"

    echo ""
    echo -e "  ${CYAN}│${NC} ${BOLD}${WHITE}S3 Configuration${NC} ${DIM}(leave empty to keep current)${NC}"
    echo -e "  ${CYAN}│${NC}"
    prompt_with_default "S3 Access Key ID" "$AWS_ACCESS_KEY_ID" "AWS_ACCESS_KEY_ID"
    prompt_password "S3 Secret Access Key" "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY"
    prompt_with_default "S3 Repository URL" "$RESTIC_REPOSITORY" "RESTIC_REPOSITORY"
    prompt_password "Restic encryption password" "RESTIC_PASSWORD" "$RESTIC_PASSWORD"

    if [ "$USE_DISCORD" = "yes" ]; then
        echo ""
        read -r -p "Disable Discord notifications? (y/n): " disable_discord
        if [[ "$disable_discord" =~ ^[Yy]$ ]]; then
            USE_DISCORD="no"
        else
            prompt_with_default "Discord webhook URL" "$DISCORD_WEBHOOK_URL" "DISCORD_WEBHOOK_URL"
            prompt_with_default "Role ID to ping on start" "$PING_ON_START" "PING_ON_START"
            prompt_with_default "Role ID to ping on success" "$PING_ON_SUCCESS" "PING_ON_SUCCESS"
            prompt_with_default "Role ID to ping on failure" "$PING_ON_FAILURE" "PING_ON_FAILURE"
        fi
    else
        echo ""
        read -r -p "Enable Discord notifications? (y/n): " enable_discord
        if [[ "$enable_discord" =~ ^[Yy]$ ]]; then
            USE_DISCORD="yes"
            prompt_with_default "Discord webhook URL" "" "DISCORD_WEBHOOK_URL"
            prompt_with_default "Role ID to ping on start" "" "PING_ON_START"
            prompt_with_default "Role ID to ping on success" "" "PING_ON_SUCCESS"
            prompt_with_default "Role ID to ping on failure" "" "PING_ON_FAILURE"
        fi
    fi

    echo ""
    echo -e "  ${CYAN}│${NC} Current retention: ${WHITE}$RETENTION_METHOD${NC}"
    read -r -p "Change retention method? (y/n): " change_retention
    if [[ "$change_retention" =~ ^[Yy]$ ]]; then
        echo -e "  ${CYAN}│${NC}  ${WHITE}1)${NC} ${GREEN}simple${NC}     ${DIM}─ Keep last N backups${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}2)${NC} ${GREEN}time${NC}       ${DIM}─ Keep within time period${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}3)${NC} ${GREEN}count${NC}      ${DIM}─ Keep specific daily/weekly/monthly/yearly${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}4)${NC} ${GREEN}unlimited${NC}  ${DIM}─ Keep all backups${NC}"
        echo ""

        read -r -p "Select retention method (1-4): " retention_choice
        case $retention_choice in
            1)
                RETENTION_METHOD="simple"
                prompt_with_default "Number of backups to keep" "${KEEP_LAST:-10}" "KEEP_LAST"
                ;;
            2)
                RETENTION_METHOD="time"
                prompt_with_default "Keep backups within period" "${KEEP_WITHIN:-6m}" "KEEP_WITHIN"
                ;;
            3)
                RETENTION_METHOD="count"
                prompt_with_default "Daily backups to keep" "${KEEP_DAILY:-7}" "KEEP_DAILY"
                prompt_with_default "Weekly backups to keep" "${KEEP_WEEKLY:-4}" "KEEP_WEEKLY"
                prompt_with_default "Monthly backups to keep" "${KEEP_MONTHLY:-6}" "KEEP_MONTHLY"
                prompt_with_default "Yearly backups to keep" "${KEEP_YEARLY:-1}" "KEEP_YEARLY"
                ;;
            4)
                RETENTION_METHOD="unlimited"
                ;;
        esac
    fi

    echo ""
    prompt_with_default "Cron schedule" "$CRON_SCHEDULE" "CRON_SCHEDULE"

    echo ""
    read -r -p "Save changes? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        save_backup_config
        success "Backup job '$BACKUP_NAME' updated successfully!"
    else
        warning "Changes discarded"
    fi

    read -r -p "Press Enter to continue..."
}

delete_backup_job() {
    print_header
    print_section "Delete Backup Job"

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR" 2>/dev/null)" ]; then
        error "No backup jobs configured yet"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo -e "  ${CYAN}│${NC} Available backup jobs:"
    echo -e "  ${CYAN}│${NC}"
    local i=1
    declare -a job_names
    for config_file in "$CONFIGS_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            local name
            name=$(basename "$config_file" .conf)
            job_names[$i]=$name
            echo -e "  ${CYAN}│${NC}  ${WHITE}$i)${NC} $name"
            ((i++))
        fi
    done
    echo ""

    echo -ne "  ${CYAN}▸${NC} ${WHITE}Select job to delete${NC} ${DIM}(0 to cancel)${NC}: "
    read -r job_num

    if [ "$job_num" -eq 0 ] 2>/dev/null; then
        return
    fi

    if [ -z "${job_names[$job_num]:-}" ]; then
        error "Invalid selection"
        read -r -p "  Press Enter to continue..."
        return
    fi

    local backup_name="${job_names[$job_num]}"

    echo -e "  ${RED}┌──────────────────────────────────────────────┐${NC}"
    echo -e "  ${RED}│${NC} ${BOLD}${RED}This will delete:${NC}                             ${RED}│${NC}"
    echo -e "  ${RED}│${NC}  ${DIM}•${NC} Configuration file                        ${RED}│${NC}"
    echo -e "  ${RED}│${NC}  ${DIM}•${NC} Environment file (credentials)             ${RED}│${NC}"
    echo -e "  ${RED}│${NC}  ${DIM}•${NC} Backup script                              ${RED}│${NC}"
    echo -e "  ${RED}│${NC}  ${DIM}•${NC} Cron job                                   ${RED}│${NC}"
    echo -e "  ${RED}│${NC}                                              ${RED}│${NC}"
    echo -e "  ${RED}│${NC} ${YELLOW}⚠ Will NOT delete your backup data from S3!${NC}  ${RED}│${NC}"
    echo -e "  ${RED}└──────────────────────────────────────────────┘${NC}"
    echo ""

    read -r -p "Are you sure you want to delete '$backup_name'? (type 'yes' to confirm): " confirm

    if [ "$confirm" = "yes" ]; then
        rm -f "$CONFIGS_DIR/${backup_name}.conf"
        rm -f "$ENV_DIR/${backup_name}.env"
        rm -f "$SCRIPTS_DIR/${backup_name}.sh"

        local existing
        existing=$(get_current_crontab)
        if [ -n "$existing" ]; then
            echo "$existing" | grep -v "$SCRIPTS_DIR/${backup_name}.sh" | crontab - 2>/dev/null || crontab -r 2>/dev/null || true
        fi

        success "Backup job '$backup_name' deleted successfully!"
    else
        warning "Deletion cancelled"
    fi

    read -r -p "Press Enter to continue..."
}

test_backup_connection() {
    local backup_name="$1"

    if [ ! -f "$CONFIGS_DIR/${backup_name}.conf" ]; then
        error "Backup job '$backup_name' not found"
        return 1
    fi

    source "$CONFIGS_DIR/${backup_name}.conf"
    source "$ENV_DIR/${backup_name}.env"

    print_section "Testing S3 Connection"
    info "Repository: $RESTIC_REPOSITORY"

    if restic snapshots --quiet &>/dev/null; then
        success "Connection successful! Repository is accessible"
        echo ""
        info "Latest snapshots:"
        restic snapshots --compact --last 5
        return 0
    fi

    local init_output
    init_output=$(restic init 2>&1 || true)

    if echo "$init_output" | grep -q "already initialized"; then
        success "Repository already initialized and accessible"
        return 0
    elif echo "$init_output" | grep -q "created restic repository"; then
        success "Repository initialized successfully!"
        return 0
    fi

    warning "Repository not found. Would you like to initialize it?"
    read -r -p "Initialize repository? (y/n): " init_choice
    if [[ "$init_choice" =~ ^[Yy]$ ]]; then
        if restic init; then
            success "Repository initialized successfully!"
        else
            error "Failed to initialize repository"
            return 1
        fi
    fi
}

test_backup_job() {
    print_header
    print_section "Test Backup Job"

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR" 2>/dev/null)" ]; then
        error "No backup jobs configured yet"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo -e "  ${CYAN}│${NC} Available backup jobs:"
    echo -e "  ${CYAN}│${NC}"
    local i=1
    declare -a job_names
    for config_file in "$CONFIGS_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            local name
            name=$(basename "$config_file" .conf)
            job_names[$i]=$name
            echo -e "  ${CYAN}│${NC}  ${WHITE}$i)${NC} $name"
            ((i++))
        fi
    done
    echo ""

    echo -ne "  ${CYAN}▸${NC} ${WHITE}Select job to test${NC} ${DIM}(0 to cancel)${NC}: "
    read -r job_num

    if [ "$job_num" -eq 0 ] 2>/dev/null; then
        return
    fi

    if [ -z "${job_names[$job_num]:-}" ]; then
        error "Invalid selection"
        read -r -p "  Press Enter to continue..."
        return
    fi

    local backup_name="${job_names[$job_num]}"

    print_section "Running Backup: $backup_name"

    if [ ! -f "$SCRIPTS_DIR/${backup_name}.sh" ]; then
        error "Backup script not found: $SCRIPTS_DIR/${backup_name}.sh"
        read -r -p "Press Enter to continue..."
        return
    fi

    bash "$SCRIPTS_DIR/${backup_name}.sh"

    echo ""
    success "Backup test completed. Check the log file for details."

    source "$CONFIGS_DIR/${backup_name}.conf"
    echo "Log file: $LOG_FILE"
    echo ""

    read -r -p "View log file? (y/n): " view_log
    if [[ "$view_log" =~ ^[Yy]$ ]]; then
        if [ -f "$LOG_FILE" ]; then
            tail -n 50 "$LOG_FILE"
        else
            warning "Log file not found"
        fi
    fi

    echo ""
    read -r -p "Press Enter to continue..."
}

view_logs() {
    print_header
    print_section "View Backup Logs"

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR" 2>/dev/null)" ]; then
        error "No backup jobs configured yet"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo -e "  ${CYAN}│${NC} Available backup jobs:"
    echo -e "  ${CYAN}│${NC}"
    local i=1
    declare -a job_names
    for config_file in "$CONFIGS_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            local name
            name=$(basename "$config_file" .conf)
            job_names[$i]=$name
            echo -e "  ${CYAN}│${NC}  ${WHITE}$i)${NC} $name"
            ((i++))
        fi
    done
    echo ""

    echo -ne "  ${CYAN}▸${NC} ${WHITE}Select job to view logs${NC} ${DIM}(0 to cancel)${NC}: "
    read -r job_num

    if [ "$job_num" -eq 0 ] 2>/dev/null; then
        return
    fi

    if [ -z "${job_names[$job_num]:-}" ]; then
        error "Invalid selection"
        read -r -p "  Press Enter to continue..."
        return
    fi

    local backup_name="${job_names[$job_num]}"
    source "$CONFIGS_DIR/${backup_name}.conf"

    if [ ! -f "$LOG_FILE" ]; then
        warning "Log file not found: $LOG_FILE"
        read -r -p "Press Enter to continue..."
        return
    fi

    print_section "Logs: $backup_name"
    echo "Log file: $LOG_FILE"
    echo ""

    read -r -p "How many lines to show? (default: 50): " num_lines
    num_lines=${num_lines:-50}

    echo ""
    tail -n "$num_lines" "$LOG_FILE"

    echo ""
    read -r -p "Press Enter to continue..."
}

select_backup_job() {
    local action_label="$1"

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR" 2>/dev/null)" ]; then
        error "No backup jobs configured yet"
        read -r -p "Press Enter to continue..."
        return 1
    fi

    echo -e "  ${CYAN}│${NC} Available backup jobs:"
    echo -e "  ${CYAN}│${NC}"
    local i=1
    declare -g -a _job_names
    _job_names=()
    for config_file in "$CONFIGS_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            local name
            name=$(basename "$config_file" .conf)
            _job_names[$i]=$name
            echo -e "  ${CYAN}│${NC}  ${WHITE}$i)${NC} $name"
            ((i++))
        fi
    done
    echo ""

    echo -ne "  ${CYAN}▸${NC} ${WHITE}Select job to ${action_label}${NC} ${DIM}(0 to cancel)${NC}: "
    read -r _job_num

    if [ "$_job_num" -eq 0 ] 2>/dev/null; then
        return 1
    fi

    if [ -z "${_job_names[$_job_num]:-}" ]; then
        error "Invalid selection"
        read -r -p "  Press Enter to continue..."
        return 1
    fi

    SELECTED_JOB="${_job_names[$_job_num]}"
    return 0
}

load_job_env() {
    local job_name="$1"
    source "$CONFIGS_DIR/${job_name}.conf"
    source "$ENV_DIR/${job_name}.env"
}

manage_snapshots() {
    while true; do
        print_header
        print_section "Snapshot Manager"

        echo -e "  ${CYAN}┌──────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}1)${NC}  ${BLUE}List${NC} snapshots                          ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}2)${NC}  ${GREEN}Restore${NC} a snapshot                      ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}3)${NC}  ${YELLOW}Browse${NC} files in a snapshot              ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}4)${NC}  ${MAGENTA}Repository${NC} statistics                   ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}5)${NC}  ${CYAN}Restore${NC} specific files/folders          ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}6)${NC}  ${RED}Delete${NC} a snapshot                       ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}                                              ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${DIM}0)  Back to main menu${NC}                       ${CYAN}│${NC}"
        echo -e "  ${CYAN}└──────────────────────────────────────────────┘${NC}"
        echo ""

        echo -ne "  ${CYAN}▸${NC} ${WHITE}Select option${NC}: "
        read -r snap_choice

        case $snap_choice in
            1) list_snapshots ;;
            2) restore_snapshot ;;
            3) browse_snapshot ;;
            4) repo_statistics ;;
            5) restore_specific_files ;;
            6) delete_snapshot ;;
            0) return ;;
            *)
                error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

list_snapshots() {
    print_header
    print_section "List Snapshots"

    if ! select_backup_job "list snapshots"; then
        return
    fi

    load_job_env "$SELECTED_JOB"

    info "Fetching snapshots for ${WHITE}${SELECTED_JOB}${NC}..."
    echo ""

    if ! restic snapshots --compact 2>/dev/null; then
        error "Failed to connect to repository"
        echo ""
        warning "Check your S3 credentials and endpoint"
    fi

    echo ""
    read -r -p "Press Enter to continue..."
}

restore_snapshot() {
    print_header
    print_section "Restore Snapshot"

    if ! select_backup_job "restore"; then
        return
    fi

    load_job_env "$SELECTED_JOB"

    info "Fetching snapshots for ${WHITE}${SELECTED_JOB}${NC}..."
    echo ""

    if ! restic snapshots --compact 2>/dev/null; then
        error "Failed to connect to repository"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -ne "  ${CYAN}▸${NC} ${WHITE}Enter snapshot ID to restore${NC} ${DIM}(or 'latest')${NC}: "
    read -r snapshot_id

    if [ -z "$snapshot_id" ]; then
        warning "No snapshot selected"
        read -r -p "Press Enter to continue..."
        return
    fi

    prompt_with_default "Restore to directory" "$FOLDER_PATH" "RESTORE_TARGET"

    echo ""
    echo -e "  ${YELLOW}┌──────────────────────────────────────────────┐${NC}"
    echo -e "  ${YELLOW}│${NC} ${BOLD}${WHITE}Restore Summary${NC}                              ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}                                              ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  ${DIM}Job${NC}        ${WHITE}$SELECTED_JOB${NC}                          ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  ${DIM}Snapshot${NC}   ${WHITE}$snapshot_id${NC}                           ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  ${DIM}Restore to${NC} ${WHITE}$RESTORE_TARGET${NC}                        ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}                                              ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC} ${RED}⚠ This will overwrite existing files!${NC}        ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}└──────────────────────────────────────────────┘${NC}"
    echo ""

    read -r -p "Proceed with restore? (type 'yes' to confirm): " confirm

    if [ "$confirm" = "yes" ]; then
        info "Restoring snapshot ${WHITE}${snapshot_id}${NC}..."
        echo ""

        if restic restore "$snapshot_id" --target "$RESTORE_TARGET" 2>&1; then
            echo ""
            success "Restore completed successfully!"
            info "Files restored to: $RESTORE_TARGET"
        else
            echo ""
            error "Restore failed! Check the error above"
        fi
    else
        warning "Restore cancelled"
    fi

    echo ""
    read -r -p "Press Enter to continue..."
}

browse_snapshot() {
    print_header
    print_section "Browse Snapshot Files"

    if ! select_backup_job "browse"; then
        return
    fi

    load_job_env "$SELECTED_JOB"

    info "Fetching snapshots for ${WHITE}${SELECTED_JOB}${NC}..."
    echo ""

    if ! restic snapshots --compact 2>/dev/null; then
        error "Failed to connect to repository"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -ne "  ${CYAN}▸${NC} ${WHITE}Enter snapshot ID to browse${NC} ${DIM}(or 'latest')${NC}: "
    read -r snapshot_id

    if [ -z "$snapshot_id" ]; then
        warning "No snapshot selected"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -ne "  ${CYAN}▸${NC} ${WHITE}Path to list${NC} ${DIM}[/]${NC}: "
    read -r browse_path
    browse_path="${browse_path:-/}"

    echo ""
    info "Files in snapshot ${WHITE}${snapshot_id}${NC} at ${WHITE}${browse_path}${NC}:"
    echo ""

    if ! restic ls "$snapshot_id" "$browse_path" 2>/dev/null | head -n 100; then
        error "Failed to list files"
    fi

    echo ""
    info "Showing first 100 entries"

    echo ""
    read -r -p "Press Enter to continue..."
}

restore_specific_files() {
    print_header
    print_section "Restore Specific Files"

    if ! select_backup_job "restore files from"; then
        return
    fi

    load_job_env "$SELECTED_JOB"

    info "Fetching snapshots for ${WHITE}${SELECTED_JOB}${NC}..."
    echo ""

    if ! restic snapshots --compact 2>/dev/null; then
        error "Failed to connect to repository"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -ne "  ${CYAN}▸${NC} ${WHITE}Enter snapshot ID${NC} ${DIM}(or 'latest')${NC}: "
    read -r snapshot_id

    if [ -z "$snapshot_id" ]; then
        warning "No snapshot selected"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -e "  ${CYAN}│${NC} ${DIM}Enter file/folder paths to restore (one per line)${NC}"
    echo -e "  ${CYAN}│${NC} ${DIM}Type 'done' when finished${NC}"
    echo ""

    local -a include_paths=()
    while true; do
        echo -ne "  ${CYAN}▸${NC} ${WHITE}Path${NC}: "
        read -r file_path
        if [ "$file_path" = "done" ] || [ -z "$file_path" ]; then
            break
        fi
        include_paths+=("--include" "$file_path")
    done

    if [ ${#include_paths[@]} -eq 0 ]; then
        warning "No paths specified"
        read -r -p "Press Enter to continue..."
        return
    fi

    prompt_with_default "Restore to directory" "$FOLDER_PATH" "RESTORE_TARGET"

    echo ""
    info "Restoring selected files from snapshot ${WHITE}${snapshot_id}${NC}..."
    echo ""

    if restic restore "$snapshot_id" --target "$RESTORE_TARGET" "${include_paths[@]}" 2>&1; then
        echo ""
        success "Files restored successfully!"
        info "Restored to: $RESTORE_TARGET"
    else
        echo ""
        error "Restore failed! Check the error above"
    fi

    echo ""
    read -r -p "Press Enter to continue..."
}

repo_statistics() {
    print_header
    print_section "Repository Statistics"

    if ! select_backup_job "view stats for"; then
        return
    fi

    load_job_env "$SELECTED_JOB"

    info "Fetching statistics for ${WHITE}${SELECTED_JOB}${NC}..."
    echo ""

    print_section "Snapshot Count"
    local snap_count
    snap_count=$(restic snapshots --compact 2>/dev/null | tail -n +3 | grep -c '^' || echo "0")
    echo -e "  ${CYAN}│${NC} Total snapshots: ${WHITE}${snap_count}${NC}"
    echo ""

    print_section "Repository Size"
    if ! restic stats 2>/dev/null; then
        error "Failed to get repository stats"
    fi

    echo ""

    print_section "Latest Snapshot"
    if ! restic snapshots --last 1 2>/dev/null; then
        error "Failed to get latest snapshot"
    fi

    echo ""

    print_section "Repository Integrity"
    read -r -p "Run integrity check? This may take a while (y/n): " check_choice
    if [[ "$check_choice" =~ ^[Yy]$ ]]; then
        echo ""
        info "Checking repository integrity..."
        echo ""
        if restic check 2>&1; then
            echo ""
            success "Repository integrity check passed!"
        else
            echo ""
            error "Repository integrity check failed!"
        fi
    fi

    echo ""
    read -r -p "Press Enter to continue..."
}

delete_snapshot() {
    print_header
    print_section "Delete Snapshot"

    if ! select_backup_job "delete snapshot from"; then
        return
    fi

    load_job_env "$SELECTED_JOB"

    info "Fetching snapshots for ${WHITE}${SELECTED_JOB}${NC}..."
    echo ""

    if ! restic snapshots --compact 2>/dev/null; then
        error "Failed to connect to repository"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -ne "  ${CYAN}▸${NC} ${WHITE}Enter snapshot ID to delete${NC}: "
    read -r snapshot_id

    if [ -z "$snapshot_id" ]; then
        warning "No snapshot selected"
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -e "  ${RED}┌──────────────────────────────────────────────┐${NC}"
    echo -e "  ${RED}│${NC} ${BOLD}${RED}WARNING${NC}                                       ${RED}│${NC}"
    echo -e "  ${RED}│${NC}                                              ${RED}│${NC}"
    echo -e "  ${RED}│${NC} This will permanently delete snapshot:       ${RED}│${NC}"
    echo -e "  ${RED}│${NC}  ${WHITE}${snapshot_id}${NC}"
    echo -e "  ${RED}│${NC}                                              ${RED}│${NC}"
    echo -e "  ${RED}│${NC} ${YELLOW}⚠ This action cannot be undone!${NC}              ${RED}│${NC}"
    echo -e "  ${RED}└──────────────────────────────────────────────┘${NC}"
    echo ""

    read -r -p "Type 'yes' to confirm deletion: " confirm

    if [ "$confirm" = "yes" ]; then
        info "Removing snapshot ${WHITE}${snapshot_id}${NC}..."
        echo ""

        if restic forget "$snapshot_id" --prune 2>&1; then
            echo ""
            success "Snapshot deleted and repository pruned"
        else
            echo ""
            error "Failed to delete snapshot"
        fi
    else
        warning "Deletion cancelled"
    fi

    echo ""
    read -r -p "Press Enter to continue..."
}

main_menu() {
    while true; do
        print_header
        echo -e "  ${CYAN}┌──────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}1)${NC}${GREEN}  Add${NC} new backup job                      ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}2)${NC}${BLUE}  List${NC} all backup jobs                    ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}3)${NC}${YELLOW}  Edit${NC} existing backup job                ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}4)${NC}${RED}  Delete${NC} backup job                       ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}5)${NC}${MAGENTA}  Test${NC} backup job (run manually)          ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}6)${NC}${CYAN}  View${NC} backup logs                        ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}7)${NC}${WHITE}  Manage${NC} snapshots & restore              ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${WHITE}8)${NC}${DIM}  Check${NC} restic installation               ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}                                              ${CYAN}│${NC}"
        echo -e "  ${CYAN}│${NC}  ${DIM}0)  Exit${NC}                                    ${CYAN}│${NC}"
        echo -e "  ${CYAN}└──────────────────────────────────────────────┘${NC}"
        echo ""

        echo -ne "  ${CYAN}▸${NC} ${WHITE}Select option${NC}: "
        read -r choice

        case $choice in
            1) add_backup_job ;;
            2) list_backup_jobs; read -r -p "Press Enter to continue..." ;;
            3) edit_backup_job ;;
            4) delete_backup_job ;;
            5) test_backup_job ;;
            6) view_logs ;;
            7) manage_snapshots ;;
            8) check_restic; read -r -p "Press Enter to continue..." ;;
            0)
                echo ""
                info "Goodbye!"
                exit 0
                ;;
            *)
                error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

main() {
    check_root
    init_directories
    check_and_install_command
    check_restic
    main_menu
}

main "$@"
