#!/bin/bash

set -euo pipefail

ENV_FILE="/path/to/your/.env"
BACKUP_NAME="Your_Backup_Name"
LVM_VOLUME="/dev/vg_name/lv_name"
SNAPSHOT_NAME="backup_snapshot"
SNAPSHOT_SIZE="5G"
MOUNT_POINT="/mnt/backup_snapshot"
BACKUP_TAG="tag"
LOG_FILE="/var/log/backup_${BACKUP_NAME}.log"
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"


RETENTION_METHOD="simple"

KEEP_WITHIN="6m"

KEEP_LAST=10

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=1

PING_ON_START=""
PING_ON_SUCCESS=""
PING_ON_FAILURE=""

log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

cleanup_snapshot() {
    log "Cleaning up LVM snapshot..."
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    if lvs "$LVM_VOLUME-$SNAPSHOT_NAME" &>/dev/null; then
        lvremove -f "$LVM_VOLUME-$SNAPSHOT_NAME" 2>/dev/null || true
    fi
    [ -d "$MOUNT_POINT" ] && rmdir "$MOUNT_POINT" 2>/dev/null || true
}

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    log "CRITICAL ERROR: Secrets file $ENV_FILE not found!"
    exit 1
fi

send_discord_notification() {
    local title="$1"
    local description="$2"
    local color="$3"
    local ping_role="$4"
    local extra_fields="$5"
    local discord_timestamp="<t:$(date +%s):F>"
    
    local content=""
    if [ -n "$ping_role" ]; then
        content="\"content\": \"<@&$ping_role>\","
    fi
    
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -H "Content-Type: application/json" -X POST -d "{
            $content
            \"embeds\": [{
                \"title\": \"$title\",
                \"description\": \"$description\",
                \"color\": $color,
                \"fields\": [
                    {
                        \"name\": \"⏰ Date & Time\",
                        \"value\": \"$discord_timestamp\",
                        \"inline\": false
                    }$extra_fields
                ],
                \"footer\": {
                    \"text\": \"$BACKUP_NAME | DayZero Backup LVM • Made by DayZero.CC\"
                }
            }]
        }" "$DISCORD_WEBHOOK_URL" 2>/dev/null
    fi
}

log "Starting LVM snapshot backup process for $BACKUP_NAME"

REPO_CHECK=$(restic snapshots 2>&1 || true)
if echo "$REPO_CHECK" | grep -q "Is there a repository at the following location"; then
    log "Repository not found. Initializing new repository..."
    if restic init; then
        log "Repository initialized successfully."
    else
        log "Failed to initialize repository."
        send_discord_notification "❌ Initialization Failed" "Failed to initialize restic repository for **$BACKUP_NAME**" "15158332" "$PING_ON_FAILURE" ""
        exit 1
    fi
elif echo "$REPO_CHECK" | grep -q "unable to create lock"; then
    log "Repository is locked by another process. Skipping this backup run."
    exit 0
elif echo "$REPO_CHECK" | grep -q "repository is already locked"; then
    log "Repository is locked by another process. Skipping this backup run."
    exit 0
elif ! echo "$REPO_CHECK" | grep -q "repository"; then
    :
fi

log "Unlocking repository (in case of stale locks)..."
restic unlock 2>/dev/null || true

send_discord_notification "🔄 Backup Started" "LVM snapshot backup process initiated for **$BACKUP_NAME**" "3447003" "$PING_ON_START" ""

log "Creating LVM snapshot..."
cleanup_snapshot
if ! lvcreate -L"$SNAPSHOT_SIZE" -s -n "$SNAPSHOT_NAME" "$LVM_VOLUME"; then
    log "Failed to create LVM snapshot."
    send_discord_notification "❌ LVM Snapshot Failed" "Failed to create LVM snapshot for **$BACKUP_NAME**" "15158332" "$PING_ON_FAILURE" ""
    exit 1
fi

log "Mounting LVM snapshot..."
mkdir -p "$MOUNT_POINT"
if ! mount -o ro "$LVM_VOLUME-$SNAPSHOT_NAME" "$MOUNT_POINT"; then
    log "Failed to mount LVM snapshot."
    cleanup_snapshot
    send_discord_notification "❌ Mount Failed" "Failed to mount LVM snapshot for **$BACKUP_NAME**" "15158332" "$PING_ON_FAILURE" ""
    exit 1
fi

log "Running restic backup from LVM snapshot..."
set +e
BACKUP_OUTPUT=$(restic backup "$MOUNT_POINT" --tag "$BACKUP_NAME" --tag "$BACKUP_TAG" 2>&1)
BACKUP_EXIT_CODE=$?
set -e

cleanup_snapshot

