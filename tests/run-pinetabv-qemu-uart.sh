#!/usr/bin/env bash
# Boot a PineTab-V Debian kernel/rootfs on QEMU's RISC-V virt board.
#
# This intentionally does not pass a PineTab-V DTB.  QEMU has no JH7110 or
# PineTab-V machine model, so its generated virt DTB is the only valid DTB for
# this test.  The harness validates the Image, root filesystem, init system,
# and serial console while keeping the source disk image read-only.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

QEMU_BIN="${QEMU_SYSTEM_RISCV64:-qemu-system-riscv64}"
IMAGE_FILE="${IMAGE_FILE:-}"
DISTRO="${DISTRO:-debian}"
EXPECTED_KERNEL_RELEASE="${EXPECTED_KERNEL_RELEASE:-7.3.0-pinetabv}"
EXPECTED_DTB="${EXPECTED_DTB:-jh7110-pine64-pinetab-v-20240730.dtb}"
KERNEL_IMAGE="${KERNEL_IMAGE:-}"
LOG_DIR="${LOG_DIR:-}"
LOG_FILE="${LOG_FILE:-}"
QEMU_CPUS="${QEMU_CPUS:-4}"
QEMU_MEMORY_MB="${QEMU_MEMORY_MB:-2048}"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-0}"
EXTRA_KERNEL_ARGS="${EXTRA_KERNEL_ARGS:-}"
ROOT_PARTITION="${ROOT_PARTITION:-4}"
BOOT_PARTITION="${BOOT_PARTITION:-3}"
log_file_explicit=false

usage() {
  cat <<'EOF'
Usage: run-pinetabv-qemu-uart.sh [options]

Boot the kernel embedded in a PineTab-V Debian image on QEMU's
generic RISC-V "virt" machine and capture ttyS0 in a timestamped log.
The disk is always attached with snapshot=on, so QEMU cannot modify the image.

Options:
  --distro NAME         Image family: debian or auto (default: debian)
  --image PATH          Raw image (default: project-root/pinetabv-debian.img)
  --kernel PATH         Use this Image instead of extracting /Image from p3
  --kernel-release REL  Expected kernel release (default: 7.3.0-pinetabv)
  --dtb FILE            Expected default DTB basename (2024-07-30 by default)
  --log PATH            Console log path (default: work-pinetabv-debian/logs/...)
  --cpus N              Virtual CPUs (default: 4)
  --memory MB           Guest RAM in MiB (default: 2048)
  --timeout SECONDS     Stop automatically after this many seconds (default: 0)
  --extra-append TEXT   Append extra Linux command-line arguments
  -h, --help            Show this help

Environment equivalents:
  QEMU_SYSTEM_RISCV64, DISTRO, IMAGE_FILE, EXPECTED_KERNEL_RELEASE,
  EXPECTED_DTB, KERNEL_IMAGE, LOG_DIR, LOG_FILE, QEMU_CPUS, QEMU_MEMORY_MB,
  QEMU_TIMEOUT, EXTRA_KERNEL_ARGS

Interactive mode runs until the guest powers off or you press Ctrl-C.

Important limitation:
  QEMU virt is not a PineTab-V.  This test covers kernel execution, the GPT
  rootfs, systemd, and a generic 16550 ttyS0.  It cannot exercise the
  PineTab-V SPL/U-Boot path, JH7110 DTB, DC8200, Cadence DSI, M31 D-PHY,
  Jadard panel, PWM backlight, cameras, audio, PMIC, charger, or battery gauge.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

need_option_value() {
  [[ $# -ge 2 ]] || die "Option $1 requires a value."
  [[ -n "$2" ]] || die "Option $1 requires a non-empty value."
}

while (($#)); do
  case "$1" in
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
    --kernel)
      need_option_value "$@"
      KERNEL_IMAGE="$2"
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
    --log)
      need_option_value "$@"
      LOG_FILE="$2"
      log_file_explicit=true
      shift 2
      ;;
    --cpus)
      need_option_value "$@"
      QEMU_CPUS="$2"
      shift 2
      ;;
    --memory)
      need_option_value "$@"
      QEMU_MEMORY_MB="$2"
      shift 2
      ;;
    --timeout)
      need_option_value "$@"
      QEMU_TIMEOUT="$2"
      shift 2
      ;;
    --extra-append)
      need_option_value "$@"
      EXTRA_KERNEL_ARGS="$2"
      shift 2
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

