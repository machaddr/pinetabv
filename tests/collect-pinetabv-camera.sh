#!/usr/bin/env bash
# Read-only camera inventory; never probe I2C addresses, select inputs or stream.
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export LC_ALL=C

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: sudo /usr/local/sbin/pinetabv-camera-report > camera-report.txt
       sudo bash tests/collect-pinetabv-camera.sh > camera-report.txt

Collect sensor driver bindings, firmware descriptions, pending V4L2 async
devices, media links, video formats and camera-related kernel/session errors.
No capture is started, input selected, I2C bus scanned or LED switched on.
The white GPIO55 LED is a flash; its state does not prove a working stream.
Run without sudo as well to include the current user's PipeWire camera graph.
EOF
    exit 0
    ;;
  '') ;;
  *) printf 'Usage: pinetabv-camera-report > camera-report.txt\n' >&2; exit 2 ;;
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
run lsmod
printf '\nSensor firmware descriptions and I2C driver bindings:\n'
for device in /sys/bus/i2c/devices/*; do
  [[ -r "${device}/of_node/compatible" ]] || continue
  compatible="$(tr '\0' ' ' < "${device}/of_node/compatible")"
  case "${compatible}" in
    *gc02m2*|*ov5640*|*ov5648*) ;;
    *) continue ;;
  esac
  printf '\n%s compatible=%s\n' "${device##*/}" "${compatible}"
  if [[ -L "${device}/driver" ]]; then
    run readlink -f "${device}/driver"
  else
    printf 'UNBOUND: this declared sensor did not bind to a driver.\n'
  fi
  for field in name modalias power/runtime_status power/runtime_usage; do
    [[ ! -r "${device}/${field}" ]] || run cat "${device}/${field}"
  done
done

printf '\nAsync sensor dependencies (when debugfs is already mounted/readable):\n'
run cat /sys/kernel/debug/v4l2-async/pending_async_subdevices
run cat /sys/kernel/debug/devices_deferred

shopt -s nullglob
for device in /dev/media*; do
  run media-ctl --device "${device}" --print-topology
done
for entry in /sys/class/video4linux/video*; do
  [[ -r "${entry}/name" ]] || continue
  name="$(<"${entry}/name")"
  case "${name}" in
    capture_yuv|capture_raw) ;;
    *) continue ;;
  esac
  device="/dev/${entry##*/}"
  run udevadm info --query=property --name "${device}"
  run v4l2-ctl --device "${device}" --all
  run v4l2-ctl --device "${device}" --list-inputs
  run v4l2-ctl --device "${device}" --list-formats-ext
done
run ls -l /dev/pinetabv-camera /dev/pinetabv-camera-raw
printf '\nFlash LED class device (not a recording indicator):\n'
for entry in /sys/class/leds/*flash*; do
  for field in brightness max_brightness trigger; do
    [[ ! -r "${entry}/${field}" ]] || run cat "${entry}/${field}"
  done
done

if (( EUID != 0 )); then
  run wpctl status
  run pw-dump
  run journalctl --user --boot --no-pager --lines=120 \
    --unit=wireplumber.service --unit=pipewire.service
else
  printf '\nRun this report as the desktop user too for PipeWire/session state.\n'
fi
printf '\nCamera kernel messages:\n'
if command -v dmesg >/dev/null 2>&1; then
  dmesg --color=never 2>&1 | \
    grep -Ei 'gc02|ov564|camera|camss|csi2|dphy|defer|12060000|19800000|19840000|19870000|permission denied|operation not permitted' || true
fi
