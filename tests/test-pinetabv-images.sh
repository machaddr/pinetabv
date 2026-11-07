#!/usr/bin/env bash
# Run the read-only generic-QEMU boot test for the final PineTab-V Debian image.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly QEMU_RUNNER="${SCRIPT_DIR}/run-pinetabv-qemu-uart.sh"

TARGET="${DISTRO:-debian}"
DEBIAN_IMAGE="${DEBIAN_IMAGE:-${PROJECT_DIR}/pinetabv-debian.img}"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-120}"
QEMU_CPUS="${QEMU_CPUS:-4}"
QEMU_MEMORY_MB="${QEMU_MEMORY_MB:-2048}"
EXPECTED_KERNEL_RELEASE="${EXPECTED_KERNEL_RELEASE:-7.3.0-pinetabv}"
EXPECTED_DTB="${EXPECTED_DTB:-jh7110-pine64-pinetab-v-20240730.dtb}"

usage() {
  cat <<'EOF'
Usage: test-pinetabv-images.sh [options]

Boot-test the final PineTab-V Debian raw image on QEMU virt.
The image is attached with snapshot=on and cannot be modified by the guest.

Options:
  --distro NAME        Image family: debian (default: debian)
  --debian-image PATH  Debian image (default: project-root/pinetabv-debian.img)
  --timeout SECONDS    Boot timeout (default: 120)
  --cpus N             Virtual CPUs (default: 4)
  --memory MB          Guest RAM in MiB (default: 2048)
  --kernel-release REL Expected kernel release (default: 7.3.0-pinetabv)
  --dtb FILE           Expected default DTB basename (2024-07-30 by default)
  -h, --help           Show this help

Environment equivalents:
  DISTRO, DEBIAN_IMAGE, QEMU_TIMEOUT, QEMU_CPUS,
  QEMU_MEMORY_MB, EXPECTED_KERNEL_RELEASE, EXPECTED_DTB

QEMU virt validates the kernel, root filesystem, init/getty and distribution
userspace. Physical PineTab-V hardware still requires the UART capture test.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_option_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "Option $1 requires a value."
}

while (($#)); do
  case "$1" in
    --distro)
      need_option_value "$@"
      TARGET="${2,,}"
      shift 2
      ;;
    --debian-image)
      need_option_value "$@"
      DEBIAN_IMAGE="$2"
      shift 2
      ;;
    --timeout)
      need_option_value "$@"
      QEMU_TIMEOUT="$2"
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

case "$TARGET" in
  debian) ;;
  *) die "--distro must be debian." ;;
esac
[[ "$QEMU_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer."
[[ "$QEMU_CPUS" =~ ^[1-9][0-9]*$ ]] || die "--cpus must be a positive integer."
[[ "$QEMU_MEMORY_MB" =~ ^[1-9][0-9]*$ ]] || die "--memory must be a positive integer."
[[ -x "$QEMU_RUNNER" ]] || die "QEMU runner is not executable: $QEMU_RUNNER"

test_image() {
  local distro="$1"
  local image="$2"

  printf '\n[*] Testing final %s image: %s\n' "$distro" "$image"
  "$QEMU_RUNNER" \
    --distro "$distro" \
    --image "$image" \
    --timeout "$QEMU_TIMEOUT" \
    --cpus "$QEMU_CPUS" \
    --memory "$QEMU_MEMORY_MB" \
    --kernel-release "$EXPECTED_KERNEL_RELEASE" \
    --dtb "$EXPECTED_DTB"
}

if ! test_image debian "$DEBIAN_IMAGE"; then
  die "Debian final-image test failed."
fi
printf '\n[*] PineTab-V Debian final-image test passed.\n'
