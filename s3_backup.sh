#!/bin/bash

set -euo pipefail

ENV_FILE="/path/to/your/.env"
BACKUP_NAME="Your_Backup_Name"
FOLDER_PATH="/path/to/backup"
BACKUP_TAG="tag"
LOG_FILE="/var/log/backup_${BACKUP_NAME}.log"


RETENTION_METHOD="simple"

KEEP_WITHIN="6m"

KEEP_LAST=10

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=1

log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    log "CRITICAL ERROR: Secrets file $ENV_FILE not found!"
    exit 1
fi

log "Starting backup process for $BACKUP_NAME"

REPO_CHECK=$(restic snapshots 2>&1 || true)
if echo "$REPO_CHECK" | grep -q "Is there a repository at the following location"; then
    log "Repository not found. Initializing new repository..."
    if restic init; then
        log "Repository initialized successfully."
    else
        log "Failed to initialize repository."
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

log "Running restic backup..."
set +e
BACKUP_OUTPUT=$(restic backup "$FOLDER_PATH" --tag "$BACKUP_NAME" --tag "$BACKUP_TAG" 2>&1)
BACKUP_EXIT_CODE=$?
set -e

if [ $BACKUP_EXIT_CODE -eq 0 ]; then
    log "Backup successful."
    
    BACKUP_SIZE=$(echo "$BACKUP_OUTPUT" | grep "Added to the repository:" | awk '{print $5, $6}')
    if [ -z "$BACKUP_SIZE" ]; then
        BACKUP_SIZE="N/A"
    fi
    
    SNAPSHOT_COUNT=$(restic snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l || echo "0")
    
    FILES_PROCESSED=$(echo "$BACKUP_OUTPUT" | grep "Files:" | awk '{print $2}')
    if [ -z "$FILES_PROCESSED" ]; then
        FILES_PROCESSED="N/A"
    fi
    
    log "Backup Size: $BACKUP_SIZE"
    log "Total Snapshots: $SNAPSHOT_COUNT"
    log "Files Processed: $FILES_PROCESSED"
else
    log "BACKUP FAILED."
    exit 1
fi

if [ "$RETENTION_METHOD" = "unlimited" ]; then
    log "Retention policy set to UNLIMITED - skipping pruning. All backups will be kept indefinitely."
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
    
    log "Snapshots removed: $SNAPSHOTS_REMOVED"
fi

log "Verifying repository integrity..."
set +e
CHECK_OUTPUT=$(restic check --read-data-subset=5% 2>&1)
CHECK_EXIT_CODE=$?
set -e

if [ $CHECK_EXIT_CODE -eq 0 ]; then
    log "Repository verification successful."
else
    log "WARNING: Repository verification found issues. Check logs."
    log "Error details: $CHECK_OUTPUT"
fi

log "Backup, prune, and verification complete."