if [[ -z "$IMAGE_FILE" ]]; then
  IMAGE_FILE="${PROJECT_DIR}/pinetabv-debian.img"
fi

is_positive_integer "$QEMU_CPUS" || die "--cpus must be a positive integer."
is_positive_integer "$QEMU_MEMORY_MB" || die "--memory must be a positive integer."
is_nonnegative_integer "$QEMU_TIMEOUT" || die "--timeout must be zero or a positive integer."
is_positive_integer "$ROOT_PARTITION" || die "ROOT_PARTITION must be a positive integer."
is_positive_integer "$BOOT_PARTITION" || die "BOOT_PARTITION must be a positive integer."

require_command "$QEMU_BIN"
require_command sgdisk
require_command sha256sum
require_command mtype
[[ "$QEMU_TIMEOUT" == 0 ]] || require_command timeout

[[ -f "$IMAGE_FILE" ]] || die "Disk image not found: $IMAGE_FILE"
[[ -r "$IMAGE_FILE" ]] || die "Disk image is not readable: $IMAGE_FILE"
IMAGE_FILE="$(readlink -f -- "$IMAGE_FILE")"

if ! "$QEMU_BIN" -machine help 2>&1 | awk '$1 == "virt" { found = 1 } END { exit !found }'; then
  die "$QEMU_BIN does not provide the RISC-V virt machine."
fi

root_partuuid="$({
  sgdisk -i "$ROOT_PARTITION" "$IMAGE_FILE" 2>/dev/null || true
} | awk -F ': *' '/Partition unique GUID:/ { print tolower($2); exit }')"
[[ "$root_partuuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || \
  die "Could not read the root PARTUUID from GPT partition $ROOT_PARTITION."

boot_first_sector="$({
  sgdisk -i "$BOOT_PARTITION" "$IMAGE_FILE" 2>/dev/null || true
} | awk -F ': *' '/First sector:/ { print $2; exit }' | awk '{ print $1 }')"
[[ "$boot_first_sector" =~ ^[0-9]+$ ]] || \
  die "Could not read the boot partition start sector from GPT partition $BOOT_PARTITION."
boot_offset_bytes=$((boot_first_sector * 512))

extlinux_conf="$(MTOOLS_SKIP_CHECK=1 mtype -i "${IMAGE_FILE}@@${boot_offset_bytes}" ::/extlinux/extlinux.conf 2>/dev/null || true)"
[[ -n "$extlinux_conf" ]] || \
  die "Could not read /extlinux/extlinux.conf from boot partition $BOOT_PARTITION."

DISTRO=debian
if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="${PROJECT_DIR}/work-pinetabv-debian/logs"
fi

default_label="$(awk 'tolower($1) == "default" { print $2; exit }' <<< "$extlinux_conf")"
[[ "$default_label" == debian ]] || \
  die "The image's extlinux configuration must default to debian."
default_kernel="$(awk -v want="$default_label" '
  BEGIN { want = tolower(want) }
  tolower($1) == "label" { selected = (tolower($2) == want) }
  selected && tolower($1) == "linux" { print $2; exit }
' <<< "$extlinux_conf")"
default_dtb="$(awk -v want="$default_label" '
  BEGIN { want = tolower(want) }
  tolower($1) == "label" { selected = (tolower($2) == want) }
  selected && tolower($1) == "fdt" { print $2; exit }
' <<< "$extlinux_conf")"
default_cmdline="$(awk -v want="$default_label" '
  BEGIN { want = tolower(want) }
  tolower($1) == "label" { selected = (tolower($2) == want) }
  selected && tolower($1) == "append" { sub(/^[[:space:]]*append[[:space:]]+/, ""); print; exit }
