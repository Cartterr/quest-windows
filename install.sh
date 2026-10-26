#!/bin/sh
# Quest Windows: every macOS window as its own floating panel on a Meta Quest (WebXR in Quest Browser).
# Run on the Mac from this folder: sh install.sh. Rerunning rebuilds qwd and restarts the server.
# The app bundle is built only once: macOS ties the Screen Recording and Accessibility grants to it,
# and qwd/server.py inherit them as its children, so they can change freely.
set -e
cd "$(dirname "$0")"
DIR=$PWD
APP="$HOME/Applications/QuestWindows.app"
LABEL=com.carter.questwindows
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

swiftc -O -swift-version 5 qwd.swift -o qwd
[ -f token ] || openssl rand -hex 16 > token
[ -f key.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Quest Windows" \
  -keyout key.pem -out cert.pem 2>/dev/null

if [ ! -d "$APP" ]; then
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>QuestWindows</string>
  <key>CFBundleExecutable</key><string>QuestWindows</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
  cat > /tmp/qw-launcher.c <<'EOF'
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
int main(void) {
    char *argv[] = {"/usr/bin/python3", SERVER, 0};
    pid_t pid;
    int status = 1;
    if (posix_spawn(&pid, argv[0], 0, 0, argv, environ) == 0) waitpid(pid, &status, 0);
    return status != 0;
}
EOF
  clang -O2 -DSERVER="\"$DIR/server.py\"" /tmp/qw-launcher.c -o "$APP/Contents/MacOS/QuestWindows"
  codesign --force -s - "$APP"
fi

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/QuestWindows</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$DIR/server.log</string>
  <key>StandardErrorPath</key><string>$DIR/server.log</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "Open in Quest Browser: https://$(ipconfig getifaddr en0):8443/$(cat token)/"
