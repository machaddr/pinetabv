#!/usr/bin/env bash
# Read-only evidence for keyboard-cover detection and GNOME Settings crashes.
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export LC_ALL=C

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: /usr/local/sbin/pinetabv-input-report > input-report.txt
       bash tests/collect-pinetabv-input.sh > input-report.txt

Run from the tablet's desktop terminal after reproducing the Settings crash.
The report includes touchpad capabilities, settings, recent GNOME errors and
existing coredump metadata/backtraces. It does not open input-event streams,
launch Settings, change settings, or extract a process memory dump. Commands
that need additional permissions report their errors and collection continues.
EOF
    exit 0
    ;;
  '') ;;
  *) printf 'Usage: pinetabv-input-report > input-report.txt\n' >&2; exit 2 ;;
esac

run() {
  local status
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Command not installed: %s\n' "$1"
    return 0
  fi
  timeout --kill-after=2s 15 "$@" 2>&1
  status=$?
  if (( status != 0 )); then
    printf '[exit status %s]\n' "${status}"
  fi
  return 0
}

run date --iso-8601=seconds
run uname -a
run id
run free -h
printf '\nDesktop environment\n'
for variable in XDG_SESSION_TYPE XDG_CURRENT_DESKTOP GDK_BACKEND GSK_RENDERER GTK_MEDIA; do
  printf '%s=%s\n' "${variable}" "${!variable-}"
done
run cat /proc/device-tree/model
printf '\nDevice Tree compatible strings\n'
if [[ -r /proc/device-tree/compatible ]]; then
  tr '\0' '\n' < /proc/device-tree/compatible
fi
run cat /proc/bus/input/devices
run cat /etc/libinput/local-overrides.quirks
run cat /usr/local/bin/gnome-control-center
run cat /usr/local/share/dbus-1/services/org.gnome.Settings.service
run grep -E '^(Name|Exec|DBusActivatable)=' \
  /usr/share/applications/org.gnome.Settings.desktop \
  /usr/share/applications/gnome-mouse-panel.desktop
run libinput --version
run libinput quirks validate
run libinput list-devices

# Restrict per-device inspection to the keyboard cover and the Goodix screen.
# Reading the udev database and capability files never reads typed input.
for event in /sys/class/input/event*; do
  [[ -r "${event}/device/name" ]] || continue
  name="$(<"${event}/device/name")"
  case "${name}" in
    'HID 1018:1006'*|*Goodix*) ;;
    *) continue ;;
  esac
  run udevadm info --query=property --path="${event}"
  run libinput quirks list "/dev/input/${event##*/}"
  run cat "${event}/device/properties" "${event}/device/capabilities/ev" \
    "${event}/device/capabilities/key" "${event}/device/capabilities/abs"
done

if (( EUID == 0 )); then
  printf '\nRun this report from the affected desktop account to include its GNOME settings.\n'
else
  run gsettings list-recursively org.gnome.desktop.peripherals.touchpad
  run gsettings list-recursively org.gnome.desktop.peripherals.mouse
  run journalctl --user --boot --no-pager --lines=120 \
    --grep='gnome-control-center|libinput|touchpad|segfault|out of memory|oom-kill'
fi
run gnome-control-center --version
run dpkg-query --show --showformat='${binary:Package} ${Version}\n' \
  gnome-control-center gnome-control-center-data gnome-shell mutter \
  libinput10 libgtk-4-1 libgtk-4-media-gstreamer libadwaita-1-0 mesa-vulkan-drivers
run journalctl --boot --no-pager --lines=120 \
  --grep='gnome-control-center|libinput|touchpad|segfault|out of memory|oom-kill'
run coredumpctl --no-pager --since=-7days list gnome-control-center
run coredumpctl --no-pager -1 info gnome-control-center
cat <<'EOF'

If Settings still closes, quit Settings and run this from the desktop terminal,
then include the terminal output with this report:
  GSK_RENDERER=cairo GTK_MEDIA=none /usr/bin/gnome-control-center mouse
This selects the compatibility rendering path directly. This report does not
start it automatically because opening a GUI requires an interactive session.
EOF