if [ $BACKUP_EXIT_CODE -eq 0 ]; then
    log "Backup successful."
    
    BACKUP_SIZE=$(echo "$BACKUP_OUTPUT" | grep "Added to the repository:" | awk '{print $5, $6}')
    if [ -z "$BACKUP_SIZE" ]; then
        BACKUP_SIZE="N/A"
    fi
    
    SNAPSHOT_COUNT=$(restic snapshots --compact 2>/dev/null | tail -n1 | awk '{print $1}' || echo "0")
    
    FILES_PROCESSED=$(echo "$BACKUP_OUTPUT" | grep "Files:" | awk '{print $2}')
    if [ -z "$FILES_PROCESSED" ]; then
        FILES_PROCESSED="N/A"
    fi
    
    SIZE_FIELD=",{\"name\": \"📦 Backup Size\", \"value\": \"$BACKUP_SIZE\", \"inline\": true}"
    SNAPSHOT_FIELD=",{\"name\": \"📸 Total Snapshots\", \"value\": \"$SNAPSHOT_COUNT\", \"inline\": true}"
    FILES_FIELD=",{\"name\": \"📁 Files Processed\", \"value\": \"$FILES_PROCESSED\", \"inline\": true}"
    LVM_FIELD=",{\"name\": \"💾 LVM Snapshot\", \"value\": \"Used for consistency\", \"inline\": true}"
    
    send_discord_notification "✅ Backup Successful" "LVM snapshot backup completed successfully for **$BACKUP_NAME**" "5763719" "$PING_ON_SUCCESS" "$SIZE_FIELD$SNAPSHOT_FIELD$FILES_FIELD$LVM_FIELD"
else
    log "BACKUP FAILED."
    send_discord_notification "❌ Backup Failed" "Backup failed for **$BACKUP_NAME**. Check logs at \`$LOG_FILE\`" "15158332" "$PING_ON_FAILURE" ""
    exit 1
fi

if [ "$RETENTION_METHOD" = "unlimited" ]; then
    log "Retention policy set to UNLIMITED - skipping pruning. All backups will be kept indefinitely."
    send_discord_notification "♾️ Pruning Skipped" "Retention set to **UNLIMITED** - all backups kept indefinitely" "3066993" "" ""
else
    log "Pruning old backups..."
    PRUNE_OUTPUT=""
    SNAPSHOTS_REMOVED=0
    
    if [ "$RETENTION_METHOD" = "time" ]; then
        log "Using time-based retention: keeping backups within $KEEP_WITHIN"
        PRUNE_OUTPUT=$(restic forget --keep-within "$KEEP_WITHIN" --prune 2>&1)
        SNAPSHOTS_REMOVED=$(echo "$PRUNE_OUTPUT" | grep -oP '\d+(?= snapshots have been removed)' || echo "0")
        log "Pruning complete. Kept all backups within $KEEP_WITHIN."
    elif [ "$RETENTION_METHOD" = "simple" ]; then
        log "Using simple retention: keeping last $KEEP_LAST backups"
        PRUNE_OUTPUT=$(restic forget --keep-last "$KEEP_LAST" --prune 2>&1)
        SNAPSHOTS_REMOVED=$(echo "$PRUNE_OUTPUT" | grep -oP '\d+(?= snapshots have been removed)' || echo "0")
        log "Pruning complete. Kept last $KEEP_LAST backups."
    elif [ "$RETENTION_METHOD" = "count" ]; then
        log "Using count-based retention: daily=$KEEP_DAILY, weekly=$KEEP_WEEKLY, monthly=$KEEP_MONTHLY, yearly=$KEEP_YEARLY"
        PRUNE_OUTPUT=$(restic forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --keep-yearly "$KEEP_YEARLY" --prune 2>&1)
        SNAPSHOTS_REMOVED=$(echo "$PRUNE_OUTPUT" | grep -oP '\d+(?= snapshots have been removed)' || echo "0")
        log "Pruning complete. Kept $KEEP_DAILY daily, $KEEP_WEEKLY weekly, $KEEP_MONTHLY monthly, $KEEP_YEARLY yearly backups."
    fi
    
    if [ "$SNAPSHOTS_REMOVED" -gt 0 ]; then
        REMOVED_FIELD=",{\"name\": \"🗑️ Removed\", \"value\": \"$SNAPSHOTS_REMOVED snapshots\", \"inline\": true}"
        POLICY_FIELD=",{\"name\": \"📋 Policy\", \"value\": \"$RETENTION_METHOD\", \"inline\": true}"
        send_discord_notification "🧹 Pruning Complete" "Old snapshots cleaned up for **$BACKUP_NAME**" "16776960" "" "$REMOVED_FIELD$POLICY_FIELD"
    else
        send_discord_notification "✨ No Pruning Needed" "No old snapshots to remove for **$BACKUP_NAME**" "3447003" "" ""
    fi
fi

log "Verifying repository integrity..."
set +e
CHECK_OUTPUT=$(restic check 2>&1)
CHECK_EXIT_CODE=$?
set -e

if [ $CHECK_EXIT_CODE -eq 0 ]; then
    log "Repository verification successful."
    send_discord_notification "🔒 Data Integrity Check" "Repository is **healthy** - no issues detected" "5763719" "" ""
else
    log "WARNING: Repository verification found issues. Check logs."
    ERROR_DETAILS=$(echo "$CHECK_OUTPUT" | tail -n 3 | tr '"' "'" | tr '\n' ' ')
    ERROR_FIELD=",{\"name\": \"⚠️ Error Details\", \"value\": \"\`\`\`$ERROR_DETAILS\`\`\`\", \"inline\": false}"
    send_discord_notification "⚠️ Data Integrity WARNING" "Repository verification **FAILED** for **$BACKUP_NAME**. Immediate attention required!" "16744192" "$PING_ON_FAILURE" "$ERROR_FIELD"
fi

log "Backup, prune, and verification complete."
