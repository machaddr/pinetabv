#!/usr/bin/env bash
# Capture and classify the real PineTab-V UART console at 115200 8N1.

set -Eeuo pipefail
umask 077
export LC_ALL=C

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

UART_DEVICE="${UART_DEVICE:-}"
IMAGE_FILE="${IMAGE_FILE:-}"
DISTRO="${DISTRO:-debian}"
EXPECTED_KERNEL_RELEASE="${EXPECTED_KERNEL_RELEASE:-7.3.0-pinetabv}"
EXPECTED_DTB="${EXPECTED_DTB:-jh7110-pine64-pinetab-v-20240730.dtb}"
LOG_DIR="${LOG_DIR:-}"
ANALYZE_FILE=""
PRINT_COMMANDS_ONLY=false

usage() {
  cat <<'EOF'
Usage: capture-pinetabv-uart.sh [options]

Open an interactive, logged 115200 8N1 console to a physical PineTab-V.
Normal keystrokes go to U-Boot/Linux; press Ctrl-] to leave the capture.

Options:
  --device PATH        Serial device (auto-detected when exactly one exists)
  --distro NAME        Image family: debian or auto (default: debian)
  --image PATH         Image used to derive PARTUUID/DTB diagnostic commands
                       (default: project-root/pinetabv-debian.img)
  --kernel-release REL Expected kernel release (default: 7.3.0-pinetabv)
  --dtb FILE           Expected default DTB basename (2024-07-30 by default)
  --log-dir PATH       Output directory (default: work-pinetabv-debian/logs)
  --analyze LOG        Classify an existing UART log without opening a device
  --print-commands     Print safe manual U-Boot diagnostic commands and exit
  -h, --help           Show this help

Environment equivalents:
  UART_DEVICE, DISTRO, IMAGE_FILE, EXPECTED_KERNEL_RELEASE, EXPECTED_DTB,
  LOG_DIR

Hardware connection:
  Insert the Pine64 UART adapter face-up into the USB 2.0 Type-C port (the
  port furthest from the power button). Connect the adapter's DEBUG port to
  this host, start this script, and then power on or reset the tablet.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

need_option_value() {
  [[ $# -ge 2 ]] || die "Option $1 requires a value."
  [[ -n "$2" ]] || die "Option $1 requires a non-empty value."
}

while (($#)); do
  case "$1" in
    --device)
      need_option_value "$@"
      UART_DEVICE="$2"
      shift 2
      ;;
    --distro)
      need_option_value "$@"
      DISTRO="${2,,}"
      shift 2
      ;;
    --image)
      need_option_value "$@"
      IMAGE_FILE="$2"
      shift 2
      ;;
    --kernel-release)
      need_option_value "$@"
      EXPECTED_KERNEL_RELEASE="$2"
      shift 2
      ;;
    --dtb)
      need_option_value "$@"
      EXPECTED_DTB="$2"
      shift 2
      ;;
    --log-dir)
      need_option_value "$@"
      LOG_DIR="$2"
      shift 2
      ;;
    --analyze)
      need_option_value "$@"
      ANALYZE_FILE="$2"
      shift 2
      ;;
    --print-commands)
      PRINT_COMMANDS_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 0)) || die "Unexpected positional argument: $1"
      ;;
    *)
      die "Unknown option: $1 (try --help)"
      ;;
  esac
done

case "$DISTRO" in
  auto|debian) ;;
  *) die "--distro must be debian or auto." ;;
esac
[[ "$EXPECTED_KERNEL_RELEASE" =~ ^[A-Za-z0-9._+-]+$ ]] || \
  die "--kernel-release contains unsafe characters: $EXPECTED_KERNEL_RELEASE"
[[ "$EXPECTED_DTB" =~ ^[A-Za-z0-9._+-]+\.dtb$ ]] || \
  die "--dtb must be a safe DTB basename."

clean_uart_log() {
  local input_file="$1"
  local output_file="$2"

  # Remove CSI/OSC terminal control sequences and CRs while retaining every
  # printable kernel message.  The raw capture is always kept separately.
  sed -E \
    -e $'s/\x1B\[[0-?]*[ -\/]*[@-~]//g' \
    -e $'s/\x1B\][^\a]*\a//g' \
    -e $'s/\x1B\][^\x1B]*\x1B\\\\//g' \
    -e $'s/\x1BP[^\x1B]*\x1B\\\\//g' \
    -e $'s/\x1B[78]//g' \
    "$input_file" | tr -d '\r' > "$output_file"
}

