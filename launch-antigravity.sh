#!/bin/bash

# Define log file for debugging
LOG_FILE="/var/log/antigravity.log"
touch "$LOG_FILE"
chown user:user "$LOG_FILE"

echo "Starting Antigravity in Web Server mode..." >> "$LOG_FILE"

MAX_RETRIES=5
RETRY_COUNT=0
ANTIGRAVITY_PID=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Attempting to launch Antigravity (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..." >> "$LOG_FILE"

    # Launch Antigravity using the 'serve-web' subcommand.
    # We run this as 'user' (UID 1000) so it has access to your home directory.
    # Use setsid to run in a new session, detached from the current shell.
    setsid runuser -u "$(id -un 1000)" -- /usr/bin/antigravity serve-web \
        --host 0.0.0.0 \
        --port 80 \
        --without-connection-token \
        --accept-server-license-terms \
        >> "$LOG_FILE" 2>&1 &
    
    ANTIGRAVITY_PID=$!
    echo "Antigravity process launched with PID: $ANTIGRAVITY_PID" >> "$LOG_FILE"

    # Give Antigravity a moment to start and potentially fail
    sleep 5

    # Check if the process is still running
    if ps -p $ANTIGRAVITY_PID > /dev/null; then
        echo "Antigravity launched successfully with PID $ANTIGRAVITY_PID." >> "$LOG_FILE"
        break # Exit loop if successful
    else
        echo "Antigravity failed to launch or exited prematurely. Checking logs for details." >> "$LOG_FILE"
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "Retrying in 10 seconds..." >> "$LOG_FILE"
            sleep 10
        fi
    fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "ERROR: Antigravity failed to launch after $MAX_RETRIES attempts." >> "$LOG_FILE"
    echo "Please check $LOG_FILE for more details." >> "$LOG_FILE"
    exit 1 # Exit with an error code
else
    echo "Antigravity launch command issued (if still running, PID: $ANTIGRAVITY_PID)." >> "$LOG_FILE"
fi