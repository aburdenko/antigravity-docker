#!/bin/bash
rm -f /tmp/antigravity-ide.log
touch /tmp/antigravity-ide.log
chmod 666 /tmp/antigravity-ide.log
# Configure Trusted Workspaces for the Antigravity CLI
mkdir -p /home/user/.gemini/antigravity-cli
echo '{"trustedWorkspaces": ["/home/user", "/app"]}' > /home/user/.gemini/antigravity-cli/settings.json
chown -R 1000:1000 /home/user/.gemini
# Auto-mount Google Drive if google-drive-ocamlfuse config exists on persistent storage
if [ -d "/home/user/.gdfuse/default" ]; then
    mkdir -p /home/user/GoogleDrive
    chown -R 1000:1000 /home/user/GoogleDrive
    runuser user -c -l "google-drive-ocamlfuse /home/user/GoogleDrive" &
    # Symlink ~/projects to the projects folder under Google Drive
    if [ -L "/home/user/projects" ]; then
        rm -f "/home/user/projects"
    elif [ -d "/home/user/projects" ]; then
        rmdir "/home/user/projects" 2>/dev/null || true
    fi
    if [ ! -e "/home/user/projects" ]; then
        ln -sf "/home/user/GoogleDrive/My Drive/2026/projects" /home/user/projects
        chown -h 1000:1000 /home/user/projects
    fi
fi
# Ensure XFCE default session for Chrome Remote Desktop
echo "exec /etc/X11/Xsession /usr/bin/xfce4-session" > /home/user/.chrome-remote-desktop-session
chown 1000:1000 /home/user/.chrome-remote-desktop-session
# Start Chrome Remote Desktop if configured
if [ -d "/home/user/.config/chrome-remote-desktop" ]; then
    runuser user -c -l "/opt/google/chrome-remote-desktop/chrome-remote-desktop --start --child-process" &
fi
# Start Code OSS Web IDE on local port 8000
runuser user -c -l "cd /opt/code-oss && ./bin/codeoss-cloudworkstations --port=8000 --host=127.0.0.1 --without-connection-token" &
# Forward external port 80 to Code OSS
socat TCP-LISTEN:80,fork,reuseaddr TCP:127.0.0.1:8000 &
# Start Antigravity Agent 2.0 interface (Jetski language server)
runuser user -c -l "/opt/antigravity-desktop/resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version 2.2.1 --override_user_agent_name antigravity --http_server_port 3030 --csrf_token 'antigravity-csrf-token-123' --app_data_dir antigravity > /tmp/antigravity-ide.log 2>&1 &"
# Start browser injection proxy for standalone browser support on port 8080
runuser user -c -l "nohup node /usr/local/bin/inject_proxy.js >/tmp/inject_proxy.log 2>&1 &"
# Forward external port 8080 to the injection proxy on port 3032
socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:3032 &