analyze_uart_log() {
  local log_file="$1"
  local log_distro="$DISTRO"
  local expected_model=""
  local exact_kernel=false
  local kernel_seen=false
  local correct_dtb=false
  local root_seen=false
  local userspace_seen=false
  local drm_seen=false
  local display_failure=false
  local audio_failure=false
  local battery_failure=false
  local camera_failure=false
  local kernel_fault=false
  local spurious_acpi_dsm=false
  local sd_controller_failure=false
  local root_wait=false

  [[ -r "$log_file" ]] || die "UART log is not readable: $log_file"

  case "$EXPECTED_DTB" in
    jh7110-pine64-pinetab-v-20240730.dtb)
      expected_model='Pine64 PineTab-V (2024-07-30)'
      ;;
    jh7110-pine64-pinetab-v-20230614.dtb)
      expected_model='Pine64 PineTab-V (2023-06-14)'
      ;;
    *)
      expected_model='Pine64 PineTab-V'
      ;;
  esac

  if [[ "$log_distro" == auto ]]; then
    if grep -Eqi 'Debian GNU/Linux|PineTab-V Debian|label debian' "$log_file"; then
      log_distro=debian
    else
      log_distro=unknown
    fi
  fi

  grep -Eq 'Linux version ' "$log_file" && kernel_seen=true
  grep -Fq "Linux version ${EXPECTED_KERNEL_RELEASE} (" "$log_file" && exact_kernel=true
  grep -Fq "Machine model: ${expected_model}" "$log_file" && correct_dtb=true
  grep -Eq 'VFS: Mounted root|EXT4-fs .* mounted filesystem|Run /sbin/init' "$log_file" && root_seen=true
  grep -Eq 'Started Serial Getty on ttyS0|Reached target .*Login Prompts|This is pinetabv|Debian GNU/Linux .* ttyS0|(^|[[:space:]])pinetabv[^[:space:]]* login:' "$log_file" && userspace_seen=true
  grep -Eqi '\[drm\] Initialized (starfive|verisilicon)|starfive[-_ ]?drm.*(initialized|bound)|verisilicon.*bound|fb0:.*drm' "$log_file" && drm_seen=true
  grep -Eqi \
    'MIPI D-PHY TX PLL failed to lock|DSI-DPhy Clock and Data Lanes not ready|primary plane [0-9]+ FIFO underflow|video stream error 0x[0-9a-f]+|failed to prepare DSI link|failed to initialize DSI PHY|Cannot get downstream bridge|Cannot attach bridge|drm.*(timeout|failed)|dsi.*(timeout|failed)|panel.*(timeout|failed)|(^|[[:space:]])BUG:|Kernel panic' \
    "$log_file" && display_failure=true
  grep -Eqi \
    'designware-i2s .*failed with error -110|platform sound:.*(parse error|failed)|asoc-soundcard:.*(parse error|failed)' \
    "$log_file" && audio_failure=true
  grep -Eqi \
    'CW2015: failed to register power supply|cw2015.*(probe|register|failed|error)|bq25890.*(probe|register|failed|error)|sc89890.*(probe|register|failed|error)' \
    "$log_file" && battery_failure=true
  grep -Eqi \
    '(ov5640|gc02m2|starfive.*camss|stf[-_ ]?camss|csi2rx).*(probe failed|failed with error|timeout|Failed to media_pipeline_start|stream on failed|capture/source format mismatch)' \
    "$log_file" && camera_failure=true
  grep -Eqi 'Unable to handle kernel NULL pointer|Oops \[#|(^|[[:space:]])BUG:|Kernel panic' \
    "$log_file" && kernel_fault=true
  grep -Eqi 'ACPI: </na>: failed to evaluate _DSM|failed to evaluate _DSM.*0x1001' \
    "$log_file" && spurious_acpi_dsm=true
  grep -Eqi \
    'pin GPIO41 already requested.*16020000\.mmc|dwmmc_starfive 16020000\.mmc:.*failed with error -22' \
    "$log_file" && sd_controller_failure=true
  grep -Eq 'Waiting for root device ' "$log_file" && root_wait=true

  printf '%s\n' 'PineTab-V UART diagnosis'
  printf '  Distribution: %s\n' "$log_distro"
  printf '  Firmware UART: %s\n' "$(grep -Eq 'OpenSBI|U-Boot' "$log_file" && printf PASS || printf MISSING)"
  printf '  Kernel entered: %s\n' "$([[ "$kernel_seen" == true ]] && printf PASS || printf MISSING)"
  printf '  Exact %s kernel: %s\n' "$EXPECTED_KERNEL_RELEASE" "$([[ "$exact_kernel" == true ]] && printf PASS || printf MISSING)"
  printf '  Expected PineTab-V DTB (%s): %s\n' "$EXPECTED_DTB" "$([[ "$correct_dtb" == true ]] && printf PASS || printf MISSING)"
  printf '  Root filesystem mounted: %s\n' "$([[ "$root_seen" == true ]] && printf PASS || printf MISSING)"
  printf '  Userspace/login reached: %s\n' "$([[ "$userspace_seen" == true ]] && printf PASS || printf MISSING)"
  printf '  DRM/framebuffer marker: %s\n' "$([[ "$drm_seen" == true ]] && printf PASS || printf MISSING)"
  printf '  Display/DSI fatal marker: %s\n' "$([[ "$display_failure" == true ]] && printf FOUND || printf none-seen)"
  printf '  I2S/sound-card fatal marker: %s\n' "$([[ "$audio_failure" == true ]] && printf FOUND || printf none-seen)"
  printf '  Charger/battery fatal marker: %s\n' "$([[ "$battery_failure" == true ]] && printf FOUND || printf none-seen)"
  printf '  Camera-pipeline fatal marker: %s\n' "$([[ "$camera_failure" == true ]] && printf FOUND || printf none-seen)"
  printf '  Kernel crash marker: %s\n' "$([[ "$kernel_fault" == true ]] && printf FOUND || printf none-seen)"
  printf '  Spurious rtw89 ACPI _DSM marker: %s\n' "$([[ "$spurious_acpi_dsm" == true ]] && printf FOUND || printf none-seen)"
  printf '  microSD controller failure: %s\n' "$([[ "$sd_controller_failure" == true ]] && printf FOUND || printf none-seen)"
  printf '  Waiting indefinitely for root: %s\n' "$([[ "$root_wait" == true ]] && printf YES || printf no)"

  if [[ "$sd_controller_failure" == true && "$root_wait" == true ]]; then
    printf '%s\n' '  Conclusion: GPIO41 ownership prevents the SD controller probing, so the SD root device cannot appear.'
  elif [[ "$userspace_seen" == true && "$drm_seen" == true ]]; then
    printf '%s\n' '  Conclusion: Linux/userspace boot and DRM initializes; inspect the hardware-specific markers above.'
  elif [[ "$root_seen" == true ]]; then
    printf '%s\n' '  Conclusion: kernel/rootfs boot; inspect the DRM/DSI probe messages below.'
  elif [[ "$kernel_seen" == true ]]; then
    printf '%s\n' '  Conclusion: firmware handed off to Linux; failure is before the root/login stage.'
  elif grep -Eq 'OpenSBI|U-Boot' "$log_file"; then
    printf '%s\n' '  Conclusion: firmware runs, but the captured log does not show Linux entry.'
  else
    printf '%s\n' '  Conclusion: no boot banner; check adapter orientation, DEBUG cable, device, permissions, and power.'
  fi

  printf '%s\n' '  Relevant warnings/errors (last 60):'
  if ! grep -Eai \
    'Linux version|Machine model|OpenSBI|U-Boot|drm|dsi|dphy|display|panel|backlight|deferred|timeout|failed|error|warning|(^|[[:space:]])BUG:|panic|VFS: Mounted root|Run /sbin/init|login:' \
    "$log_file" | tail -n 60 | sed 's/^/    /'; then
    printf '%s\n' '    (none)'
  fi
}

