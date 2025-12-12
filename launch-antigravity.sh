#!/bin/bash

# Output all logging to stdout/stderr for Cloud Logging
echo "Launching Antigravity GUI application..." 

export PORT=8080

# We run this as 'user' (UID 1000) so it has access to your home directory.
# Use setsid to run in a new session, detached from the current shell.
setsid /usr/bin/antigravity > /dev/null 2>&1 &
    
ANTIGRAVITY_PID=$!
echo "Antigravity process launched with PID: $ANTIGRAVITY_PID" 
echo "Antigravity launch command issued (if still running, PID: $ANTIGRAVITY_PID)."