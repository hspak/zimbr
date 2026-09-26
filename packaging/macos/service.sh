#!/bin/bash
# Manage the packaged relay's per-user LaunchAgent after TLS provisioning.
set -euo pipefail

[[ $# -eq 1 && $1 =~ ^(start|stop|status)$ ]] || {
  echo "Usage: $(basename "$0") {start|stop|status}" >&2; exit 2;
}
[[ $(uname -s) == Darwin && $(id -u) -ne 0 ]] || {
  echo 'Run as the Mac login user, without sudo.' >&2; exit 1;
}
# Homebrew exposes this helper through a symlink in its bin directory.
script=${BASH_SOURCE[0]}
while [[ -L $script ]]; do
  directory=$(cd -- "$(dirname -- "$script")" && pwd)
  script=$(readlink "$script")
  [[ $script == /* ]] || script=$directory/$script
done
contents=$(cd -- "$(dirname -- "$script")/.." && pwd)
binary="$contents/MacOS/relay"
label=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")
data_name=$(/usr/libexec/PlistBuddy -c 'Print :ZimbrDataDirectory' "$contents/Info.plist")
[[ $label == com.hsp.zimbr.relay || $label == com.hsp.zimbr.relay.dev ]] || {
  echo 'Unknown relay app identity.' >&2; exit 1;
}
[[ $data_name != */* && -n $data_name && $data_name != . && $data_name != .. ]] || {
  echo 'Invalid relay data directory.' >&2; exit 1;
}
service="gui/$(id -u)/$label"
agent="$HOME/Library/LaunchAgents/$label.plist"
data="$HOME/Library/Application Support/$data_name"
case "${1:-}" in
  stop) launchctl bootout "$service"; exit ;;
  status) launchctl print "$service"; exit ;;
  start) ;;
esac
"$binary" check-config --config "$data/relay.json"
"$binary" setup --data-dir "$data"
umask 077
mkdir -p "$HOME/Library/LaunchAgents"
[[ ! -L $agent ]] || { echo 'Refusing symlink LaunchAgent.' >&2; exit 1; }

xml() {
  local value=$1
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  printf '%s' "$value"
}
temporary=$(mktemp "$agent.XXXXXXXX")
trap 'rm -f -- "$temporary"' EXIT
cat >"$temporary" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$(xml "$binary")</string><string>serve</string><string>--menu-bar</string><string>--data-dir</string><string>$(xml "$data")</string><string>--config</string><string>$(xml "$data/relay.json")</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>1</integer>
<key>ProcessType</key><string>Standard</string>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>WorkingDirectory</key><string>$(xml "$data")</string>
<key>StandardOutPath</key><string>$(xml "$data/relay.log")</string>
<key>StandardErrorPath</key><string>$(xml "$data/relay.log")</string>
<key>Umask</key><integer>63</integer>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$(xml "$HOME")</string></dict>
</dict></plist>
EOF
plutil -lint "$temporary"
previous=$(launchctl print "$service" 2>/dev/null || true)
pid=
if [[ $previous =~ pid[[:space:]]*=[[:space:]]*([0-9]+) ]]; then pid=${BASH_REMATCH[1]}; fi
if ! launchctl bootout "$service" 2>/dev/null && [[ -n $pid ]]; then
  echo 'Could not stop the previous relay.' >&2; exit 1
fi
if [[ -n $pid ]]; then
  for ((attempt = 0; attempt < 150; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo 'Previous relay has not exited; service left stopped.' >&2; exit 1
  fi
fi
mv -f -- "$temporary" "$agent"
launchctl enable "$service"
launchctl bootstrap "gui/$(id -u)" "$agent"
launchctl print "$service"