' <<< "$extlinux_conf")"
diagnostic_label="$(awk '
  tolower($1) == "label" && tolower($2) ~ /(^|-)diagnostics$/ { print $2; exit }
' <<< "$extlinux_conf")"
diagnostic_cmdline="$(awk -v want="$diagnostic_label" '
  BEGIN { want = tolower(want) }
  tolower($1) == "label" { selected = (tolower($2) == want) }
  selected && tolower($1) == "append" { sub(/^[[:space:]]*append[[:space:]]+/, ""); print; exit }
' <<< "$extlinux_conf")"

[[ "$default_kernel" == /Image ]] || \
  die "The default extlinux entry does not load /Image."
[[ "$default_dtb" == "/dtbs/${EXPECTED_DTB}" ]] || \
  die "The default extlinux entry selects ${default_dtb:-no DTB}, not /dtbs/$EXPECTED_DTB."
[[ "$default_cmdline" == *"root=PARTUUID=${root_partuuid}"* && \
   "$default_cmdline" == *"console=ttyS0,115200"* ]] || \
  die "The default extlinux entry lacks the matching root PARTUUID or UART console."
[[ "$diagnostic_label" =~ ^[A-Za-z0-9._+-]+$ && \
   "$diagnostic_cmdline" == *"root=PARTUUID=${root_partuuid}"* && \
   "$diagnostic_cmdline" == *"console=ttyS0,115200"* && \
   "$diagnostic_cmdline" == *"drm.debug="* ]] || \
  die "The image lacks a valid *-diagnostics extlinux entry."

temporary_dir="$(mktemp -d -t pinetabv-qemu.XXXXXXXX)"
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

kernel_source="override"
if [[ -z "$KERNEL_IMAGE" ]]; then
  require_command mcopy
  KERNEL_IMAGE="${temporary_dir}/Image"
  MTOOLS_SKIP_CHECK=1 mcopy -i "${IMAGE_FILE}@@${boot_offset_bytes}" ::/Image "$KERNEL_IMAGE" >/dev/null 2>&1 || \
    die "Could not extract /Image from boot partition $BOOT_PARTITION."
  kernel_source="image partition ${BOOT_PARTITION}"
else
  [[ -f "$KERNEL_IMAGE" ]] || die "Kernel Image not found: $KERNEL_IMAGE"
  [[ -r "$KERNEL_IMAGE" ]] || die "Kernel Image is not readable: $KERNEL_IMAGE"
  KERNEL_IMAGE="$(readlink -f -- "$KERNEL_IMAGE")"
fi
[[ -s "$KERNEL_IMAGE" ]] || die "Kernel Image is empty: $KERNEL_IMAGE"

if [[ -z "$LOG_FILE" ]]; then
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  LOG_FILE="${LOG_DIR}/qemu-pinetabv-${DISTRO}-uart-${timestamp}.log"
fi
mkdir -p -- "$(dirname -- "$LOG_FILE")"
if [[ -e "$LOG_FILE" ]]; then
  if [[ "$log_file_explicit" == true ]]; then
    die "Refusing to overwrite existing log: $LOG_FILE"
  fi
  LOG_FILE="${LOG_FILE%.log}-$$.log"
fi
LOG_FILE="$(readlink -m -- "$LOG_FILE")"

kernel_cmdline="root=PARTUUID=${root_partuuid} rw rootwait rootfstype=ext4 console=ttyS0,115200 earlycon=sbi ignore_loglevel loglevel=8 log_buf_len=4M printk.time=1 systemd.log_target=console systemd.show_status=1"
if [[ -n "$EXTRA_KERNEL_ARGS" ]]; then
  kernel_cmdline+=" ${EXTRA_KERNEL_ARGS}"
fi

qemu_args=(
  -machine virt,acpi=off
  -accel tcg,thread=multi
  -cpu rv64
  -smp "$QEMU_CPUS"
  -m "$QEMU_MEMORY_MB"
  -bios default
  -kernel "$KERNEL_IMAGE"
  -append "$kernel_cmdline"
  -drive "if=none,id=rootdisk,file=${IMAGE_FILE},format=raw,snapshot=on,cache=unsafe"
  -device virtio-blk-device,drive=rootdisk
  -display none
  -monitor none
  -chardev "file,id=uart,path=${LOG_FILE},append=off"
  -serial chardev:uart
  -nic none
  -no-reboot
)

