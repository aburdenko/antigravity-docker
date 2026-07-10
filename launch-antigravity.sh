#!/bin/bash

# Output all logging to stdout/stderr for Cloud Logging
echo "Launching Antigravity GUI application..." 

export PORT=8080

# Ensure DISPLAY is set for Chrome Remote Desktop X11 session (defaults to :20)
if [ -z "$DISPLAY" ]; then
    X_SOCKET=$(ls /tmp/.X11-unix/X* 2>/dev/null | head -n 1)
    if [ -n "$X_SOCKET" ]; then
        export DISPLAY=":${X_SOCKET#/tmp/.X11-unix/X}"
    else
        export DISPLAY=":20"
    fi
fi
echo "Using X11 DISPLAY=$DISPLAY"

# We run this as 'user' (UID 1000) so it has access to your home directory.
# Use setsid to run in a new session, detached from the current shell.
setsid /usr/bin/antigravity > /dev/null 2>&1 &
    
ANTIGRAVITY_PID=$!
echo "Antigravity process launched with PID: $ANTIGRAVITY_PID" 
echo "Antigravity launch command issued (if still running, PID: $ANTIGRAVITY_PID)."