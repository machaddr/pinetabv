#!/usr/bin/env bash
# Read-only evidence for a lit but blank PineTab-V display.
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export LC_ALL=C

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: sudo pinetabv-display-report > display-report.txt
       sudo bash tests/collect-pinetabv-display.sh > display-report.txt

Run over UART or SSH while the screen is blank. Collect the current boot's
kernel/display-manager logs, DRM state and backlight readings. This does not
restart the desktop, change a display mode, or alter brightness or clocks.
Debugfs data is included only when debugfs is already mounted and readable.
EOF
    exit 0
    ;;
  '') ;;
  *) printf 'Usage: sudo pinetabv-display-report > display-report.txt\n' >&2; exit 2 ;;
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
run cat /proc/cmdline
run dpkg-query --show '--showformat=${binary:Package} ${Version}\n' \
  linux-image-7.3.0-pinetabv pinetabv-hardware-support
run systemctl show --property=LoadState,ActiveState,SubState,Result,ExecMainStatus \
  display-manager.service gdm3.service
run loginctl list-sessions --no-legend

for card in /sys/class/drm/card[0-9]*; do
  [[ -e "${card}" && "${card##*/}" != *-* ]] || continue
  run readlink -f "${card}/device/driver"
done
for connector in /sys/class/drm/card*-*; do
  [[ -d "${connector}" ]] || continue
  for field in status enabled modes; do
    [[ -r "${connector}/${field}" ]] && run cat "${connector}/${field}"
  done
done
for backlight in /sys/class/backlight/*; do
  [[ -d "${backlight}" ]] || continue
  for field in brightness actual_brightness max_brightness bl_power; do
    [[ -r "${backlight}/${field}" ]] && run cat "${backlight}/${field}"
  done
done
for state in /sys/kernel/debug/dri/*/state /sys/kernel/debug/clk/clk_summary; do
  [[ -r "${state}" ]] && run cat "${state}"
done

run journalctl --boot --no-pager --lines=160 \
  --unit=display-manager.service --unit=gdm3.service
run journalctl --boot --no-pager --lines=160 \
  --grep='drm|DSI|D-PHY|panel|vout|gnome-shell|mutter|gdm|GPU|powervr'
run dmesg --color=never