printf '%s\n' \
  '[*] PineTab-V generic QEMU UART test' \
  "[*] QEMU: $($QEMU_BIN --version | sed -n '1p')" \
  "[*] Distribution/image family: ${DISTRO}" \
  "[*] Image: ${IMAGE_FILE}" \
  "[*] Extlinux default: ${default_label} (${default_dtb})" \
  "[*] Extlinux diagnostics: ${diagnostic_label}" \
  "[*] Kernel: ${KERNEL_IMAGE} (${kernel_source})" \
  "[*] Kernel SHA-256: $(sha256sum "$KERNEL_IMAGE" | awk '{print $1}')" \
  "[*] Root PARTUUID: ${root_partuuid}" \
  "[*] UART log: ${LOG_FILE}" \
  '[*] The disk uses snapshot=on; all guest writes are temporary.' \
  '[!] This is QEMU virt, not JH7110/PineTab-V hardware.'

if [[ "$QEMU_TIMEOUT" == 0 ]]; then
  printf '%s\n' '[*] Press Ctrl-C to stop QEMU.'
else
  printf '[*] QEMU will stop after %s seconds.\n' "$QEMU_TIMEOUT"
fi
printf '\n'

set +e
if [[ "$QEMU_TIMEOUT" == 0 ]]; then
  "$QEMU_BIN" "${qemu_args[@]}"
  qemu_status=$?
else
  timeout --signal=TERM --kill-after=5s "${QEMU_TIMEOUT}s" \
    "$QEMU_BIN" "${qemu_args[@]}"
  qemu_status=$?
fi
set -e
[[ -s "$LOG_FILE" ]] || \
  die "QEMU produced no serial output in $LOG_FILE."

printf '\n[*] UART evidence summary:\n'
test_failed=false
if grep -Fq "Linux version ${EXPECTED_KERNEL_RELEASE} (" "$LOG_FILE"; then
  grep -Fm1 "Linux version ${EXPECTED_KERNEL_RELEASE}" "$LOG_FILE" | sed 's/^/  PASS kernel: /'
else
  printf '  FAIL kernel: no Linux %s banner was captured\n' "$EXPECTED_KERNEL_RELEASE"
  test_failed=true
fi
if grep -Eq "VFS: Mounted root|EXT4-fs \\(vda${ROOT_PARTITION}\\): mounted filesystem" "$LOG_FILE"; then
  printf '  PASS rootfs: partition %s mounted\n' "$ROOT_PARTITION"
else
  printf '%s\n' '  FAIL rootfs: no root-mount marker was captured'
  test_failed=true
fi
if grep -Eq 'Started .*Serial Getty on ttyS0|Debian GNU/Linux .* ttyS0|(^|[[:space:]])pinetabv[^[:space:]]* login:' "$LOG_FILE"; then
  printf '%s\n' '  PASS UART/userspace: ttyS0 getty reached'
else
  printf '%s\n' '  FAIL UART/userspace: no ttyS0 login/getty marker was captured'
  test_failed=true
fi
if grep -Eq 'Debian GNU/Linux( 13)?|Welcome to Debian' "$LOG_FILE"; then
  printf '%s\n' '  PASS distribution: Debian userspace banner reached'
else
  printf '%s\n' '  FAIL distribution: no Debian userspace marker was captured'
  test_failed=true
fi
printf '[*] Full console saved to %s\n' "$LOG_FILE"
printf '%s\n' '[!] A passing QEMU result cannot validate the physical DSI/panel/backlight path.'

case "$qemu_status" in
  0) ;;
  124|130|143)
    printf '[*] QEMU stopped as requested (status %s).\n' "$qemu_status"
    ;;
  *)
    die "QEMU exited unexpectedly with status $qemu_status."
    ;;
esac

[[ "$test_failed" == false ]] || \
  die "QEMU completed, but one or more required boot markers were missing."
