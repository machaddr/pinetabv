#!/usr/bin/env bash
# Collect wireless state without changing radio, connection or module settings.
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export LC_ALL=C

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: sudo /usr/local/sbin/pinetabv-wireless-report > wireless-report.txt
       sudo bash tests/collect-pinetabv-wireless.sh > wireless-report.txt

Collect kernel/USB, firmware, rfkill, NetworkManager and Bluetooth state.
The report uses cached scan results and does not change radio settings,
restart services, reload modules, or read saved Wi-Fi passwords.
EOF
    exit 0
    ;;
  '') ;;
  *) printf 'Usage: sudo /usr/local/sbin/pinetabv-wireless-report > wireless-report.txt\n' >&2; exit 2 ;;
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
run ip -brief link
run lsusb
run lsusb -t
run rfkill list
run nmcli general status
run nmcli radio all
run nmcli --fields DEVICE,TYPE,STATE device status
run nmcli --fields IN-USE,CHAN,SIGNAL,SECURITY device wifi list --rescan no
run iw dev
run iw phy
run iw reg get
run lsmod
run systemctl show --property=LoadState,ActiveState,SubState,Result,ExecMainStatus \
  NetworkManager.service wpa_supplicant.service bluetooth.service
run readlink -f /lib/firmware/regulatory.db
run readlink -f /lib/firmware/regulatory.db.p7s
run ls -l /lib/firmware/regulatory.db* \
  /lib/firmware/rtw89/rtw8852b_fw* /lib/firmware/rtl_bt/rtl8852bu*
run journalctl --boot --no-pager --lines=120 \
  --unit=NetworkManager.service --unit=wpa_supplicant.service --unit=bluetooth.service
run dmesg --color=never