if [[ -n "$ANALYZE_FILE" ]]; then
  [[ "$PRINT_COMMANDS_ONLY" == false ]] || die "--analyze and --print-commands cannot be combined."
  [[ -f "$ANALYZE_FILE" ]] || die "UART log not found: $ANALYZE_FILE"
  temporary_clean="$(mktemp -t pinetabv-uart-clean.XXXXXXXX)"
  trap 'rm -f -- "$temporary_clean"' EXIT
  clean_uart_log "$ANALYZE_FILE" "$temporary_clean"
  analyze_uart_log "$temporary_clean"
  exit 0
fi

if [[ -z "$IMAGE_FILE" ]]; then
  IMAGE_FILE="${PROJECT_DIR}/pinetabv-debian.img"
fi

require_command sgdisk
require_command mtype
[[ -f "$IMAGE_FILE" ]] || die "Image not found; cannot derive safe U-Boot commands: $IMAGE_FILE"
[[ -r "$IMAGE_FILE" ]] || die "Image is not readable: $IMAGE_FILE"
IMAGE_FILE="$(readlink -f -- "$IMAGE_FILE")"

root_partuuid="$({
  sgdisk -i 4 "$IMAGE_FILE" 2>/dev/null || true
} | awk -F ': *' '/Partition unique GUID:/ { print tolower($2); exit }')"
boot_first_sector="$({
  sgdisk -i 3 "$IMAGE_FILE" 2>/dev/null || true
} | awk -F ': *' '/First sector:/ { print $2; exit }' | awk '{ print $1 }')"
[[ "$root_partuuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || \
  die "Could not derive the root PARTUUID from image GPT partition 4."
[[ "$boot_first_sector" =~ ^[0-9]+$ ]] || \
  die "Could not derive the boot offset from image GPT partition 3."

boot_offset_bytes=$((boot_first_sector * 512))
extlinux_conf="$(MTOOLS_SKIP_CHECK=1 mtype -i "${IMAGE_FILE}@@${boot_offset_bytes}" ::/extlinux/extlinux.conf 2>/dev/null || true)"
[[ -n "$extlinux_conf" ]] || die "Could not read /extlinux/extlinux.conf from image partition 3."

DISTRO=debian
if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="${PROJECT_DIR}/work-pinetabv-debian/logs"
fi

default_label="$(awk 'tolower($1) == "default" { print $2; exit }' <<< "$extlinux_conf")"
[[ "$default_label" == debian ]] || \
  die "The image's extlinux configuration must default to debian."
default_dtb="$(awk -v want="$default_label" '
  BEGIN { want = tolower(want) }
  tolower($1) == "label" { selected = (tolower($2) == want) }
  selected && tolower($1) == "fdt" { sub(".*/", "", $2); print $2; exit }
' <<< "$extlinux_conf")"
diagnostic_label="$(awk '
  tolower($1) == "label" && tolower($2) ~ /(^|-)diagnostics$/ { print $2; exit }
' <<< "$extlinux_conf")"
diagnostic_cmdline="$(awk -v want="$diagnostic_label" '
  BEGIN { want = tolower(want) }
  tolower($1) == "label" { diagnostic = (tolower($2) == want) }
  diagnostic && tolower($1) == "append" { sub(/^[[:space:]]*append[[:space:]]+/, ""); print; exit }
' <<< "$extlinux_conf")"
[[ "$default_dtb" == "$EXPECTED_DTB" ]] || \
  die "The image defaults to ${default_dtb:-no DTB}, not $EXPECTED_DTB."
[[ "$diagnostic_label" =~ ^[A-Za-z0-9._+-]+$ ]] || \
  die "The image has no safe *-diagnostics extlinux label."
[[ "$diagnostic_cmdline" == *"root=PARTUUID=${root_partuuid}"* && \
   "$diagnostic_cmdline" == *"console=ttyS0,115200"* && \
   "$diagnostic_cmdline" == *"drm.debug="* ]] || \
  die "The image's ${diagnostic_label} entry lacks the matching root PARTUUID, UART console, or drm.debug setting."
[[ "$diagnostic_cmdline" != *"'"* ]] || \
  die "The diagnostic command line contains an unsafe single quote."
metadata_source="$IMAGE_FILE"

print_uboot_commands() {
  cat <<EOF
# Values derived from: ${metadata_source}
# First interrupt autoboot. These commands do not write the SD card or QSPI.
version
mmc list
mmc dev 1
mmc rescan
part list mmc 1
fatls mmc 1:3 /
fatls mmc 1:3 /extlinux
printenv bootmode devnum bootpart fatbootpart bootdev bootcmd boot2 load_vf2_env

# Try the image's extlinux menu (select ${diagnostic_label}):
sysboot mmc 1:3 fat 0xc0000000 /extlinux/extlinux.conf

# Or bypass a stale QSPI environment and manually load the exact SD files:
fatload mmc 1:3 0x40200000 /Image
fatload mmc 1:3 0x46000000 /dtbs/${default_dtb}
fdt addr 0x46000000
fdt print / model
setenv bootargs '${diagnostic_cmdline}'
booti 0x40200000 - 0x46000000

# If "mmc list" assigns the SD card a number other than 1, substitute it above.
# Do not run saveenv; these diagnostics intentionally change RAM state only.
EOF
}

if [[ "$PRINT_COMMANDS_ONLY" == true ]]; then
  print_uboot_commands
  exit 0
fi

require_command script
require_command socat
require_command sed
require_command stty
require_command tr

if [[ -z "$UART_DEVICE" ]]; then
  shopt -s nullglob
  candidate_paths=(/dev/serial/by-id/* /dev/ttyUSB* /dev/ttyACM*)
  shopt -u nullglob
  declare -A seen_devices=()
  devices=()
  for candidate in "${candidate_paths[@]}"; do
    [[ -c "$candidate" ]] || continue
    resolved="$(readlink -f -- "$candidate")"
    [[ -n "$resolved" ]] || continue
    if [[ -z "${seen_devices[$resolved]:-}" ]]; then
      seen_devices[$resolved]=1
      devices+=("$candidate")
    fi
  done

  case "${#devices[@]}" in
    0)
      die "No /dev/serial/by-id, ttyUSB, or ttyACM device found. Connect the UART adapter first."
      ;;
    1)
      UART_DEVICE="${devices[0]}"
      ;;
    *)
      printf '%s\n' 'Multiple serial devices found; select the PineTab-V adapter:' >&2
      printf '  %s\n' "${devices[@]}" >&2
      die "Run again with --device PATH."
      ;;
  esac
fi

[[ -c "$UART_DEVICE" ]] || die "Not a serial character device: $UART_DEVICE"
UART_DEVICE="$(readlink -f -- "$UART_DEVICE")"
if [[ ! -r "$UART_DEVICE" || ! -w "$UART_DEVICE" ]]; then
  device_group="$(stat -c '%G' "$UART_DEVICE" 2>/dev/null || printf unknown)"
  die "No read/write permission for $UART_DEVICE (group: $device_group). Add your user to that group, re-login, and retry; do not run the capture as root."
fi

mkdir -p -- "$LOG_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_base="${LOG_DIR}/pinetabv-${DISTRO}-uart-${timestamp}"
raw_log="${log_base}.raw.log"
clean_log="${log_base}.clean.log"
summary_file="${log_base}.summary.txt"
commands_file="${log_base}.uboot-commands.txt"
for output in "$raw_log" "$clean_log" "$summary_file" "$commands_file"; do
  [[ ! -e "$output" ]] || die "Refusing to overwrite existing output: $output"
done

print_uboot_commands > "$commands_file"

printf '%s\n' \
  '[*] Physical PineTab-V UART capture' \
  "[*] Distribution/image family: $DISTRO" \
  "[*] Image metadata: $IMAGE_FILE" \
  "[*] Device: $UART_DEVICE" \
  '[*] Format: 115200 baud, 8 data bits, no parity, 1 stop bit, no flow control' \
  "[*] Raw log: $raw_log" \
  "[*] Safe U-Boot diagnostics: $commands_file" \
  '[*] Power on/reset the tablet now. Press Ctrl-] to finish.'

if command -v udevadm >/dev/null 2>&1; then
  udevadm info --query=property --name="$UART_DEVICE" 2>/dev/null | \
    grep -E '^(ID_VENDOR=|ID_MODEL=|ID_SERIAL=|DEVNAME=)' | sed 's/^/    /' || true
fi
printf '\n'

# Configure the real serial device before socat opens it.  socat 1.8.1.3 can
# incorrectly leave the device at B0 when its b115200 and rawer termios options
# are combined, despite accepting the command line.  Keeping serial termios out
# of socat also makes the configured baud independently verifiable.
stty -F "$UART_DEVICE" 115200 raw -echo -ixon -ixoff -crtscts \
  cs8 -parenb -cstopb clocal -hupcl
configured_baud="$(stty -F "$UART_DEVICE" speed)"
[[ "$configured_baud" == 115200 ]] || \
  die "Serial device reports ${configured_baud} baud after requesting 115200."

set +e
script -qef -E never -O "$raw_log" -- \
  socat STDIO,rawer,echo=0,escape=0x1d \
  "FILE:${UART_DEVICE}"
capture_status=$?
set -e

[[ -f "$raw_log" ]] || die "Capture exited without creating a UART log."
clean_uart_log "$raw_log" "$clean_log"
analyze_uart_log "$clean_log" | tee "$summary_file"

printf '\n[*] Capture complete.\n'
printf '    Raw:      %s\n' "$raw_log"
printf '    Clean:    %s\n' "$clean_log"
printf '    Summary:  %s\n' "$summary_file"
printf '    Commands: %s\n' "$commands_file"

case "$capture_status" in
  0|130|143)
    exit 0
    ;;
  *)
    die "Serial capture exited unexpectedly with status $capture_status."
    ;;
esac
