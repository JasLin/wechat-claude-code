#!/bin/bash
set -euo pipefail

DATA_DIR="${HOME}/.wechat-claude-code"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Platform detection
detect_os() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)  echo "linux" ;;
    *)       echo "unknown" ;;
  esac
}

OS="$(detect_os)"

# Platform-specific configurations
case "$OS" in
  macos)
    PLIST_LABEL="com.wechat-claude-code.bridge"
    PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

    is_loaded() {
      launchctl print gui/$(id -u)/"${PLIST_LABEL}" &>/dev/null
    }
    ;;
  linux)
    SERVICE_LABEL="wechat-claude-code"
    SERVICE_PATH="${HOME}/.config/systemd/user/${SERVICE_LABEL}.service"

    is_loaded() {
      systemctl --user is-active "${SERVICE_LABEL}" >/dev/null 2>&1 || \
      systemctl --user is-enabled "${SERVICE_LABEL}" >/dev/null 2>&1
    }
    ;;
  *)
    echo "Unsupported operating system: $(uname -s)"
    exit 1
    ;;
esac

case "$1" in
  start)
    if is_loaded; then
      echo "Already running (or service loaded)"
      exit 0
    fi

    mkdir -p "$DATA_DIR/logs"
    NODE_BIN="$(command -v node || echo '/usr/local/bin/node')"

    case "$OS" in
      macos)
        cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${PROJECT_DIR}/dist/main.js</string>
    <string>start</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${PROJECT_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${DATA_DIR}/logs/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${DATA_DIR}/logs/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${NODE_BIN%/*}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
        launchctl load "$PLIST_PATH"
        echo "Started wechat-claude-code daemon (macOS launchd)"
        ;;
      linux)
        mkdir -p "${HOME}/.config/systemd/user"
        cat > "$SERVICE_PATH" <<SERVICE
[Unit]
Description=WeChat Claude Code Bridge
After=network.target

[Service]
Type=simple
WorkingDirectory=${PROJECT_DIR}
ExecStart=${NODE_BIN} ${PROJECT_DIR}/dist/main.js start
Restart=always
RestartSec=10
StandardOutput=append:${DATA_DIR}/logs/stdout.log
StandardError=append:${DATA_DIR}/logs/stderr.log
Environment=PATH=${NODE_BIN%/*}:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SERVICE
        systemctl --user daemon-reload
        systemctl --user start "${SERVICE_LABEL}"
        systemctl --user enable "${SERVICE_LABEL}"
        echo "Started wechat-claude-code daemon (systemd user service)"
        echo "Note: To ensure the service runs after logout, run:"
        echo "  loginctl enable-linger \$USER"
        ;;
    esac
    ;;

  stop)
    case "$OS" in
      macos)
        launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "Stopped wechat-claude-code daemon (macOS)"
        ;;
      linux)
        systemctl --user stop "${SERVICE_LABEL}" 2>/dev/null || true
        systemctl --user disable "${SERVICE_LABEL}" 2>/dev/null || true
        rm -f "$SERVICE_PATH"
        systemctl --user daemon-reload
        echo "Stopped wechat-claude-code daemon (Linux systemd)"
        ;;
    esac
    ;;

  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;

  status)
    case "$OS" in
      macos)
        if is_loaded; then
          pid=$(pgrep -f "dist/main.js start" 2>/dev/null | head -1)
          if [ -n "$pid" ]; then
            echo "Running (PID: $pid)"
          else
            echo "Loaded but not running"
          fi
        else
          echo "Not running"
        fi
        ;;
      linux)
        if systemctl --user is-active "${SERVICE_LABEL}" >/dev/null 2>&1; then
          pid=$(systemctl --user show -p MainPID --value "${SERVICE_LABEL}")
          if [ "$pid" -ne 0 ]; then
            echo "Running (PID: $pid)"
          else
            echo "Service active but no PID"
          fi
        elif systemctl --user is-enabled "${SERVICE_LABEL}" >/dev/null 2>&1; then
          echo "Enabled but not running"
        else
          echo "Not running"
        fi
        ;;
    esac
    ;;

  logs)
    LOG_DIR="${DATA_DIR}/logs"
    if [ -d "$LOG_DIR" ]; then
      latest=$(ls -t "${LOG_DIR}"/bridge-*.log 2>/dev/null | head -1)
      if [ -n "$latest" ]; then
        tail -100 "$latest"
      else
        echo "No bridge logs found. Checking stdout/stderr:"
        for f in "${LOG_DIR}"/stdout.log "${LOG_DIR}"/stderr.log; do
          if [ -f "$f" ]; then
            echo "=== $(basename "$f") ==="
            tail -30 "$f"
          fi
        done
      fi
    else
      echo "No logs found"
    fi
    ;;

  *)
    echo "Usage: daemon.sh {start|stop|restart|status|logs}"
    echo "Platform: $OS"
    ;;
esac
