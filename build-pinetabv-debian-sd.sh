#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DEVICE=""
IMAGE_FILE=""
IMAGE_WORK_FILE=""
IMAGE_WORK_OWNED=0
IMAGE_COMMITTED=0
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-12}"
ASSUME_YES=0

DISTRO_ID=debian
DISTRO_NAME='Debian 13'
HOSTNAME_VALUE="${HOSTNAME_VALUE:-pinetabv}"
TIMEZONE_VALUE="${TIMEZONE_VALUE:-UTC}"
LOCALE_VALUE="${LOCALE_VALUE:-en_US.UTF-8}"
WORKDIR="${WORKDIR:-${SELF_DIR}/work-pinetabv-debian}"
QEMU_RISCV_STATIC="${QEMU_RISCV_STATIC:-}"

BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-512}"
BOOT_LABEL="${BOOT_LABEL:-BOOT}"
ROOT_LABEL="${ROOT_LABEL:-DEBIANROOT}"

KERNEL_REPO="${KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
KERNEL_REF="${KERNEL_REF:-v7.3}"
KERNEL_COMMIT="${KERNEL_COMMIT:-c03c1a14507dfaf8b856c2608f9ac216021fc222}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-defconfig}"
KERNEL_PATCH_DIR="${KERNEL_PATCH_DIR:-${SELF_DIR}/patches/linux-7.3}"

PVR_FIRMWARE_NAME="rogue_36.50.54.182_v1.fw"
PVR_FIRMWARE_URL="${PVR_FIRMWARE_URL:-https://gitlab.freedesktop.org/imagination/linux-firmware/-/raw/powervr/powervr/${PVR_FIRMWARE_NAME}}"
PVR_FIRMWARE_SHA256="${PVR_FIRMWARE_SHA256:-59127d3a02e48876310a520b7dc355f7430d3748d2940caaa33f39237d517abb}"
PVR_LICENSE_URL="${PVR_LICENSE_URL:-https://gitlab.freedesktop.org/imagination/linux-firmware/-/raw/powervr/LICENSE.powervr}"
PVR_LICENSE_SHA256="${PVR_LICENSE_SHA256:-1c9aa6bd6703a7ce1cdb879542fa1d8aca115a327bd819b193c971de9c53f402}"

UBOOT_REPO="${UBOOT_REPO:-https://github.com/starfive-tech/u-boot.git}"
UBOOT_REF="${UBOOT_REF:-pinetabv-devel}"
UBOOT_COMMIT="${UBOOT_COMMIT:-196f587b957a7a7b2900de53b1cafb6ae034de0d}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-pine64_pinetabv_defconfig}"
UBOOT_COMPAT_PATCH="${UBOOT_COMPAT_PATCH:-${SELF_DIR}/patches/u-boot-pinetabv-compat.patch}"

OPENSBI_REPO="${OPENSBI_REPO:-https://github.com/riscv-software-src/opensbi.git}"
OPENSBI_REF="${OPENSBI_REF:-v1.9}"
OPENSBI_COMMIT="${OPENSBI_COMMIT:-cbf9f6734dd85a982c63e3cb5db7ffe09da839ca}"
SPL_TOOL_REPO="${SPL_TOOL_REPO:-https://github.com/starfive-tech/Tools.git}"
SPL_TOOL_REF="${SPL_TOOL_REF:-master}"
SPL_TOOL_COMMIT="${SPL_TOOL_COMMIT:-a9df16e9b8a6f36c55d3a74cb9ac269c0f871739}"

PINETABV_DTB="${PINETABV_DTB:-jh7110-pine64-pinetab-v-20240730.dtb}"
PINETABV_FALLBACK_DTB="${PINETABV_FALLBACK_DTB:-}"
if [[ -z "${PINETABV_FALLBACK_DTB}" ]]; then
  case "${PINETABV_DTB}" in
    jh7110-pine64-pinetab-v-20240730.dtb)
      PINETABV_FALLBACK_DTB="jh7110-pine64-pinetab-v-20230614.dtb"
      ;;
    jh7110-pine64-pinetab-v-20230614.dtb)
      PINETABV_FALLBACK_DTB="jh7110-pine64-pinetab-v-20240730.dtb"
      ;;
  esac
fi

PINETABV_DRM_EXCLUDED=(
  DRM_CDNS_DSI_J721E
  DRM_DW_HDMI
  DRM_EFIDRM
  DRM_NOUVEAU
  DRM_RADEON
  DRM_SIMPLEDRM
  DRM_SUN4I
  DRM_VIRTIO_GPU
)

JOBS="${JOBS:-$(nproc)}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-}"
RESTORE_OWNER_UID="${SUDO_UID:-}"
RESTORE_OWNER_GID="${SUDO_GID:-}"

DOWNLOAD_DIR="${WORKDIR}/downloads"
SRC_DIR="${WORKDIR}/src"
BUILD_DIR="${WORKDIR}/build"
MNT_DIR="${WORKDIR}/mnt"
ROOT_MNT="${MNT_DIR}/root"
# Keep /boot on the real FAT partition during dpkg installation.
BOOT_MNT="${ROOT_MNT}/boot"

LOOP_DEV=""
TARGET_NODE=""
PART_SPL=""
PART_UBOOT=""
PART_BOOT=""
PART_ROOT=""
OPENSBI_EFFECTIVE_REF=""
KERNEL_RELEASE=""
CHROOT_MOUNTS=()
ORIGINAL_RISCV64_BINFMT_INTERPRETER=""
ORIGINAL_RISCV64_BINFMT_FLAGS=""
ORIGINAL_RISCV64_BINFMT_MAGIC_HEX=""
ORIGINAL_RISCV64_BINFMT_MASK_HEX=""
TEMP_RISCV64_BINFMT_ACTIVE=0
INSTALLED_SPL_IMAGE=""
INSTALLED_UBOOT_IMAGE=""
BUILD_LOCK_FD=""

TYPE_GUID_SPL="2E54B353-1271-4842-806F-E436D6AF6985"
TYPE_GUID_UBOOT="5B193300-FC78-40CD-8002-E86C45580B47"

DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_ARCH="${DEBIAN_ARCH:-riscv64}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-https://deb.debian.org/debian-security}"
DEBIAN_COMPONENTS="${DEBIAN_COMPONENTS:-main,contrib,non-free,non-free-firmware}"
DEBIAN_APT_COMPONENTS="${DEBIAN_APT_COMPONENTS:-main contrib non-free non-free-firmware}"
DEBIAN_BOOTSTRAP_KEYRING="${DEBIAN_BOOTSTRAP_KEYRING:-}"
DEBIAN_KEYRING_DEB_URL="${DEBIAN_KEYRING_DEB_URL:-https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb}"
DEBIAN_KEYRING_DEB_SHA256="${DEBIAN_KEYRING_DEB_SHA256:-9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac}"
KDEB_PKGVERSION="${KDEB_PKGVERSION:-7.3.0-1+pinetabv5}"
KERNEL_PACKAGE_MAINTAINER="${KERNEL_PACKAGE_MAINTAINER:-André Machado <machaddr@falanet.org>}"
DEBIAN_DESKTOP_USER="${DEBIAN_DESKTOP_USER:-user}"
DEBIAN_DESKTOP_PASSWORD="${DEBIAN_DESKTOP_PASSWORD:-debian}"

DEBIAN_REQUIRED_PACKAGES="${DEBIAN_REQUIRED_PACKAGES:-systemd-sysv systemd-resolved udev kmod dbus locales tzdata ca-certificates dialog linux-base build-essential}"
DEBIAN_PACKAGES="${DEBIAN_PACKAGES:-openssh-server sudo network-manager wpasupplicant wireless-regdb firmware-realtek bluez rfkill iw iproute2 iputils-ping pciutils usbutils i2c-tools iio-sensor-proxy libreoffice libreoffice-gtk3 libinput-tools dconf-cli alsa-utils pipewire-audio wireplumber v4l-utils libcamera-tools libcamera-ipa libspa-0.2-libcamera libspa-0.2-modules gstreamer1.0-pipewire gstreamer1.0-plugins-good gnome-snapshot libdrm-tests mesa-utils vulkan-tools parted dosfstools e2fsprogs curl less vim-tiny task-gnome-desktop gdm3}"

KERNEL_PACKAGE_DIR="${BUILD_DIR}/debian-packages"
KERNEL_IMAGE_PACKAGE=""
KERNEL_IMAGE_DEB=""
HARDWARE_SUPPORT_DEB=""
TARGET_NEEDS_QEMU=1

log() {
  printf '[*] %s\n' "$*" >&2
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

partition_path() {
  local dev="$1"
  local idx="$2"

  if [[ "${dev}" =~ (loop|mmcblk|nvme|nbd|zd)[0-9]*$ ]]; then
    printf '%sp%s' "${dev}" "${idx}"
  else
    printf '%s%s' "${dev}" "${idx}"
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
  done
}

require_cross_toolchain() {
  local tool=""

  if [[ -n "${CROSS_COMPILE}" ]]; then
    command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || die "Cross compiler not found: ${CROSS_COMPILE}gcc"
  else
    local prefix
    for prefix in riscv64-unknown-linux-gnu- riscv64-linux-gnu-; do
      if command -v "${prefix}gcc" >/dev/null 2>&1; then
        CROSS_COMPILE="${prefix}"
        break
      fi
    done
    [[ -n "${CROSS_COMPILE}" ]] || \
      die "No suitable RISC-V cross toolchain found. Install one and/or set CROSS_COMPILE."
  fi

  for tool in ar gcc ld nm objcopy objdump ranlib readelf strip; do
    command -v "${CROSS_COMPILE}${tool}" >/dev/null 2>&1 || \
      die "Cross-toolchain command not found: ${CROSS_COMPILE}${tool}"
  done
}

require_qemu_static() {
  if [[ -n "${QEMU_RISCV_STATIC}" ]]; then
    [[ -x "${QEMU_RISCV_STATIC}" ]] || die "QEMU_RISCV_STATIC is not executable: ${QEMU_RISCV_STATIC}"
    return
  fi

  local candidate
  for candidate in /usr/bin/qemu-riscv64-static /usr/local/bin/qemu-riscv64-static; do
    if [[ -x "${candidate}" ]]; then
      QEMU_RISCV_STATIC="${candidate}"
      return
    fi
  done

  die "Cross-architecture Debian bootstrap requires qemu-riscv64-static. Install qemu-user-static or set QEMU_RISCV_STATIC."
}

ensure_riscv64_binfmt() {
  local register_file="/proc/sys/fs/binfmt_misc/register"
  local entry_name="qemu-riscv64"
  local magic_escaped='\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00'
  local mask_escaped='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
  local entry_path="/proc/sys/fs/binfmt_misc/${entry_name}"
  local current_interpreter=""
  local current_flags=""
  local current_magic_hex=""
  local current_mask_hex=""


  if [[ -e "${entry_path}" ]]; then
    current_interpreter="$(awk '/^interpreter / { print $2 }' "${entry_path}")"
    current_flags="$(awk '/^flags:/ { print $2 }' "${entry_path}")"
    current_magic_hex="$(awk '/^magic / { print $2 }' "${entry_path}")"
    current_mask_hex="$(awk '/^mask / { print $2 }' "${entry_path}")"

    if [[ "${current_interpreter}" == "${QEMU_RISCV_STATIC}" && "${current_flags}" == *F* ]]; then
      return
    fi

    log "Replacing incompatible qemu-riscv64 binfmt entry (${current_interpreter:-unknown}, flags ${current_flags:-unknown})"
    ORIGINAL_RISCV64_BINFMT_INTERPRETER="${current_interpreter}"
    ORIGINAL_RISCV64_BINFMT_FLAGS="${current_flags}"
    ORIGINAL_RISCV64_BINFMT_MAGIC_HEX="${current_magic_hex}"
    ORIGINAL_RISCV64_BINFMT_MASK_HEX="${current_mask_hex}"
    echo -1 > "${entry_path}"
  fi

  [[ -e "${register_file}" ]] || die "binfmt_misc is not available at ${register_file}"

  log "Registering qemu-riscv64-static with binfmt_misc"
  printf ':%s:M::%s:%s:%s:FP\n' \
    "${entry_name}" "${magic_escaped}" "${mask_escaped}" "${QEMU_RISCV_STATIC}" > "${register_file}"
  TEMP_RISCV64_BINFMT_ACTIVE=1
}

restore_riscv64_binfmt() {
  local register_file="/proc/sys/fs/binfmt_misc/register"
  local entry_path="/proc/sys/fs/binfmt_misc/qemu-riscv64"

  (( TEMP_RISCV64_BINFMT_ACTIVE == 1 )) || return 0
  [[ -e "${register_file}" ]] || return 0

  if [[ -e "${entry_path}" ]]; then
    echo -1 > "${entry_path}" || true
  fi

  if [[ -n "${ORIGINAL_RISCV64_BINFMT_INTERPRETER}" ]]; then
    printf ':%s:M::%s:%s:%s:%s\n' \
      "qemu-riscv64" \
      "$(printf '%s' "${ORIGINAL_RISCV64_BINFMT_MAGIC_HEX}" | sed 's/../\\x&/g')" \
      "$(printf '%s' "${ORIGINAL_RISCV64_BINFMT_MASK_HEX}" | sed 's/../\\x&/g')" \
      "${ORIGINAL_RISCV64_BINFMT_INTERPRETER}" \
      "${ORIGINAL_RISCV64_BINFMT_FLAGS}" > "${register_file}" || true
  fi

  TEMP_RISCV64_BINFMT_ACTIVE=0
}

ensure_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi

  die "Run this script as root or install sudo."
}

cleanup_mount() {
  local path="$1"
  if [[ -n "${path}" ]] && findmnt -rn -M "${path}" >/dev/null 2>&1; then
    umount -R "${path}" || umount -Rl "${path}" || true
  fi
}

unmount_target_strict() {
  local path="$1"
  local attempt=0

  for attempt in 1 2 3 4 5; do
    if ! findmnt -rn -M "${path}" >/dev/null 2>&1; then
      return
    fi
    umount "${path}" >/dev/null 2>&1 || true
    if ! findmnt -rn -M "${path}" >/dev/null 2>&1; then
      return
    fi
    sync
    sleep 1
  done

  findmnt -R "${path}" >&2 || true
  die "Could not unmount ${path} cleanly; refusing to publish the image."
}

cleanup_chroot_mounts() {
  local idx

  for (( idx=${#CHROOT_MOUNTS[@]}-1; idx>=0; idx-- )); do
    cleanup_mount "${CHROOT_MOUNTS[idx]}"
  done
  CHROOT_MOUNTS=()
}

cleanup() {
  local rc=$?
  set +e
  cleanup_chroot_mounts
  restore_riscv64_binfmt
  cleanup_mount "${BOOT_MNT}"
  cleanup_mount "${ROOT_MNT}"
  if [[ -n "${LOOP_DEV}" ]]; then
    losetup -d "${LOOP_DEV}" || true
    LOOP_DEV=""
  fi
  if (( IMAGE_WORK_OWNED == 1 && IMAGE_COMMITTED == 0 )) &&
     [[ -n "${IMAGE_WORK_FILE}" && "${IMAGE_WORK_FILE}" == "${IMAGE_FILE}.building."* ]]; then
    rm -f -- "${IMAGE_WORK_FILE}" || \
      warn "Could not remove incomplete image: ${IMAGE_WORK_FILE}"
  fi
  if [[ -n "${RESTORE_OWNER_UID}" && -n "${RESTORE_OWNER_GID}" && -d "${WORKDIR}" ]]; then
    chown -R "${RESTORE_OWNER_UID}:${RESTORE_OWNER_GID}" "${WORKDIR}" || true
  fi
  exit "${rc}"
}

trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || die "--target requires a path"
        TARGET_DEVICE="$2"
        shift 2
        ;;
      --image)
        [[ $# -ge 2 ]] || die "--image requires a path"
        IMAGE_FILE="$2"
        shift 2
        ;;
      --size-gb)
        [[ $# -ge 2 ]] || die "--size-gb requires a value"
        IMAGE_SIZE_GB="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "${TARGET_DEVICE}" || -n "${IMAGE_FILE}" ]] || die "Pass --target or --image."
  [[ -z "${TARGET_DEVICE}" || -z "${IMAGE_FILE}" ]] || die "Use either --target or --image, not both."
  [[ "${IMAGE_SIZE_GB}" =~ ^[1-9][0-9]*$ ]] || die "--size-gb must be a positive integer."

  case "${PINETABV_DTB}" in
    jh7110-pine64-pinetab-v-20230614.dtb|jh7110-pine64-pinetab-v-20240730.dtb)
      ;;
    *)
      die "PINETABV_DTB must name one of the two supported PineTab-V revision DTBs."
      ;;
  esac
  case "${PINETABV_FALLBACK_DTB}" in
    jh7110-pine64-pinetab-v-20230614.dtb|jh7110-pine64-pinetab-v-20240730.dtb)
      ;;
    *)
      die "PINETABV_FALLBACK_DTB must name one of the two supported revision DTBs."
      ;;
  esac
  [[ "${PINETABV_DTB}" != "${PINETABV_FALLBACK_DTB}" ]] || \
    die "PINETABV_DTB and PINETABV_FALLBACK_DTB must be different."
}

confirm_target() {
  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return
  fi

  if [[ -n "${TARGET_DEVICE}" ]]; then
    [[ -b "${TARGET_DEVICE}" ]] || die "Target is not a block device: ${TARGET_DEVICE}"

    printf 'About to erase %s\nType "erase %s" to continue: ' "${TARGET_DEVICE}" "${TARGET_DEVICE}" >&2
    local answer=""
    read -r answer
    [[ "${answer}" == "erase ${TARGET_DEVICE}" ]] || die "Confirmation failed."
  fi
}

prepare_workdirs() {
  mkdir -p "${DOWNLOAD_DIR}" "${SRC_DIR}" "${BUILD_DIR}" "${ROOT_MNT}" "${BOOT_MNT}"
}

acquire_build_lock() {
  local lock_file="${WORKDIR}/.build.lock"

  exec {BUILD_LOCK_FD}>"${lock_file}"
  flock -n "${BUILD_LOCK_FD}" || \
    die "Another PineTab-V build is already using ${WORKDIR}."
}

assert_target_is_idle() {
  local path="$1"
  local mounted=""

  mounted="$(lsblk -nrpo NAME,MOUNTPOINT "${path}" 2>/dev/null | awk '$2 != "" {print $1 ":" $2}')"
  [[ -z "${mounted}" ]] || die "Target has mounted partitions:\n${mounted}"
}

setup_target_node() {
  local image_dir=""
  local image_name=""
  local image_candidate=""

  if [[ -n "${TARGET_DEVICE}" ]]; then
    [[ -b "${TARGET_DEVICE}" ]] || die "Target is not a block device: ${TARGET_DEVICE}"
    assert_target_is_idle "${TARGET_DEVICE}"
    TARGET_NODE="${TARGET_DEVICE}"
    return
  fi

  image_name="$(basename -- "${IMAGE_FILE}")"
  [[ "${image_name}" != "." && "${image_name}" != ".." ]] || \
    die "Unsafe image filename: ${IMAGE_FILE}"
  install -d "$(dirname -- "${IMAGE_FILE}")"
  image_dir="$(cd "$(dirname -- "${IMAGE_FILE}")" && pwd -P)"
  IMAGE_FILE="${image_dir}/${image_name}"
  [[ ! -L "${IMAGE_FILE}" ]] || die "Refusing to replace a symlink: ${IMAGE_FILE}"

  image_candidate="$(mktemp "${IMAGE_FILE}.building.XXXXXX")"
  IMAGE_WORK_FILE="${image_candidate}"
  IMAGE_WORK_OWNED=1
  truncate -s "${IMAGE_SIZE_GB}G" "${IMAGE_WORK_FILE}"
  LOOP_DEV="$(losetup --show -Pf "${IMAGE_WORK_FILE}")"
  TARGET_NODE="${LOOP_DEV}"
}

refresh_partition_nodes() {
  sync
  if [[ -n "${LOOP_DEV}" ]]; then
    losetup -d "${LOOP_DEV}"
    LOOP_DEV="$(losetup --show -Pf "${IMAGE_WORK_FILE}")"
    TARGET_NODE="${LOOP_DEV}"
  else
    partprobe "${TARGET_NODE}"
  fi
  udevadm settle
}

partition_info_field() {
  local info="$1"
  local field="$2"

  awk -F': ' -v field="${field}" '
    $1 == field {
      split($2, value, " ");
      print value[1];
      exit;
    }
  ' <<< "${info}"
}

verify_partition_layout() {
  local spl_info=""
  local uboot_info=""

  spl_info="$(LC_ALL=C sgdisk -i 1 "${TARGET_NODE}")"
  uboot_info="$(LC_ALL=C sgdisk -i 2 "${TARGET_NODE}")"

  [[ "$(partition_info_field "${spl_info}" 'Partition GUID code')" == \
      "${TYPE_GUID_SPL}" ]] || die "The SPL partition has the wrong type GUID."
  [[ "$(partition_info_field "${uboot_info}" 'Partition GUID code')" == \
      "${TYPE_GUID_UBOOT}" ]] || die "The U-Boot partition has the wrong type GUID."
  [[ "$(partition_info_field "${spl_info}" 'First sector')" == 4096 && \
     "$(partition_info_field "${spl_info}" 'Last sector')" == 8191 ]] || \
    die "The SPL partition is not at the JH7110 ROM offset."
  [[ "$(partition_info_field "${uboot_info}" 'First sector')" == 8192 && \
     "$(partition_info_field "${uboot_info}" 'Last sector')" == 16383 ]] || \
    die "The U-Boot partition is not at the JH7110 SPL offset."
}

partition_target() {
  log "Partitioning ${TARGET_NODE}"

  sgdisk --zap-all "${TARGET_NODE}" >/dev/null
  sgdisk --clear \
    --set-alignment=2 \
    --new=1:4096:8191 --change-name=1:spl   --typecode=1:${TYPE_GUID_SPL} \
    --new=2:8192:16383 --change-name=2:uboot --typecode=2:${TYPE_GUID_UBOOT} \
    --new=3:16384:+${BOOT_SIZE_MIB}MiB --change-name=3:boot --typecode=3:EF00 \
    --new=4:0:0 --change-name=4:rootfs --typecode=4:8300 \
    "${TARGET_NODE}" >/dev/null

  refresh_partition_nodes

  PART_SPL="$(partition_path "${TARGET_NODE}" 1)"
  PART_UBOOT="$(partition_path "${TARGET_NODE}" 2)"
  PART_BOOT="$(partition_path "${TARGET_NODE}" 3)"
  PART_ROOT="$(partition_path "${TARGET_NODE}" 4)"

  [[ -b "${PART_SPL}" && -b "${PART_UBOOT}" && -b "${PART_BOOT}" && -b "${PART_ROOT}" ]] || die "Partition nodes were not created correctly."
  verify_partition_layout
}

format_filesystems() {
  log "Formatting boot and root filesystems"
  mkfs.vfat -F 32 -n "${BOOT_LABEL}" "${PART_BOOT}" >/dev/null
  mkfs.ext4 \
    -L "${ROOT_LABEL}" \
    "${PART_ROOT}" >/dev/null
}

verify_sha256() {
  local path="$1"
  local expected="$2"

  printf '%s  %s\n' "${expected}" "${path}" | sha256sum --check --status
}

download_verified_file() {
  local url="$1"
  local dest="$2"
  local expected_sha256="$3"
  local partial="${dest}.download"

  if [[ -f "${dest}" ]] && verify_sha256 "${dest}" "${expected_sha256}"; then
    log "Using verified cached download ${dest}"
    return
  fi

  log "Downloading and verifying ${url}"
  curl -fL --retry 5 --retry-delay 2 --retry-connrefused -o "${partial}" "${url}"
  verify_sha256 "${partial}" "${expected_sha256}" || die "SHA-256 verification failed for ${url}"
  mv -f "${partial}" "${dest}"
}

clone_ref() {
  local repo="$1"
  local ref="$2"
  local dest="$3"

  rm -rf "${dest}"
  git clone --depth 1 --branch "${ref}" "${repo}" "${dest}" >/dev/null
}

apply_u_boot_compat_patches() {
  [[ -f "${UBOOT_COMPAT_PATCH}" ]] || die "Missing U-Boot compatibility patch: ${UBOOT_COMPAT_PATCH}"

  log "Applying U-Boot compatibility patch ${UBOOT_COMPAT_PATCH}"
  if git -C "${SRC_DIR}/u-boot" apply --reverse --check --whitespace=nowarn "${UBOOT_COMPAT_PATCH}" >/dev/null 2>&1; then
    log "U-Boot compatibility patch already applied"
    return
  fi

  git -C "${SRC_DIR}/u-boot" apply --check --whitespace=nowarn "${UBOOT_COMPAT_PATCH}"
  git -C "${SRC_DIR}/u-boot" apply --whitespace=nowarn "${UBOOT_COMPAT_PATCH}"
}

apply_kernel_patch_series() {
  local series_file="${KERNEL_PATCH_DIR}/series"
  local patch_name=""
  local patch_path=""

  [[ -f "${series_file}" ]] || die "Missing kernel patch series: ${series_file}"

  while IFS= read -r patch_name || [[ -n "${patch_name}" ]]; do
    [[ -n "${patch_name}" && "${patch_name}" != \#* ]] || continue
    patch_path="${KERNEL_PATCH_DIR}/${patch_name}"
    [[ -f "${patch_path}" ]] || die "Missing kernel patch listed by series: ${patch_path}"

    log "Applying Linux patch ${patch_name}"
    git -C "${SRC_DIR}/linux" apply --check --whitespace=nowarn "${patch_path}"
    git -C "${SRC_DIR}/linux" apply --whitespace=nowarn "${patch_path}"
  done < "${series_file}"

  git -C "${SRC_DIR}/linux" diff --check
}

resolve_latest_opensbi_ref() {
  if [[ "${OPENSBI_REF}" != "latest" ]]; then
    OPENSBI_EFFECTIVE_REF="${OPENSBI_REF}"
    return
  fi

  OPENSBI_EFFECTIVE_REF="$(
    git ls-remote --tags "${OPENSBI_REPO}" \
      | awk '{print $2}' \
      | sed 's#refs/tags/##' \
      | grep -E '^v[0-9]+(\.[0-9]+)*$' \
      | sort -V \
      | tail -1
  )"

  [[ -n "${OPENSBI_EFFECTIVE_REF}" ]] || die "Unable to determine the latest OpenSBI release tag."
}

fetch_sources() {
  resolve_latest_opensbi_ref

  log "Fetching source trees"
  clone_ref "${KERNEL_REPO}" "${KERNEL_REF}" "${SRC_DIR}/linux"
  [[ "$(git -C "${SRC_DIR}/linux" rev-parse HEAD)" == "${KERNEL_COMMIT}" ]] || \
    die "Linux ${KERNEL_REF} did not resolve to the pinned commit ${KERNEL_COMMIT}"
  clone_ref "${UBOOT_REPO}" "${UBOOT_REF}" "${SRC_DIR}/u-boot"
  [[ "$(git -C "${SRC_DIR}/u-boot" rev-parse HEAD)" == "${UBOOT_COMMIT}" ]] || \
    die "U-Boot ${UBOOT_REF} did not resolve to the pinned commit ${UBOOT_COMMIT}"
  clone_ref "${OPENSBI_REPO}" "${OPENSBI_EFFECTIVE_REF}" "${SRC_DIR}/opensbi"
  [[ "$(git -C "${SRC_DIR}/opensbi" rev-parse HEAD)" == "${OPENSBI_COMMIT}" ]] || \
    die "OpenSBI ${OPENSBI_EFFECTIVE_REF} did not resolve to the pinned commit ${OPENSBI_COMMIT}"
  clone_ref "${SPL_TOOL_REPO}" "${SPL_TOOL_REF}" "${SRC_DIR}/tools"
  [[ "$(git -C "${SRC_DIR}/tools" rev-parse HEAD)" == "${SPL_TOOL_COMMIT}" ]] || \
    die "SPL tool ${SPL_TOOL_REF} did not resolve to the pinned commit ${SPL_TOOL_COMMIT}"
  apply_kernel_patch_series
  apply_u_boot_compat_patches
}

build_spl_tool() {
  log "Building StarFive spl_tool"
  make -C "${SRC_DIR}/tools/spl_tool" clean >/dev/null
  make -C "${SRC_DIR}/tools/spl_tool" >/dev/null
}

build_opensbi_payload() {
  local opensbi_build="${BUILD_DIR}/opensbi"
  local build_log="${BUILD_DIR}/opensbi-build.log"
  local uboot_bin="${BUILD_DIR}/u-boot/u-boot.bin"
  local uboot_dtb="${BUILD_DIR}/u-boot/arch/riscv/dts/pine64_pinetabv.dtb"
  local payload="${opensbi_build}/platform/generic/firmware/fw_payload.bin"
  local payload_elf="${opensbi_build}/platform/generic/firmware/fw_payload.elf"
  local nm_symbols="${opensbi_build}/fw_payload.nm"
  local fw_start=""
  local fw_end=""
  local fw_fdt=""
  local payload_start=""
  local address=""
  local fdt_destination=$((0x42200000))
  local fdt_source_offset=0
  local payload_offset=0
  local uboot_size=0
  local uboot_dtb_size=0

  [[ -s "${uboot_bin}" ]] || die "U-Boot payload not found: ${uboot_bin}"
  [[ -s "${uboot_dtb}" ]] || die "U-Boot PineTab-V DTB not found: ${uboot_dtb}"

  log "Building OpenSBI ${OPENSBI_EFFECTIVE_REF} with the PineTab-V U-Boot payload"
  make -C "${SRC_DIR}/opensbi" O="${opensbi_build}" clean >/dev/null 2>&1 || true
  if ! make -C "${SRC_DIR}/opensbi" \
      O="${opensbi_build}" \
      PLATFORM=generic \
      CROSS_COMPILE="${CROSS_COMPILE}" \
      FW_PAYLOAD_PATH="${uboot_bin}" \
      FW_FDT_PATH="${uboot_dtb}" \
      FW_PAYLOAD_FDT_OFFSET=0x2200000 \
      FW_TEXT_START=0x40000000 \
      -j "${JOBS}" >"${build_log}" 2>&1; then
    warn "OpenSBI build failed; the last 100 log lines follow."
    tail -n 100 "${build_log}" >&2
    die "OpenSBI build failed. Full log: ${build_log}"
  fi

  [[ -s "${payload}" ]] || die "OpenSBI payload was not generated: ${payload}"
  [[ -s "${payload_elf}" ]] || die "OpenSBI payload ELF was not generated: ${payload_elf}"

  "${CROSS_COMPILE}nm" -n "${payload_elf}" > "${nm_symbols}"
  fw_start="$(
    awk '$3 == "_fw_start" { value = "0x" $1; count++ }
         END { if (count == 1) print value }' "${nm_symbols}"
  )"
  fw_end="$(
    awk '$3 == "_fw_end" { value = "0x" $1; count++ }
         END { if (count == 1) print value }' "${nm_symbols}"
  )"
  fw_fdt="$(
    awk '$3 == "fw_fdt_bin" { value = "0x" $1; count++ }
         END { if (count == 1) print value }' "${nm_symbols}"
  )"
  payload_start="$(
    awk '$3 == "payload_bin" { value = "0x" $1; count++ }
         END { if (count == 1) print value }' "${nm_symbols}"
  )"
  for address in "${fw_start}" "${fw_end}" "${fw_fdt}" "${payload_start}"; do
    [[ "${address}" =~ ^0x[0-9a-fA-F]+$ ]] || \
      die "Could not validate the OpenSBI firmware layout."
  done
  (( fw_start == 0x40000000 )) || die "OpenSBI has the wrong JH7110 load address."
  (( payload_start == 0x40200000 )) || die "U-Boot has the wrong payload address."
  (( fw_end < payload_start )) || die "OpenSBI overlaps its U-Boot payload."

  uboot_size="$(stat -c %s "${uboot_bin}")"
  uboot_dtb_size="$(stat -c %s "${uboot_dtb}")"
  payload_offset=$((payload_start - fw_start))
  fdt_source_offset=$((fw_fdt - fw_start))
  (( payload_start + uboot_size <= fdt_destination )) || \
    die "U-Boot overlaps OpenSBI's relocated device-tree workspace."
  (( fdt_destination + 0x100000 < 0x43900000 )) || \
    die "OpenSBI lacks a safe device-tree workspace below scriptaddr."
  cmp -s -n "${uboot_size}" -i "${payload_offset}:0" \
    "${payload}" "${uboot_bin}" || \
    die "OpenSBI did not embed the exact PineTab-V U-Boot binary."
  cmp -s -n "${uboot_dtb_size}" -i "${fdt_source_offset}:0" \
    "${payload}" "${uboot_dtb}" || \
    die "OpenSBI did not embed the exact PineTab-V U-Boot device tree."

  grep -aFq 'OpenSBI' "${payload}" || \
    die "The generated firmware payload does not contain OpenSBI."
  grep -aFq 'U-Boot 2021.10' "${payload}" || \
    die "The generated firmware payload does not contain PineTab-V U-Boot."

  log "Verified the OpenSBI/PineTab-V U-Boot payload"
}

build_uboot_fit() {
  local uboot_build="${BUILD_DIR}/u-boot"
  local opensbi_payload="${BUILD_DIR}/opensbi/platform/generic/firmware/fw_payload.bin"
  local its_source="${SRC_DIR}/tools/uboot_its/visionfive2-uboot-fit-image.its"
  local fit_build="${BUILD_DIR}/u-boot-fit"
  local fit_image="${uboot_build}/u-boot.itb"
  local extracted_payload="${fit_build}/fw_payload.extracted.bin"
  local fit_listing="${fit_build}/u-boot.itb.list"

  log "Packaging the verified OpenSBI/U-Boot FIT"

  [[ -s "${opensbi_payload}" ]] || die "Missing OpenSBI/U-Boot payload: ${opensbi_payload}"
  [[ -s "${its_source}" ]] || die "Missing StarFive U-Boot FIT description: ${its_source}"
  [[ -x "${uboot_build}/tools/mkimage" ]] || die "U-Boot mkimage was not built."
  [[ -x "${uboot_build}/tools/dumpimage" ]] || die "U-Boot dumpimage was not built."

  install -d "${fit_build}"
  install -m644 "${its_source}" "${fit_build}/visionfive2-uboot-fit-image.its"
  install -m644 "${opensbi_payload}" "${fit_build}/fw_payload.bin"
  (
    cd "${fit_build}"
    "${uboot_build}/tools/mkimage" \
      -f visionfive2-uboot-fit-image.its \
      -A riscv -O u-boot -T firmware "${fit_image}" >/dev/null
  )

  "${uboot_build}/tools/dumpimage" -l "${fit_image}" > "${fit_listing}"
  grep -Fq 'U-boot-spl FIT image for JH7110 VisionFive2' "${fit_listing}" || \
    die "The loader FIT is not a StarFive JH7110 firmware image."
  grep -Fq 'Load Address: 0x40000000' "${fit_listing}" || \
    die "The loader FIT has the wrong JH7110 firmware load address."
  "${uboot_build}/tools/dumpimage" \
    -T flat_dt -p 0 -o "${extracted_payload}" "${fit_image}" >/dev/null
  cmp -s "${opensbi_payload}" "${extracted_payload}" || \
    die "The loader FIT does not contain the generated OpenSBI/U-Boot payload."

  INSTALLED_UBOOT_IMAGE="${fit_image}"
  log "Verified the JH7110 OpenSBI/U-Boot FIT"
}

assert_kernel_config_state() {
  local config_file="$1"
  local expected="$2"
  local state=""
  local symbol=""

  shift 2
  for symbol in "$@"; do
    state="$("${SRC_DIR}/linux/scripts/config" --file "${config_file}" --state "${symbol}")"
    [[ "${state}" == "${expected}" ]] || \
      die "Kernel configuration lost CONFIG_${symbol}=${expected} (resolved to ${state})."
  done
}

assert_kernel_config_not_enabled() {
  local config_file="$1"
  local state=""
  local symbol=""

  shift
  for symbol in "$@"; do
    state="$("${SRC_DIR}/linux/scripts/config" --file "${config_file}" --state "${symbol}")"
    [[ "${state}" == "n" || "${state}" == "undef" ]] || \
      die "Kernel configuration unexpectedly enabled CONFIG_${symbol}=${state}."
  done
}

kernel_configure() {
  local kernel_src="${SRC_DIR}/linux"
  local kernel_build="${BUILD_DIR}/linux"
  local config_tool="${kernel_src}/scripts/config"
  local drm_symbol=""

  log "Configuring PineTab-V kernel"
  make -C "${kernel_src}" \
    O="${kernel_build}" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    "${KERNEL_DEFCONFIG}" >/dev/null

  "${config_tool}" --file "${kernel_build}/.config" \
    --set-str LOCALVERSION -pinetabv \
    --disable LOCALVERSION_AUTO \
    --disable RISCV_USER_CFI \
    --enable SECCOMP \
    --enable DEVTMPFS \
    --enable DEVTMPFS_MOUNT \
    --enable TMPFS \
    --enable EXT4_FS \
    --enable CMA \
    --enable DMA_CMA \
    --enable SERIAL_8250 \
    --enable SERIAL_8250_CONSOLE \
    --enable SERIAL_OF_PLATFORM \
    --enable VT \
    --enable VT_CONSOLE \
    --enable FRAMEBUFFER_CONSOLE \
    --enable CACHEMAINT_FOR_DMA \
    --enable SIFIVE_CCACHE \
    --enable INPUT_EVDEV \
    --enable HID \
    --enable HID_GENERIC \
    --enable HID_MULTITOUCH \
    --enable USB_HID \
    --enable RFKILL \
    --enable RFKILL_GPIO \
    --enable BT \
    --enable BT_BREDR \
    --enable BT_LE \
    --module BT_RFCOMM \
    --module BT_BNEP \
    --module BT_HIDP \
    --module BT_HCIBTUSB \
    --enable BT_HCIBTUSB_RTL \
    --enable KEYBOARD_GPIO \
    --enable POWER_RESET_GPIO_RESTART \
    --enable FRAMEBUFFER_CONSOLE_ROTATION \
    --enable I2C \
    --enable I2C_GPIO \
    --enable I2C_DESIGNWARE_PLATFORM \
    --enable EEPROM_AT24 \
    --enable NEW_LEDS \
    --enable LEDS_CLASS \
    --enable LEDS_GPIO \
    --enable RTC_CLASS \
    --enable RTC_DRV_HYM8563 \
    --enable INPUT_TOUCHSCREEN \
    --enable TOUCHSCREEN_GOODIX \
    --enable MFD_AXP20X_I2C \
    --enable REGULATOR_AXP20X \
    --enable BATTERY_CW2015 \
    --enable CHARGER_BQ25890 \
    --enable REGULATOR_FIXED_VOLTAGE \
    --enable PCI \
    --enable PCIE_STARFIVE_HOST \
    --enable PHY_STARFIVE_JH7110_PCIE \
    --enable BLK_DEV_NVME \
    --enable USB_SUPPORT \
    --enable USB \
    --enable USB_XHCI_HCD \
    --enable USB_CDNS_SUPPORT \
    --enable USB_CDNS3 \
    --enable USB_CDNS3_HOST \
    --enable USB_CDNS3_STARFIVE \
    --enable PHY_STARFIVE_JH7110_USB \
    --enable MMC \
    --enable MMC_BLOCK \
    --enable MMC_DW \
    --enable MMC_DW_STARFIVE \
    --enable MTD \
    --enable MTD_SPI_NOR \
    --enable SPI_CADENCE_QUADSPI \
    --enable HWMON \
    --enable SENSORS_SFCTEMP \
    --enable WATCHDOG \
    --enable STARFIVE_WATCHDOG \
    --enable CPU_FREQ \
    --enable CPUFREQ_DT \
    --enable IIO_ST_ACCEL_3AXIS \
    --enable IIO_ST_ACCEL_I2C_3AXIS \
    --enable PWM_OCORES \
    --enable BACKLIGHT_CLASS_DEVICE \
    --enable BACKLIGHT_PWM \
    --enable DRM \
    --enable DRM_FBDEV_EMULATION \
    --enable DRM_VERISILICON_DC \
    --enable DRM_CDNS_DSI \
    --enable DRM_CDNS_DSI_JH7110 \
    --enable DRM_PANEL_BOE_TH101MB31UIG002_28A \
    --enable CLK_STARFIVE_JH7110_VOUT \
    --enable PHY_STARFIVE_JH7110_DPHY_TX \
    --module DRM_POWERVR \
    --enable MEDIA_SUPPORT \
    --enable MEDIA_SUPPORT_FILTER \
    --enable MEDIA_CAMERA_SUPPORT \
    --enable MEDIA_PLATFORM_SUPPORT \
    --enable VIDEO_DEV \
    --enable V4L_PLATFORM_DRIVERS \
    --enable STAGING \
    --enable STAGING_MEDIA \
    --enable CLK_STARFIVE_JH7110_ISP \
    --module VIDEO_CADENCE_CSI2RX \
    --module VIDEO_STARFIVE_CAMSS \
    --module PHY_STARFIVE_JH7110_DPHY_RX \
    --enable MUX_GPIO \
    --module VIDEO_MUX \
    --module VIDEO_GC02M2 \
    --module VIDEO_OV5640 \
    --enable SOUND \
    --enable SND \
    --enable SND_SOC \
    --enable SND_DESIGNWARE_I2S \
    --enable SND_SOC_ES8316 \
    --enable SND_SOC_SIMPLE_AMPLIFIER \
    --enable SND_SIMPLE_CARD \
    --enable WLAN \
    --module CFG80211 \
    --enable CFG80211_REQUIRE_SIGNED_REGDB \
    --enable CFG80211_USE_KERNEL_REGDB_KEYS \
    --module MAC80211 \
    --module RTW89 \
    --module RTW89_8852BU

  # The generic RISC-V defconfig enables display drivers for unrelated SoCs.
  # Keep only the DC8200, JH7110 Cadence DSI, BOE panel, and PowerVR hardware
  # drivers needed by PineTab-V.  Required DRM core/helper code remains enabled.
  for drm_symbol in "${PINETABV_DRM_EXCLUDED[@]}"; do
    "${config_tool}" --file "${kernel_build}/.config" --disable "${drm_symbol}"
  done

  make -C "${kernel_src}" \
    O="${kernel_build}" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    olddefconfig >/dev/null

  # JH7110's U74 cores do not implement Zicfilp or Zicfiss.  Keep the
  # optional CFI vDSO disabled instead of emitting GNU property notes for
  # instructions this board cannot select at runtime.
  assert_kernel_config_state "${kernel_build}/.config" n \
    LOCALVERSION_AUTO
  # Toolchains that cannot emit Zicfiss/Zicfilp code hide RISCV_USER_CFI
  # completely; either an explicit n or an unavailable symbol is correct.
  assert_kernel_config_not_enabled "${kernel_build}/.config" \
    RISCV_USER_CFI
  assert_kernel_config_state "${kernel_build}/.config" y \
    SECCOMP DEVTMPFS DEVTMPFS_MOUNT TMPFS EXT4_FS CMA DMA_CMA \
    SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_OF_PLATFORM \
    VT VT_CONSOLE FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION \
    CACHEMAINT_FOR_DMA SIFIVE_CCACHE INPUT_EVDEV \
    HID HID_GENERIC HID_MULTITOUCH USB_HID \
    RFKILL RFKILL_GPIO BT BT_BREDR BT_LE BT_HCIBTUSB_RTL \
    KEYBOARD_GPIO POWER_RESET_GPIO_RESTART \
    FRAMEBUFFER_CONSOLE_ROTATION I2C I2C_GPIO I2C_DESIGNWARE_PLATFORM \
    EEPROM_AT24 NEW_LEDS LEDS_CLASS LEDS_GPIO RTC_CLASS RTC_DRV_HYM8563 \
    INPUT_TOUCHSCREEN TOUCHSCREEN_GOODIX MFD_AXP20X_I2C \
    REGULATOR_AXP20X REGULATOR_FIXED_VOLTAGE BATTERY_CW2015 \
    CHARGER_BQ25890 PCI PCIE_STARFIVE_HOST PHY_STARFIVE_JH7110_PCIE \
    BLK_DEV_NVME USB_SUPPORT USB USB_XHCI_HCD USB_CDNS_SUPPORT USB_CDNS3 \
    USB_CDNS3_HOST USB_CDNS3_STARFIVE PHY_STARFIVE_JH7110_USB \
    MMC MMC_BLOCK MMC_DW MMC_DW_STARFIVE MTD MTD_SPI_NOR \
    SPI_CADENCE_QUADSPI HWMON SENSORS_SFCTEMP WATCHDOG STARFIVE_WATCHDOG \
    CPU_FREQ CPUFREQ_DT IIO_ST_ACCEL_3AXIS IIO_ST_ACCEL_I2C_3AXIS \
    IIO_ST_SENSORS_CORE IIO_ST_SENSORS_I2C PWM_OCORES \
    BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM DRM DRM_VERISILICON_DC \
    DRM_CDNS_DSI DRM_CDNS_DSI_JH7110 \
    DRM_PANEL_BOE_TH101MB31UIG002_28A CLK_STARFIVE_JH7110_VOUT \
    PHY_STARFIVE_JH7110_DPHY_TX MEDIA_SUPPORT MEDIA_SUPPORT_FILTER \
    MEDIA_CAMERA_SUPPORT MEDIA_PLATFORM_SUPPORT VIDEO_DEV \
    V4L_PLATFORM_DRIVERS STAGING STAGING_MEDIA CLK_STARFIVE_JH7110_ISP \
    MUX_GPIO SOUND SND SND_SOC SND_DESIGNWARE_I2S SND_SOC_ES8316 \
    SND_SOC_SIMPLE_AMPLIFIER SND_SIMPLE_CARD WLAN \
    CFG80211_REQUIRE_SIGNED_REGDB CFG80211_USE_KERNEL_REGDB_KEYS
  assert_kernel_config_state "${kernel_build}/.config" m \
    BT_RFCOMM BT_BNEP BT_HIDP BT_HCIBTUSB \
    DRM_POWERVR VIDEO_CADENCE_CSI2RX VIDEO_STARFIVE_CAMSS \
    PHY_STARFIVE_JH7110_DPHY_RX VIDEO_MUX VIDEO_GC02M2 VIDEO_OV5640 \
    CFG80211 MAC80211 RTW89 RTW89_8852BU
  assert_kernel_config_not_enabled "${kernel_build}/.config" \
    "${PINETABV_DRM_EXCLUDED[@]}" \
    DRM_NOUVEAU_BACKLIGHT DRM_NOUVEAU_CH7006 DRM_NOUVEAU_SIL164 \
    DRM_SUN6I_DSI DRM_SUN8I_DW_HDMI DRM_SUN8I_MIXER \
    DRM_SUN8I_TCON_TOP DRM_VIRTIO_GPU_KMS DRM_TTM DRM_TTM_HELPER \
    DRM_SUBALLOC_HELPER DRM_DISPLAY_DP_HELPER FB_EFI FB_SIMPLE \
    SYSFB_SIMPLEFB
}

verify_built_pinetabv_dtbs() {
  local dtb_dir="${BUILD_DIR}/linux/arch/riscv/boot/dts/starfive"
  local dtb=""
  local dtb_name=""
  local dc_clock_names=""
  local dc_reset_names=""
  local panel_compatible=""
  local panel_reg=""
  local reset_names=""
  local accelerometer_compatible=""
  local -a accelerometer_matrix=()
  local sound_links=""
  local sysgpio_children=""
  local forbidden_gpio_group=""
  local bitclock_master=""
  local brightness_default=""
  local brightness_steps=""
  local codec_dai=""
  local codec_phandle=""
  local cpu0_dai=""
  local cpu1_dai=""
  local frame_master=""
  local i2srx_phandle=""
  local i2stx1_phandle=""
  local link_codec_phandle=""
  local -a camera_gpio_cells=()
  local -a audio_pin_switches=()
  local -a brightness_level_cells=()
  local -a card_detect_gpio_cells=()
  local -a dc_clock_cells=()
  local -a dc_reset_cells=()
  local -a i2srx_pinctrl_cells=()
  local -a headphone_detect_gpio_cells=()
  local -a ov5640_powerdown_gpio_cells=()
  local -a reset_name_array=()
  local -a reset_gpio_cells=()
  local -a sound_link_array=()
  local -a volume_gpio_cells=()
  local volume_gpio_controller=""

  for dtb_name in \
    jh7110-pine64-pinetab-v-20230614.dtb \
    jh7110-pine64-pinetab-v-20240730.dtb; do
    dtb="${dtb_dir}/${dtb_name}"
    [[ -s "${dtb}" ]] || die "Missing freshly built PineTab-V DTB: ${dtb_name}"

    [[ "$(fdtget -t u "${dtb}" /gpio-keys/volume-down-key linux,code)" == 114 && \
       "$(fdtget -t u "${dtb}" /gpio-keys/volume-up-key linux,code)" == 115 ]] || \
      die "${dtb_name} has inverted volume keycodes."
    volume_gpio_controller="$(fdtget -t u "${dtb}" /soc/pinctrl@13040000 phandle)"
    read -r -a volume_gpio_cells <<< "$(fdtget -t u "${dtb}" /gpio-keys/volume-down-key gpios)"
    [[ "${volume_gpio_cells[*]}" == "${volume_gpio_controller} 49 1" ]] || \
      die "${dtb_name} does not use active-low system GPIO49 for volume down."
    read -r -a volume_gpio_cells <<< "$(fdtget -t u "${dtb}" /gpio-keys/volume-up-key gpios)"
    if [[ "${dtb_name}" == *20230614.dtb ]]; then
      [[ "${volume_gpio_cells[*]}" == "${volume_gpio_controller} 51 1" ]] || \
        die "${dtb_name} does not use active-low system GPIO51 for volume up."
    else
      volume_gpio_controller="$(fdtget -t u "${dtb}" /soc/pinctrl@17020000 phandle)"
      [[ "${volume_gpio_cells[*]}" == "${volume_gpio_controller} 0 0" ]] || \
        die "${dtb_name} does not use active-high AON GPIO0 for volume up."
    fi

    [[ "$(fdtget -t s "${dtb}" /soc/dsi@295d0000 status)" == "okay" ]] || \
      die "${dtb_name} does not enable the JH7110 DSI host."

    dc_clock_names="$(
      fdtget -t s "${dtb}" /soc/display@29400000 clock-names
    )"
    [[ "${dc_clock_names}" == "core axi ahb pix0 pix1 lcd noc" ]] || \
      die "${dtb_name} does not describe the complete DC8200 clock set."
    read -r -a dc_clock_cells <<< "$(
      fdtget -t u "${dtb}" /soc/display@29400000 clocks
    )"
    (( ${#dc_clock_cells[@]} == 14 )) && \
      [[ "${dc_clock_cells[13]}" == "60" ]] || \
      die "${dtb_name} does not own the JH7110 display NoC clock."

    dc_reset_names="$(
      fdtget -t s "${dtb}" /soc/display@29400000 reset-names
    )"
    [[ "${dc_reset_names}" == "core axi ahb noc" ]] || \
      die "${dtb_name} does not describe the complete DC8200 reset set."
    read -r -a dc_reset_cells <<< "$(
      fdtget -t u "${dtb}" /soc/display@29400000 resets
    )"
    (( ${#dc_reset_cells[@]} == 8 )) && \
      [[ "${dc_reset_cells[7]}" == "26" ]] || \
      die "${dtb_name} does not own the JH7110 display NoC reset."

    reset_names="$(fdtget -t s "${dtb}" /soc/dsi@295d0000 reset-names)"
    read -r -a reset_name_array <<< "${reset_names}"
    (( ${#reset_name_array[@]} == 6 )) || \
      die "${dtb_name} does not describe all six JH7110 DSI resets."
    [[ " ${reset_names} " == *" rxesc "* ]] || \
      die "${dtb_name} leaves the JH7110 DSI RX escape reset undescribed."

    panel_reg="$(fdtget -t u "${dtb}" /soc/dsi@295d0000/panel@0 reg)"
    [[ "${panel_reg}" == "0" ]] || \
      die "${dtb_name} does not use the vendor-confirmed DSI virtual channel 0."
    panel_compatible="$(
      fdtget -t s "${dtb}" /soc/dsi@295d0000/panel@0 compatible
    )"
    [[ "${panel_compatible}" == \
      "boe,th101mb31ig002-28a-pinetab-v boe,th101mb31ig002-28a" ]] || \
      die "${dtb_name} does not select the PineTab-V BOE/Jadard panel data."

    fdtget -t x "${dtb}" /soc/dsi@295d0000 starfive,vout-syscon \
      >/dev/null || die "${dtb_name} is missing the JH7110 LCD-to-DSI route."

    [[ "$(fdtget -t x "${dtb}" /reserved-memory/linux,cma alloc-ranges)" == \
      "0 70000000 0 60000000" ]] || \
      die "${dtb_name} does not constrain CMA to the DC8200 32-bit DMA window."

    read -r -a brightness_level_cells <<< "$(
      fdtget -t u "${dtb}" /backlight brightness-levels
    )"
    brightness_steps="$(
      fdtget -t u "${dtb}" /backlight num-interpolated-steps
    )"
    brightness_default="$(
      fdtget -t u "${dtb}" /backlight default-brightness-level
    )"
    (( ${#brightness_level_cells[@]} == 2 )) && \
      [[ "${brightness_level_cells[0]}" == "100" ]] && \
      [[ "${brightness_level_cells[1]}" == "0" ]] && \
      [[ "${brightness_steps}" == "100" ]] && \
      [[ "${brightness_default}" == "60" ]] || \
      die "${dtb_name} does not expose the verified 101-step backlight curve."

    read -r -a card_detect_gpio_cells <<< "$(
      fdtget -t u "${dtb}" /soc/mmc@16020000 cd-gpios
    )"
    (( ${#card_detect_gpio_cells[@]} == 3 )) && \
      [[ "${card_detect_gpio_cells[1]}" == "41" ]] && \
      [[ "${card_detect_gpio_cells[2]}" == "17" ]] || \
      die "${dtb_name} does not use active-low, pulled-up GPIO41 for microSD card detect."

    read -r -a camera_gpio_cells <<< "$(
      fdtget -t u "${dtb}" /mux-controller mux-gpios
    )"
    (( ${#camera_gpio_cells[@]} == 3 )) && \
      [[ "${camera_gpio_cells[1]}" == "53" ]] || \
      die "${dtb_name} does not use GPIO53 for camera selection."
    [[ "$(fdtget -t u "${dtb}" /video-mux default-input)" == "0" ]] || \
      die "${dtb_name} does not select the front camera as its default media input."

    read -r -a ov5640_powerdown_gpio_cells <<< "$(
      fdtget -t u "${dtb}" /soc/i2c@12060000/camera@3c powerdown-gpios
    )"
    (( ${#ov5640_powerdown_gpio_cells[@]} == 3 )) && \
      [[ "${ov5640_powerdown_gpio_cells[1]}" == "22" ]] && \
      [[ "${ov5640_powerdown_gpio_cells[2]}" == "0" ]] || \
      die "${dtb_name} does not use active-high GPIO22 for OV5640 power-down."

    sound_links="$(fdtget -l "${dtb}" /sound)"
    readarray -t sound_link_array <<< "${sound_links}"
    (( ${#sound_link_array[@]} == 1 )) && \
      [[ "${sound_link_array[0]}" == "simple-audio-card,dai-link@0" ]] || \
      die "${dtb_name} does not describe the unified PineTab-V audio link."
    [[ "$(fdtget -t s "${dtb}" /sound compatible)" == \
      "pine64,pinetab-v-soundcard" ]] || \
      die "${dtb_name} does not select the PineTab-V soundcard driver."
    [[ "$(fdtget -t s "${dtb}" /sound simple-audio-card,name)" == \
      "PineTab-V ES8316 Audio" ]] || \
      die "${dtb_name} does not expose the PineTab-V ES8316 audio card name."
    if fdtget -t x "${dtb}" /sound pinctrl-0 >/dev/null 2>&1; then
      die "${dtb_name} incorrectly leaves I2S pins owned by the sound card."
    fi

    read -r -a i2srx_pinctrl_cells <<< "$(
      fdtget -t x "${dtb}" /soc/i2s@100e0000 pinctrl-0
    )"
    (( ${#i2srx_pinctrl_cells[@]} == 3 )) || \
      die "${dtb_name} does not give all shared clock and RX pins to I2SRX."

    cpu0_dai="$(
      fdtget -t x "${dtb}" \
        /sound/simple-audio-card,dai-link@0/cpu-0 sound-dai
    )"
    cpu1_dai="$(
      fdtget -t x "${dtb}" \
        /sound/simple-audio-card,dai-link@0/cpu-1 sound-dai
    )"
    codec_dai="$(
      fdtget -t x "${dtb}" \
        /sound/simple-audio-card,dai-link@0/codec sound-dai
    )"
    i2srx_phandle="$(fdtget -t x "${dtb}" /soc/i2s@100e0000 phandle)"
    i2stx1_phandle="$(fdtget -t x "${dtb}" /soc/i2s@120c0000 phandle)"
    codec_phandle="$(
      fdtget -t x "${dtb}" /soc/i2c@10030000/audio-codec@11 phandle
    )"
    [[ "${cpu0_dai}" == "${i2srx_phandle}" ]] && \
      [[ "${cpu1_dai}" == "${i2stx1_phandle}" ]] && \
      [[ "${codec_dai}" == "${codec_phandle}" ]] || \
      die "${dtb_name} does not connect both I2S DAIs to the ES8316 codec."

    link_codec_phandle="$(
      fdtget -t x "${dtb}" \
        /sound/simple-audio-card,dai-link@0/codec phandle
    )"
    bitclock_master="$(
      fdtget -t x "${dtb}" /sound/simple-audio-card,dai-link@0 \
        bitclock-master
    )"
    frame_master="$(
      fdtget -t x "${dtb}" /sound/simple-audio-card,dai-link@0 \
        frame-master
    )"
    [[ "${bitclock_master}" == "${link_codec_phandle}" ]] && \
      [[ "${frame_master}" == "${link_codec_phandle}" ]] || \
      die "${dtb_name} does not configure ES8316 as the I2S clock master."

    read -r -a headphone_detect_gpio_cells <<< "$(
      fdtget -t u "${dtb}" /sound simple-audio-card,hp-det-gpios
    )"
    (( ${#headphone_detect_gpio_cells[@]} == 3 )) && \
      [[ "${headphone_detect_gpio_cells[1]}" == "36" ]] && \
      [[ "${headphone_detect_gpio_cells[2]}" == "1" ]] || \
      die "${dtb_name} does not use active-low GPIO36 for headset insertion."
    if fdtget -t u "${dtb}" /sound simple-audio-card,mic-det-gpios \
        >/dev/null 2>&1; then
      die "${dtb_name} incorrectly treats strapped GPIO13 as a microphone detector."
    fi

    read -r -a audio_pin_switches <<< "$(
      fdtget -t s "${dtb}" /sound simple-audio-card,pin-switches
    )"
    [[ "${audio_pin_switches[*]}" == \
      "Internal Microphone Headset Microphone Internal Speakers" ]] || \
      die "${dtb_name} does not expose the routed PineTab-V audio endpoints."

    sysgpio_children="$(fdtget -l "${dtb}" /soc/pinctrl@13040000)"
    for forbidden_gpio_group in \
      camera-selector-0 gc02m2-0 ov5640-0; do
      if grep -Fqx "${forbidden_gpio_group}" <<< "${sysgpio_children}"; then
        die "${dtb_name} gives ${forbidden_gpio_group} duplicate GPIO and pinctrl ownership."
      fi
    done
    if fdtget -l "${dtb}" /soc/pinctrl@13040000/mmc1-0 | \
        grep -Fqx cd-pins; then
      die "${dtb_name} gives microSD card detect duplicate GPIO and pinctrl ownership."
    fi
  done

  dtb="${dtb_dir}/jh7110-pine64-pinetab-v-20230614.dtb"
  if fdtget -t u "${dtb}" /soc/dsi@295d0000/panel@0 reset-gpios \
      >/dev/null 2>&1; then
    die "The 20230614 DTB must not drive GPIO51, which is its volume-up key."
  fi

  dtb="${dtb_dir}/jh7110-pine64-pinetab-v-20240730.dtb"
  read -r -a reset_gpio_cells <<< "$(
    fdtget -t u "${dtb}" /soc/dsi@295d0000/panel@0 reset-gpios
  )"
  (( ${#reset_gpio_cells[@]} == 3 )) && \
    [[ "${reset_gpio_cells[1]}" == "51" ]] && \
    [[ "${reset_gpio_cells[2]}" == "1" ]] || \
    die "The 20240730 DTB does not describe active-low panel reset on GPIO51."

  accelerometer_compatible="$(
    fdtget -t s "${dtb}" /soc/i2c@10030000/accelerometer@18 compatible
  )"
  [[ "${accelerometer_compatible}" == "silan,sc7a20" ]] || \
    die "The 20240730 DTB does not describe the PineTab-V SC7A20 accelerometer."
  read -r -a accelerometer_matrix <<< "$(
    fdtget -t s "${dtb}" /soc/i2c@10030000/accelerometer@18 mount-matrix
  )"
  [[ "${accelerometer_matrix[*]}" == \
    "0 0 -1 1 0 0 0 -1 0" ]] || \
    die "The 20240730 DTB has the wrong PineTab-V accelerometer mount matrix."

  log "Verified both PineTab-V DTBs, display, camera, audio and IIO topology"
}

build_kernel() {
  local image_size=0

  kernel_configure

  log "Building PineTab-V kernel"
  make -C "${SRC_DIR}/linux" \
    O="${BUILD_DIR}/linux" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    LOCALVERSION= \
    -j "${JOBS}" \
    Image modules dtbs >/dev/null

  grep -aFq $'model name\t: %s' \
    "${BUILD_DIR}/linux/arch/riscv/boot/Image" || \
    die "The kernel Image lacks the RISC-V CPU model-name compatibility field."
  verify_built_pinetabv_dtbs

  KERNEL_RELEASE="$(
    make -s -C "${SRC_DIR}/linux" \
      O="${BUILD_DIR}/linux" \
      ARCH=riscv \
      CROSS_COMPILE="${CROSS_COMPILE}" \
      LOCALVERSION= \
      kernelrelease
  )"
  [[ "${KERNEL_RELEASE}" == "7.3.0-pinetabv" ]] || \
    die "Unexpected kernel release: ${KERNEL_RELEASE}"

  image_size="$(stat -c %s "${BUILD_DIR}/linux/arch/riscv/boot/Image")"
  (( 0x40200000 + image_size < 0x42200000 )) || \
    die "The Linux Image overlaps OpenSBI's relocated device-tree workspace."
}

build_uboot() {
  local board_source="${SRC_DIR}/u-boot/board/pine64/pinetabv/starfive_visionfive2.c"
  local uboot_config="${BUILD_DIR}/u-boot/.config"

  log "Building PineTab-V U-Boot"
  make -C "${SRC_DIR}/u-boot" \
    O="${BUILD_DIR}/u-boot" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    "${UBOOT_DEFCONFIG}" >/dev/null

  grep -Fqx 'CONFIG_OF_SEPARATE=y' "${uboot_config}" || \
    die "PineTab-V U-Boot did not enable its external control DTB."
  grep -Fqx 'CONFIG_ENV_IS_NOWHERE=y' "${uboot_config}" || \
    die "PineTab-V U-Boot could still consume stale SPI environment state."
  if grep -Fqx 'CONFIG_ENV_IS_IN_SPI_FLASH=y' "${uboot_config}"; then
    die "PineTab-V U-Boot unexpectedly enabled the persistent SPI environment."
  fi
  if grep -Eq 'uclass_get_device\(UCLASS_VIDEO|video_bmp_display' \
      "${board_source}"; then
    die "PineTab-V U-Boot still has a boot-fatal board video probe."
  fi

  make -C "${SRC_DIR}/u-boot" \
    O="${BUILD_DIR}/u-boot" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    -j "${JOBS}" >/dev/null

  "${SRC_DIR}/tools/spl_tool/spl_tool" -c -f "${BUILD_DIR}/u-boot/spl/u-boot-spl.bin" >/dev/null
  INSTALLED_SPL_IMAGE="${BUILD_DIR}/u-boot/spl/u-boot-spl.bin.normal.out"
  [[ -s "${INSTALLED_SPL_IMAGE}" ]] || die "StarFive SPL image was not generated."
}

prompt_for_root_password() {
  if [[ -n "${ROOT_PASSWORD_HASH}" ]]; then
    return
  fi

  if [[ -n "${ROOT_PASSWORD}" ]]; then
    ROOT_PASSWORD_HASH="$(openssl passwd -6 "${ROOT_PASSWORD}")"
    ROOT_PASSWORD=""
    return
  fi

  if [[ ! -t 0 ]]; then
    die "Set ROOT_PASSWORD or ROOT_PASSWORD_HASH when running non-interactively."
  fi

  local first=""
  local second=""
  while true; do
    read -rsp "Root password for the PineTab-V image: " first
    printf '\n' >&2
    read -rsp "Confirm root password: " second
    printf '\n' >&2

    if [[ -z "${first}" ]]; then
      warn "Password must not be empty."
      continue
    fi
    if [[ "${first}" != "${second}" ]]; then
      warn "Passwords did not match."
      continue
    fi

    ROOT_PASSWORD_HASH="$(openssl passwd -6 "${first}")"
    break
  done
}

set_shadow_hash() {
  local shadow_file="$1"
  local user_name="$2"
  local hash_value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -F: -v OFS=: -v user="${user_name}" -v hash="${hash_value}" '
    $1 == user { $2 = hash }
    { print }
  ' "${shadow_file}" > "${tmp_file}"
  mv "${tmp_file}" "${shadow_file}"
  chmod 600 "${shadow_file}"
}

install_pinetabv_audio_ucm() {
  local ucm_dir="${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV"
  local ucm_link_dir="${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard"
  local acp_file=""

  log "Installing the PineTab-V ES8316 ALSA UCM profile"
  install -d "${ucm_dir}" "${ucm_link_dir}"

  cat > "${ucm_dir}/PineTab-V.conf" <<'EOF'
Syntax 3

Comment "Pine64 PineTab-V ES8316 audio"

SectionUseCase."HiFi" {
	File "/PineTabV/HiFi.conf"
	Comment "Play and capture HiFi audio"
}

BootSequence [
	cset "name='Headphone Playback Volume' 3"
	cset "name='Headphone Mixer Volume' 11"
	cset "name='DAC Playback Volume' 192"
	cset "name='ALC Capture Switch' off"
	cset "name='ADC Capture Volume' 192"
	cset "name='ADC PGA Gain Volume' 7"
	cset "name='Left Headphone Mixer Left DAC Switch' on"
	cset "name='Right Headphone Mixer Right DAC Switch' on"
	cset "name='Internal Speakers Switch' on"
	cset "name='Headset Microphone Switch' off"
	cset "name='Internal Microphone Switch' on"
]
EOF

  cat > "${ucm_dir}/HiFi.conf" <<'EOF'
# Reapply path controls when enabling HiFi, including on existing tablets
# whose alsactl state predates this profile. Do not restore analog bypasses.
SectionVerb {
	EnableSequence [
		cset "name='DAC Soft Ramp Switch' on"
		cset "name='Left Headphone Mixer LLIN Switch' off"
		cset "name='Right Headphone Mixer RLIN Switch' off"
		cset "name='Left Headphone Mixer Left DAC Switch' on"
		cset "name='Right Headphone Mixer Right DAC Switch' on"
	]
}

# The vendor DT orders JH7110 I2S RX first and I2S TX second.  With its
# direct-link topology ALSA consequently exposes capture as PCM 0 and
# playback as PCM 1.
SectionDevice."Speaker" {
	Comment "Internal Speakers"

	ConflictingDevice [
		"Headphones"
	]

	EnableSequence [
		cset "name='Internal Speakers Switch' on"
	]

	DisableSequence [
		cset "name='Internal Speakers Switch' off"
	]

	Value {
		PlaybackPriority 100
		PlaybackPCM "hw:${CardId},1"
		PlaybackMixerElem "Headphone Mixer"
		PlaybackMasterElem "DAC"
	}
}

SectionDevice."Headphones" {
	Comment "Headphones"

	ConflictingDevice [
		"Speaker"
	]

	EnableSequence [
		cset "name='Internal Speakers Switch' off"
	]

	Value {
		PlaybackPriority 200
		PlaybackPCM "hw:${CardId},1"
		PlaybackMixerElem "Headphone Mixer"
		PlaybackMasterElem "DAC"
		JackControl "Headphones Jack"
		JackHWMute "Speaker"
	}
}

SectionDevice."Mic" {
	Comment "Internal Microphone"

	ConflictingDevice [
		"Headset"
	]

	EnableSequence [
		cset "name='Headset Microphone Switch' off"
		cset "name='Internal Microphone Switch' on"
		cset "name='Differential Mux' lin2-rin2"
	]

	DisableSequence [
		cset "name='Internal Microphone Switch' off"
	]

	Value {
		CapturePriority 200
		CapturePCM "hw:${CardId},0"
		CaptureMixerElem "ADC PGA Gain"
		CaptureMasterElem "ADC"
	}
}

SectionDevice."Headset" {
	Comment "Headset Microphone"

	ConflictingDevice [
		"Mic"
	]

	EnableSequence [
		cset "name='Internal Microphone Switch' off"
		cset "name='Headset Microphone Switch' on"
		cset "name='Differential Mux' lin1-rin1"
	]

	DisableSequence [
		cset "name='Headset Microphone Switch' off"
	]

	Value {
		# The board detects insertion only, not the presence of a mic.
		# Keep this a manual choice and prefer the internal microphone.
		CapturePriority 100
		CapturePCM "hw:${CardId},0"
		CaptureMixerElem "ADC PGA Gain"
		CaptureMasterElem "ADC"
	}
}
EOF

  ln -snf ../../PineTabV/PineTab-V.conf \
    "${ucm_link_dir}/PineTab-V.conf"
  ln -snf ../../PineTabV/PineTab-V.conf \
    "${ucm_link_dir}/PineTab-V ES8316 Audio.conf"

  # UCM exposes conflicting device combinations as whole-card profiles.
  # Use one duplex ACP profile and independent hardware paths for the desktop.
  install -Dm644 "${SELF_DIR}/support/audio/pinetabv.conf" \
    "${ROOT_MNT}/usr/share/alsa-card-profile/mixer/profile-sets/pinetabv.conf"
  for acp_file in pinetabv-output-speaker pinetabv-output-headphones \
      pinetabv-output-off pinetabv-input-internal-mic \
      pinetabv-input-headset-mic pinetabv-input-off; do
    install -Dm644 "${SELF_DIR}/support/audio/${acp_file}.conf" \
      "${ROOT_MNT}/usr/share/alsa-card-profile/mixer/paths/${acp_file}.conf"
  done

  install -d "${ROOT_MNT}/etc/wireplumber/wireplumber.conf.d"
  cat > "${ROOT_MNT}/etc/wireplumber/wireplumber.conf.d/51-pinetabv-audio.conf" <<'EOF'
# Only the PineTab-V codec: USB and Bluetooth audio keep their own policy.
monitor.alsa.rules = [
  {
    matches = [ { api.alsa.card.name = "PineTab-V ES8316 Audio" } ]
    actions = { update-props = {
      api.alsa.soft-mixer = true
      api.alsa.use-ucm = false
      device.profile-set = "pinetabv.conf"
      device.profile = "HiFi"
      api.acp.disable-pro-audio = true
      api.acp.probe-rate = 48000
    } }
  }
  {
    # The codec's fixed MCLK is 12.288 MHz and both DAIs share its clocks.
    matches = [ { alsa.card_name = "PineTab-V ES8316 Audio" } ]
    actions = { update-props = {
      audio.rate = 48000
      audio.allowed-rates = [ 48000 ]
    } }
  }
  {
    matches = [ {
      alsa.card_name = "PineTab-V ES8316 Audio"
      media.class = "Audio/Sink"
    } ]
    # The speaker amplifier is noisy during idle power transitions. Release
    # playback promptly instead of keeping it powered with a silent stream.
    actions = { update-props = {
      node.pause-on-idle = false
      session.suspend-timeout-seconds = 1
    } }
  }
]
EOF
}

install_pinetabv_input_policy() {
  local quirks_dir="${ROOT_MNT}/etc/libinput"
  local quirks_file="${quirks_dir}/local-overrides.quirks"

  log "Installing the PineTab-V keyboard-cover touchpad policy"
  install -d "${quirks_dir}"
  cat > "${quirks_file}" <<'EOF'
[PineTab-V Keyboard Cover Touchpad]
MatchName=HID 1018:1006 Touchpad
MatchBus=usb
MatchVendor=0x1018
MatchProduct=0x1006
MatchUdevType=touchpad
MatchDeviceTree=pine64,pinetab-v-*
AttrEventCode=-BTN_RIGHT
AttrInputProp=+INPUT_PROP_BUTTONPAD
EOF
}

install_pinetabv_input_diagnostics() {
  install -Dm755 "${SELF_DIR}/tests/collect-pinetabv-input.sh" \
    "${ROOT_MNT}/usr/local/sbin/pinetabv-input-report"
}

install_pinetabv_settings_compat() {
  local launcher="${ROOT_MNT}/usr/local/bin/gnome-control-center"
  local service="${ROOT_MNT}/usr/local/share/dbus-1/services/org.gnome.Settings.service"

  log "Installing the PineTab-V GNOME Settings compatibility launcher"
  install -d "$(dirname "${launcher}")" "$(dirname "${service}")"
  cat > "${launcher}" <<'EOF'
#!/bin/sh
# Board-scoped workaround for Settings closing on Mouse & Touchpad.
# That panel creates WebM illustrations. Avoid its media/experimental GPU paths
# until a tablet crash backtrace identifies the exact upstream failure.
# GTK documents these controls at https://docs.gtk.org/gtk4/running.html.
# Explicit environment choices remain available for diagnosis.
if [ -r /proc/device-tree/compatible ] &&
   tr '\000' '\n' < /proc/device-tree/compatible | grep -Fqx 'pine64,pinetab-v'; then
  export GSK_RENDERER="${GSK_RENDERER:-cairo}"
  export GTK_MEDIA="${GTK_MEDIA:-none}"
fi
exec /usr/bin/gnome-control-center "$@"
EOF
  chmod 755 "${launcher}"
  # GNOME 48's desktop files use Exec=gnome-control-center [panel], so the
  # /usr/local/bin PATH override preserves their translations and search terms.
  # Its D-Bus service uses an absolute /usr/bin path: override that separately.
  # Standard session service search prefers /usr/local/share to /usr/share.
  cat > "${service}" <<'EOF'
[D-BUS Service]
Name=org.gnome.Settings
Exec=/usr/local/bin/gnome-control-center
EOF
}

install_pinetabv_camera_policy() {
  local udev_rules="${ROOT_MNT}/etc/udev/rules.d/71-pinetabv-camera.rules"
  local wireplumber_conf="${ROOT_MNT}/etc/wireplumber/wireplumber.conf.d/51-pinetabv-camera.conf"
  local selector="${ROOT_MNT}/usr/local/bin/pinetabv-camera-select"

  log "Installing PineTab-V camera discovery and input selection"
  install -d "$(dirname "${udev_rules}")" "$(dirname "${wireplumber_conf}")" \
    "$(dirname "${selector}")"
  # PipeWire maps ID_V4L_PRODUCT to device.product.name before WirePlumber
  # creates the V4L2 device. Match the kernel name, never /dev/video numbers.
  cat > "${udev_rules}" <<'EOF'
ACTION=="remove", GOTO="pinetabv_camera_end"
SUBSYSTEM!="video4linux", GOTO="pinetabv_camera_end"
DRIVERS!="starfive-camss", GOTO="pinetabv_camera_end"
ATTR{name}=="capture_raw", ENV{ID_V4L_PRODUCT}="PineTab-V Raw Camera", SYMLINK+="pinetabv-camera-raw"
ATTR{name}=="capture_yuv", ENV{ID_V4L_PRODUCT}="PineTab-V Camera", SYMLINK+="pinetabv-camera"
LABEL="pinetabv_camera_end"
EOF
  cat > "${wireplumber_conf}" <<'EOF'
# Keep the raw Bayer diagnostics node out of desktop camera discovery.
# The hardware ISP supplies NV12 through the ordinary V4L2 backend.
monitor.v4l2.rules = [
  {
    matches = [ { device.product.name = "PineTab-V Raw Camera" } ]
    actions = { update-props = { device.disabled = true } }
  }
  {
    matches = [ { device.product.name = "PineTab-V Camera" } ]
    actions = { update-props = { device.description = "PineTab-V Camera" } }
  }
  {
    matches = [ {
      api.v4l2.cap.driver = "starfive-camss"
      node.name = "~v4l2_input.*"
    } ]
    actions = {
      update-props = {
        node.description = "PineTab-V Camera"
        node.nick = "PineTab-V Camera"
        priority.session = 2000
        node.pause-on-idle = true
        session.suspend-timeout-seconds = 1
      }
    }
  }
]
EOF
  cat > "${selector}" <<'EOF'
#!/bin/sh
# The two physical sensors share one ISP; select while camera apps are closed.
set -eu
case "${1:-}" in
  front) input=0 ;;
  rear) input=1 ;;
  -h|--help)
    printf 'Usage: pinetabv-camera-select front|rear\nClose camera applications before switching the sensor.\n'
    exit 0
    ;;
  *) printf 'Usage: pinetabv-camera-select front|rear\n' >&2; exit 2 ;;
esac
if [ ! -e /dev/pinetabv-camera ]; then
  printf 'PineTab-V ISP camera is not registered at /dev/pinetabv-camera.\n' >&2
  exit 1
fi
# PipeWire releases its buffers shortly after the last camera app closes.
# Allow its idle suspend to finish; never interrupt an active camera client.
for attempt in 1 2 3 4 5 6 7 8 9 10 11; do
  if result="$(LC_ALL=C v4l2-ctl --device=/dev/pinetabv-camera --set-input="${input}" 2>&1)"; then
    printf '%s\n' "${result}"
    exit 0
  fi
  case "${result}" in
    *"Device or resource busy"*)
      [ "${attempt}" -lt 11 ] || break
      sleep 0.2
      ;;
    *) printf '%s\n' "${result}" >&2; exit 1 ;;
  esac
done
printf '%s\nClose camera applications before selecting the other sensor.\n' "${result}" >&2
exit 1
EOF
  chmod 755 "${selector}"
}

install_pinetabv_wireless_diagnostics() {
  install -Dm755 "${SELF_DIR}/tests/collect-pinetabv-wireless.sh" \
    "${ROOT_MNT}/usr/local/sbin/pinetabv-wireless-report"
}

verify_pinetabv_camera_policy() {
  local udev_rules="${ROOT_MNT}/etc/udev/rules.d/71-pinetabv-camera.rules"
  local wireplumber_conf="${ROOT_MNT}/etc/wireplumber/wireplumber.conf.d/51-pinetabv-camera.conf"

  [[ -s "${udev_rules}" && -s "${wireplumber_conf}" && \
     -x "${ROOT_MNT}/usr/local/bin/pinetabv-camera-select" ]] || \
    die "The PineTab-V desktop camera policy or sensor selector is missing."
  grep -Fq 'ATTR{name}=="capture_raw", ENV{ID_V4L_PRODUCT}="PineTab-V Raw Camera"' \
    "${udev_rules}" || die "The stable raw camera identity is missing."
  grep -Fq 'ATTR{name}=="capture_yuv", ENV{ID_V4L_PRODUCT}="PineTab-V Camera"' \
    "${udev_rules}" || die "The stable ISP camera identity is missing."
  grep -Fq 'device.product.name = "PineTab-V Raw Camera"' \
    "${wireplumber_conf}" || die "WirePlumber does not identify the raw camera."
  grep -Fq 'device.disabled = true' "${wireplumber_conf}" || \
    die "WirePlumber does not hide the raw Bayer camera."
}

install_powervr_firmware() {
  local firmware_download="${DOWNLOAD_DIR}/${PVR_FIRMWARE_NAME}"
  local license_download="${DOWNLOAD_DIR}/LICENSE.powervr"

  download_verified_file "${PVR_FIRMWARE_URL}" "${firmware_download}" "${PVR_FIRMWARE_SHA256}"
  download_verified_file "${PVR_LICENSE_URL}" "${license_download}" "${PVR_LICENSE_SHA256}"

  log "Installing the JH7110 BXE-4-32 firmware and experimental-driver opt-in"
  install -Dm644 "${firmware_download}" \
    "${ROOT_MNT}/lib/firmware/powervr/${PVR_FIRMWARE_NAME}"
  install -Dm644 "${license_download}" \
    "${ROOT_MNT}/usr/share/licenses/powervr/LICENSE.powervr"

  install -d "${ROOT_MNT}/etc/modprobe.d" "${ROOT_MNT}/etc/profile.d"
  cat > "${ROOT_MNT}/etc/modprobe.d/powervr.conf" <<'EOF'
# JH7110 BXE-4-32 support is intentionally marked experimental upstream.
options powervr exp_hw_support=1
EOF
  cat > "${ROOT_MNT}/etc/profile.d/powervr.sh" <<'EOF'
# Mesa intentionally hides its non-conformant PowerVR Vulkan driver by default.
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
EOF
  chmod 644 "${ROOT_MNT}/etc/profile.d/powervr.sh"
}

install_boot_files() {
  local kernel_build="${BUILD_DIR}/linux"
  local kernel_dtb_dir="${kernel_build}/arch/riscv/boot/dts/starfive"
  local root_partuuid=""
  local kernel_cmdline=""

  root_partuuid="$(<"${WORKDIR}/root.partuuid")"
  [[ -n "${root_partuuid}" ]] || die "Missing cached root PARTUUID."
  kernel_cmdline="root=PARTUUID=${root_partuuid} rw rootwait rootfstype=ext4 console=tty1 console=ttyS0,115200 earlycon=sbi fbcon=rotate:1"

  log "Installing boot artifacts"
  if [[ -e "${BOOT_MNT}/dtbs" || -L "${BOOT_MNT}/dtbs" ]]; then
    rm -rf -- "${BOOT_MNT}/dtbs"
  fi
  install -d "${BOOT_MNT}/dtbs" "${BOOT_MNT}/dtbs/starfive" "${BOOT_MNT}/extlinux"
  install -Dm644 "${kernel_build}/arch/riscv/boot/Image" "${BOOT_MNT}/Image"
  install -Dm644 "${kernel_build}/System.map" "${BOOT_MNT}/System.map-${KERNEL_RELEASE}"
  install -Dm644 "${kernel_build}/.config" "${BOOT_MNT}/config-${KERNEL_RELEASE}"

  install -Dm644 "${kernel_dtb_dir}/${PINETABV_DTB}" "${BOOT_MNT}/dtbs/${PINETABV_DTB}"
  install -Dm644 "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" \
    "${BOOT_MNT}/dtbs/${PINETABV_FALLBACK_DTB}"
  install -Dm644 "${kernel_dtb_dir}/${PINETABV_DTB}" "${BOOT_MNT}/dtbs/starfive/pine64_pinetabv.dtb"

  cat > "${BOOT_MNT}/uEnv.txt" <<EOF
boot2=setenv bootdev mmc; setenv fatbootpart \${bootpart}; run bootcmd_distro
fdtfile=${PINETABV_DTB}
kernel_comp_addr_r=0x90000000
kernel_addr_r=0x40200000
initrd_high=0xffffffffffffffff
bootargs=${kernel_cmdline}
EOF
  cp "${BOOT_MNT}/uEnv.txt" "${BOOT_MNT}/vf2_uEnv.txt"

  cat > "${BOOT_MNT}/extlinux/extlinux.conf" <<EOF
default ${DISTRO_ID}
menu title PineTab-V ${DISTRO_NAME}
timeout 50

label ${DISTRO_ID}
  menu label ${DISTRO_NAME} Linux (${KERNEL_RELEASE})
  linux /Image
  fdt /dtbs/${PINETABV_DTB}
  append ${kernel_cmdline}

label ${DISTRO_ID}-diagnostics
  menu label ${DISTRO_NAME} Linux (${KERNEL_RELEASE}) - DRM diagnostics
  linux /Image
  fdt /dtbs/${PINETABV_DTB}
  append ${kernel_cmdline} ignore_loglevel loglevel=8 drm.debug=0x1ff log_buf_len=4M

label ${DISTRO_ID}-alternate-pcb
  menu label ${DISTRO_NAME} Linux (${KERNEL_RELEASE}) - alternate PineTab-V PCB
  linux /Image
  fdt /dtbs/${PINETABV_FALLBACK_DTB}
  append ${kernel_cmdline}
EOF
}

write_bootloader_partitions() {
  local spl_size=0
  local uboot_size=0

  [[ -s "${INSTALLED_SPL_IMAGE}" ]] || die "Missing SPL image: ${INSTALLED_SPL_IMAGE}"
  [[ -s "${INSTALLED_UBOOT_IMAGE}" ]] || \
    die "Missing verified OpenSBI/U-Boot FIT: ${INSTALLED_UBOOT_IMAGE}"

  spl_size="$(stat -c %s "${INSTALLED_SPL_IMAGE}")"
  uboot_size="$(stat -c %s "${INSTALLED_UBOOT_IMAGE}")"
  (( spl_size <= $(blockdev --getsize64 "${PART_SPL}") )) || \
    die "SPL does not fit in the SPL partition."
  (( uboot_size <= $(blockdev --getsize64 "${PART_UBOOT}") )) || \
    die "OpenSBI/U-Boot FIT does not fit in the U-Boot partition."

  log "Writing SPL and U-Boot"
  dd if="${INSTALLED_SPL_IMAGE}" of="${PART_SPL}" \
    bs=4M conv=fsync,notrunc status=progress
  dd if="${INSTALLED_UBOOT_IMAGE}" of="${PART_UBOOT}" \
    bs=4M conv=fsync,notrunc status=progress

  verify_bootloader_partitions
}

verify_bootloader_partitions() {
  local spl_size=0
  local uboot_size=0

  verify_partition_layout
  [[ -s "${INSTALLED_SPL_IMAGE}" ]] || die "The verified SPL source is unavailable."
  [[ -s "${INSTALLED_UBOOT_IMAGE}" ]] || \
    die "The verified OpenSBI/U-Boot FIT source is unavailable."
  spl_size="$(stat -c %s "${INSTALLED_SPL_IMAGE}")"
  uboot_size="$(stat -c %s "${INSTALLED_UBOOT_IMAGE}")"

  cmp -n "${spl_size}" "${INSTALLED_SPL_IMAGE}" "${PART_SPL}" || \
    die "SPL verification failed after writing the target."
  cmp -n "${uboot_size}" "${INSTALLED_UBOOT_IMAGE}" "${PART_UBOOT}" || \
    die "OpenSBI/U-Boot FIT verification failed after writing the target."
}

verify_target_layout_common() {
  verify_pinetabv_camera_policy
  local kernel_build="${BUILD_DIR}/linux"
  local kernel_dtb_dir="${kernel_build}/arch/riscv/boot/dts/starfive"
  local boot_partuuid=""
  local root_partuuid=""
  local boot_source=""
  local root_source=""
  local -a installed_revision_dtbs=()
  local required_file=""

  log "Verifying the PineTab-V boot and root files"
  boot_source="$(findmnt -rn -o SOURCE -M "${BOOT_MNT}")"
  root_source="$(findmnt -rn -o SOURCE -M "${ROOT_MNT}")"
  [[ "$(readlink -f "${boot_source}")" == "$(readlink -f "${PART_BOOT}")" ]] || \
    die "The boot verification mount is not ${PART_BOOT}."
  [[ "$(readlink -f "${root_source}")" == "$(readlink -f "${PART_ROOT}")" ]] || \
    die "The root verification mount is not ${PART_ROOT}."
  [[ "$(findmnt -rn -o FSTYPE -M "${BOOT_MNT}")" == "vfat" ]] || \
    die "The boot partition is not mounted as vfat."
  [[ "$(findmnt -rn -o FSTYPE -M "${ROOT_MNT}")" == "ext4" ]] || \
    die "The root partition is not mounted as ext4."

  for required_file in \
    "${BOOT_MNT}/Image" \
    "${BOOT_MNT}/System.map-${KERNEL_RELEASE}" \
    "${BOOT_MNT}/config-${KERNEL_RELEASE}" \
    "${BOOT_MNT}/dtbs/${PINETABV_DTB}" \
    "${BOOT_MNT}/dtbs/${PINETABV_FALLBACK_DTB}" \
    "${BOOT_MNT}/dtbs/starfive/pine64_pinetabv.dtb" \
    "${BOOT_MNT}/uEnv.txt" \
    "${BOOT_MNT}/vf2_uEnv.txt" \
    "${BOOT_MNT}/extlinux/extlinux.conf" \
    "${ROOT_MNT}/etc/fstab" \
    "${ROOT_MNT}/lib/modules/${KERNEL_RELEASE}/modules.dep" \
    "${ROOT_MNT}/lib/firmware/powervr/${PVR_FIRMWARE_NAME}" \
    "${ROOT_MNT}/etc/libinput/local-overrides.quirks" \
    "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/PineTab-V.conf" \
    "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/HiFi.conf"; do
    [[ -s "${required_file}" ]] || die "Required target file is missing or empty: ${required_file}"
  done

  cmp -s "${kernel_build}/arch/riscv/boot/Image" "${BOOT_MNT}/Image" || \
    die "The installed kernel Image differs from the new build."
  cmp -s "${kernel_dtb_dir}/${PINETABV_DTB}" \
    "${BOOT_MNT}/dtbs/${PINETABV_DTB}" || \
    die "The installed default DTB differs from the new build."
  cmp -s "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" \
    "${BOOT_MNT}/dtbs/${PINETABV_FALLBACK_DTB}" || \
    die "The installed alternate-revision DTB differs from the new build."
  cmp -s "${BOOT_MNT}/dtbs/${PINETABV_DTB}" \
    "${BOOT_MNT}/dtbs/starfive/pine64_pinetabv.dtb" || \
    die "The canonical PineTab-V DTB is not the selected revision."

  mapfile -t installed_revision_dtbs < <(
    find "${BOOT_MNT}/dtbs" -maxdepth 1 -type f \
      -name 'jh7110-pine64-pinetab-v-*.dtb' -printf '%f\n' | sort
  )
  (( ${#installed_revision_dtbs[@]} == 2 )) || \
    die "The boot partition does not contain exactly the two freshly built revision DTBs."
  [[ " ${installed_revision_dtbs[*]} " == *" ${PINETABV_DTB} "* ]] || \
    die "The selected PineTab-V DTB is missing from the boot partition."
  [[ " ${installed_revision_dtbs[*]} " == *" ${PINETABV_FALLBACK_DTB} "* ]] || \
    die "The alternate PineTab-V DTB is missing from the boot partition."

  grep -Fqx "fdtfile=${PINETABV_DTB}" "${BOOT_MNT}/uEnv.txt" || \
    die "uEnv.txt does not select the new ${PINETABV_DTB}."
  grep -Fqx "fdtfile=${PINETABV_DTB}" "${BOOT_MNT}/vf2_uEnv.txt" || \
    die "vf2_uEnv.txt does not select the new ${PINETABV_DTB}."
  grep -Fqx 'boot2=setenv bootdev mmc; setenv fatbootpart ${bootpart}; run bootcmd_distro' \
    "${BOOT_MNT}/uEnv.txt" || \
    die "uEnv.txt does not use the PineTab-V SD-aware distro boot path."
  grep -Fqx 'boot2=setenv bootdev mmc; setenv fatbootpart ${bootpart}; run bootcmd_distro' \
    "${BOOT_MNT}/vf2_uEnv.txt" || \
    die "vf2_uEnv.txt does not use the PineTab-V SD-aware distro boot path."
  grep -Fqx 'kernel_comp_addr_r=0x90000000' "${BOOT_MNT}/uEnv.txt" || \
    die "uEnv.txt does not retain a safe compressed-kernel workspace."
  grep -Fqx 'kernel_comp_addr_r=0x90000000' "${BOOT_MNT}/vf2_uEnv.txt" || \
    die "vf2_uEnv.txt does not retain a safe compressed-kernel workspace."
  grep -Fqx "default ${DISTRO_ID}" "${BOOT_MNT}/extlinux/extlinux.conf" || \
    die "The ${DISTRO_NAME} extlinux entry is not the default."
  grep -Fqx '  linux /Image' "${BOOT_MNT}/extlinux/extlinux.conf" || \
    die "The extlinux entry does not load the new kernel Image."
  grep -Fqx "  fdt /dtbs/${PINETABV_DTB}" \
    "${BOOT_MNT}/extlinux/extlinux.conf" || \
    die "The extlinux entry does not explicitly load the selected new DTB."
  grep -Fqx "  fdt /dtbs/${PINETABV_FALLBACK_DTB}" \
    "${BOOT_MNT}/extlinux/extlinux.conf" || \
    die "The alternate-PCB extlinux entry does not load its new DTB."
  grep -Fq 'ignore_loglevel loglevel=8 drm.debug=0x1ff log_buf_len=4M' \
    "${BOOT_MNT}/extlinux/extlinux.conf" || \
    die "The DRM diagnostic extlinux entry is missing its debug arguments."

  boot_partuuid="$(<"${WORKDIR}/boot.partuuid")"
  root_partuuid="$(<"${WORKDIR}/root.partuuid")"
  [[ "${boot_partuuid}" == "$(blkid -s PARTUUID -o value "${PART_BOOT}")" ]] || \
    die "The cached boot PARTUUID does not match the target partition."
  [[ "${root_partuuid}" == "$(blkid -s PARTUUID -o value "${PART_ROOT}")" ]] || \
    die "The cached root PARTUUID does not match the target partition."
  grep -Fq "root=PARTUUID=${root_partuuid} " \
    "${BOOT_MNT}/extlinux/extlinux.conf" || \
    die "The extlinux root PARTUUID does not match the target root filesystem."
  grep -Fqx "PARTUUID=${boot_partuuid}  /boot  vfat  defaults,noatime  0  2" \
    "${ROOT_MNT}/etc/fstab" || die "The target fstab is missing the boot filesystem."
  grep -Fqx "PARTUUID=${root_partuuid}  /      ext4  defaults,noatime  0  1" \
    "${ROOT_MNT}/etc/fstab" || die "The target fstab is missing the root filesystem."

  printf '%s  %s\n' "${PVR_FIRMWARE_SHA256}" \
    "${ROOT_MNT}/lib/firmware/powervr/${PVR_FIRMWARE_NAME}" | sha256sum -c - >/dev/null
  grep -Fqx 'MatchName=HID 1018:1006 Touchpad' \
    "${ROOT_MNT}/etc/libinput/local-overrides.quirks" || \
    die "The PineTab-V keyboard-cover touchpad match is missing."
  grep -Fqx 'MatchDeviceTree=pine64,pinetab-v-*' \
    "${ROOT_MNT}/etc/libinput/local-overrides.quirks" || \
    die "The keyboard-cover touchpad quirk is not scoped to PineTab-V."
  grep -Fqx 'AttrEventCode=-BTN_RIGHT' \
    "${ROOT_MNT}/etc/libinput/local-overrides.quirks" || \
    die "The keyboard-cover fake right-button correction is missing."
  grep -Fqx 'AttrInputProp=+INPUT_PROP_BUTTONPAD' \
    "${ROOT_MNT}/etc/libinput/local-overrides.quirks" || \
    die "The keyboard-cover clickpad property is missing."

  [[ -L "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V.conf" && \
     "$(readlink "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V.conf")" == \
       ../../PineTabV/PineTab-V.conf ]] || \
    die "The PineTab-V ALSA UCM soundcard mapping is missing."
  [[ -L "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V ES8316 Audio.conf" && \
     "$(readlink "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V ES8316 Audio.conf")" == \
       ../../PineTabV/PineTab-V.conf ]] || \
    die "The PineTab-V ES8316 ALSA UCM card-name mapping is missing."
  [[ "$(grep -Fc 'PlaybackPCM "hw:${CardId},1"' \
       "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/HiFi.conf")" == 2 ]] || \
    die "The PineTab-V ALSA UCM profile does not route playback to PCM 1."
  [[ "$(grep -Fc 'CapturePCM "hw:${CardId},0"' \
       "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/HiFi.conf")" == 2 ]] || \
    die "The PineTab-V ALSA UCM profile does not route capture to PCM 0."
  [[ -L "${ROOT_MNT}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" ]] || \
    die "The ttyS0 recovery console is not enabled."
  [[ ! -e "${ROOT_MNT}/etc/systemd/system/systemd-backlight@backlight:backlight.service" && \
     ! -L "${ROOT_MNT}/etc/systemd/system/systemd-backlight@backlight:backlight.service" ]] || \
    die "The PineTab-V systemd backlight save/restore instance is masked."
}

finalize_target() {
  local image_parent=""

  log "Performing a read-only final verification"
  sync
  cleanup_chroot_mounts
  mount -o remount,ro "${BOOT_MNT}"
  mount -o remount,ro "${ROOT_MNT}"
  [[ ",$(findmnt -rn -o OPTIONS -M "${BOOT_MNT}")," == *,ro,* ]] || \
    die "The boot partition did not become read-only for final verification."
  [[ ",$(findmnt -rn -o OPTIONS -M "${ROOT_MNT}")," == *,ro,* ]] || \
    die "The root partition did not become read-only for final verification."
  verify_target_layout
  verify_bootloader_partitions
  unmount_target_strict "${BOOT_MNT}"
  unmount_target_strict "${ROOT_MNT}"
  sync

  if [[ -n "${LOOP_DEV}" ]]; then
    losetup -d "${LOOP_DEV}"
    LOOP_DEV=""
  fi

  if [[ -n "${IMAGE_FILE}" ]]; then
    [[ "${IMAGE_WORK_OWNED}" -eq 1 ]] || die "The temporary image is not owned by this build."
    [[ "${IMAGE_WORK_FILE}" == "${IMAGE_FILE}.building."* ]] || \
      die "Refusing to publish an unexpected temporary image path."
    image_parent="$(dirname -- "${IMAGE_FILE}")"
    chmod 644 "${IMAGE_WORK_FILE}"
    mv -fT -- "${IMAGE_WORK_FILE}" "${IMAGE_FILE}"
    IMAGE_COMMITTED=1
    IMAGE_WORK_OWNED=0
    IMAGE_WORK_FILE=""
    sync -f "${IMAGE_FILE}"
    sync -f "${image_parent}"
    if [[ -n "${RESTORE_OWNER_UID}" && -n "${RESTORE_OWNER_GID}" ]]; then
      chown "${RESTORE_OWNER_UID}:${RESTORE_OWNER_GID}" "${IMAGE_FILE}" || \
        warn "Could not restore ownership of ${IMAGE_FILE}."
    fi
  fi
}

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --target /dev/sdX [--yes]
  ${SCRIPT_NAME} --image /path/pinetabv-debian.img [--size-gb 12] [--yes]

Options:
  --target PATH      Block device to erase and provision.
  --image PATH       Create and provision a raw Debian 13 disk image.
  --size-gb N        Image size in GiB when --image is used. Default: ${IMAGE_SIZE_GB}
  --yes              Skip the destructive-write confirmation prompt.
  --help             Show this help.

Environment overrides:
  DEBIAN_SUITE=trixie
  DEBIAN_MIRROR=https://deb.debian.org/debian
  DEBIAN_SECURITY_MIRROR=https://deb.debian.org/debian-security
  DEBIAN_BOOTSTRAP_KEYRING=/path/to/debian-archive-keyring.gpg
  DEBIAN_PACKAGES="openssh-server network-manager ... task-gnome-desktop gdm3"
  KDEB_PKGVERSION=${KDEB_PKGVERSION}
  KERNEL_PACKAGE_MAINTAINER="${KERNEL_PACKAGE_MAINTAINER}"
  DEBIAN_DESKTOP_USER=${DEBIAN_DESKTOP_USER}
  DEBIAN_DESKTOP_PASSWORD=${DEBIAN_DESKTOP_PASSWORD}
  QEMU_RISCV_STATIC=/usr/bin/qemu-riscv64-static
  CROSS_COMPILE=riscv64-linux-gnu-
  HOSTNAME_VALUE=pinetabv
  TIMEZONE_VALUE=UTC
  LOCALE_VALUE=en_US.UTF-8
  PINETABV_DTB=jh7110-pine64-pinetab-v-20240730.dtb
  ROOT_PASSWORD=...
  ROOT_PASSWORD_HASH=...
  WORKDIR=${WORKDIR}

Notes:
  - Debian 13 is pinned by codename (trixie) and bootstrapped as riscv64 with
    debootstrap.  Its Release signature is mandatory; when the host keyring is
    absent, the pinned Debian 2025.1 keyring package is downloaded and verified.
    Cross-architecture builds use qemu-riscv64-static.
  - The script builds StarFive's PineTab-V U-Boot, OpenSBI, and Linux 7.3
    with this project's PineTab-V patch series and configuration.
  - The verified Image, modules and PineTab-V DTBs are assembled into a native
    riscv64 .deb with dpkg-deb.  It is installed with APT and retained in
    /opt/pinetabv/kernel-packages.
  - The FAT boot partition is populated and byte-verified independently of
    generic Debian kernel hooks because PineTab-V uses its own U-Boot layout.
EOF
}

validate_debian_options() {
  local camera_package=""

  [[ "${DEBIAN_SUITE}" == trixie ]] || \
    die "DEBIAN_SUITE must remain trixie for a Debian 13 image."
  [[ "${DEBIAN_ARCH}" == riscv64 ]] || \
    die "DEBIAN_ARCH must remain riscv64 for PineTab-V."
  case " ${DEBIAN_REQUIRED_PACKAGES} " in
    *" dialog "*) ;;
    *) die "DEBIAN_REQUIRED_PACKAGES must include dialog for debconf." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" iio-sensor-proxy "*) ;;
    *) die "DEBIAN_PACKAGES must include iio-sensor-proxy for screen autorotation." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" task-gnome-desktop "*) ;;
    *) die "DEBIAN_PACKAGES must include task-gnome-desktop." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" gdm3 "*) ;;
    *) die "DEBIAN_PACKAGES must include gdm3." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" pipewire-audio "*) ;;
    *) die "DEBIAN_PACKAGES must include pipewire-audio for GNOME audio." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" wireplumber "*) ;;
    *) die "DEBIAN_PACKAGES must include wireplumber for GNOME audio policy." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" libcamera-tools "*) ;;
    *) die "DEBIAN_PACKAGES must include libcamera-tools for camera diagnostics." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" libcamera-ipa "*) ;;
    *) die "DEBIAN_PACKAGES must include libcamera-ipa for Bayer processing." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" libspa-0.2-libcamera "*) ;;
    *) die "DEBIAN_PACKAGES must include PipeWire's libcamera camera plugin." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" libinput-tools "*) ;;
    *) die "DEBIAN_PACKAGES must include libinput-tools for touchpad diagnostics." ;;
  esac
  case " ${DEBIAN_PACKAGES} " in
    *" dconf-cli "*) ;;
    *) die "DEBIAN_PACKAGES must include dconf-cli for GNOME input defaults." ;;
  esac
  for camera_package in gnome-snapshot gstreamer1.0-pipewire gstreamer1.0-plugins-good libspa-0.2-modules; do
    case " ${DEBIAN_PACKAGES} " in
      *" ${camera_package} "*) ;;
      *) die "DEBIAN_PACKAGES must include ${camera_package} for desktop cameras." ;;
    esac
  done
  [[ -n "${DEBIAN_MIRROR}" && -n "${DEBIAN_SECURITY_MIRROR}" ]] || \
    die "Debian mirror URLs must not be empty."
  dpkg --validate-version "${KDEB_PKGVERSION}" >/dev/null 2>&1 || \
    die "Invalid Debian kernel package version: ${KDEB_PKGVERSION}"
  [[ -n "${KERNEL_PACKAGE_MAINTAINER}" && \
     "${KERNEL_PACKAGE_MAINTAINER}" != *$'\n'* ]] || \
    die "KERNEL_PACKAGE_MAINTAINER must be a non-empty single line."
  [[ "${DEBIAN_DESKTOP_USER}" == user ]] || \
    die "DEBIAN_DESKTOP_USER must remain user for the default desktop login."
  [[ "${DEBIAN_DESKTOP_PASSWORD}" == debian ]] || \
    die "DEBIAN_DESKTOP_PASSWORD must remain debian for the default desktop login."
}

detect_target_execution() {
  case "$(uname -m)" in
    riscv64)
      TARGET_NEEDS_QEMU=0
      ;;
    *)
      TARGET_NEEDS_QEMU=1
      require_qemu_static
      ;;
  esac
}

prepare_debian_archive_keyring() {
  local system_keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
  local keyring_deb="${DOWNLOAD_DIR}/debian-archive-keyring_2025.1_all.deb"
  local keyring_root="${BUILD_DIR}/debian-archive-keyring"
  local extracted_keyring="${keyring_root}/usr/share/keyrings/debian-archive-keyring.gpg"

  if [[ -n "${DEBIAN_BOOTSTRAP_KEYRING}" ]]; then
    [[ -s "${DEBIAN_BOOTSTRAP_KEYRING}" ]] || \
      die "DEBIAN_BOOTSTRAP_KEYRING is missing or empty: ${DEBIAN_BOOTSTRAP_KEYRING}"
    DEBIAN_BOOTSTRAP_KEYRING="$(readlink -f "${DEBIAN_BOOTSTRAP_KEYRING}")"
    return
  fi

  if [[ -s "${system_keyring}" ]]; then
    DEBIAN_BOOTSTRAP_KEYRING="${system_keyring}"
    return
  fi

  download_verified_file \
    "${DEBIAN_KEYRING_DEB_URL}" "${keyring_deb}" \
    "${DEBIAN_KEYRING_DEB_SHA256}"
  rm -rf -- "${keyring_root}"
  dpkg-deb --extract "${keyring_deb}" "${keyring_root}"
  [[ -s "${extracted_keyring}" ]] || \
    die "The verified Debian archive-keyring package lacks its archive keyring."
  DEBIAN_BOOTSTRAP_KEYRING="${extracted_keyring}"
  log "Using verified Debian bootstrap keyring ${DEBIAN_BOOTSTRAP_KEYRING}"
}

mount_target_filesystems() {
  log "Mounting Debian target filesystems"
  mount "${PART_ROOT}" "${ROOT_MNT}"
  install -d "${BOOT_MNT}"
  mount "${PART_BOOT}" "${BOOT_MNT}"
}

target_chroot_run() {
  local command_string="$1"
  local environment="export HOME=/root TERM=dumb LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  if (( TARGET_NEEDS_QEMU == 1 )); then
    chroot "${ROOT_MNT}" /usr/bin/qemu-riscv64-static /bin/bash -c \
      "${environment}; ${command_string}"
  else
    chroot "${ROOT_MNT}" /bin/bash -c "${environment}; ${command_string}"
  fi
}

# Debian uses a private volatile /run while packages are configured.  Do not
# expose the build host's systemd and D-Bus sockets inside the target chroot.
prepare_debian_chroot_resolver() {
  local host_resolver=""
  local target_resolver="${ROOT_MNT}/etc/resolv.conf"

  if [[ -s /run/systemd/resolve/resolv.conf ]] &&
     grep -Eq '^[[:space:]]*nameserver[[:space:]]+' \
       /run/systemd/resolve/resolv.conf; then
    # Prefer systemd-resolved's uplink file over its 127.0.0.53 stub.  This
    # leaves the chroot independent of the host's local DNS proxy.
    host_resolver=/run/systemd/resolve/resolv.conf
  else
    host_resolver="$(readlink -f /etc/resolv.conf || true)"
  fi
  [[ -s "${host_resolver}" ]] || \
    die "The build host does not have a usable resolver configuration."
  grep -Eq '^[[:space:]]*nameserver[[:space:]]+' "${host_resolver}" || \
    die "The build host resolver does not contain a nameserver."

  # Installing systemd-resolved in the target may replace this file with a
  # link into /run.  The build chroot deliberately has a private, empty /run,
  # so refresh a regular resolver file before every chroot phase that may use
  # APT.  finish_debian_chroot restores the runtime systemd-resolved link.
  rm -f -- "${target_resolver}"
  install -Dm644 "${host_resolver}" "${target_resolver}"
  [[ -f "${target_resolver}" && ! -L "${target_resolver}" ]] || \
    die "Failed to install the Debian build-chroot resolver."
}

mount_chroot_fs() {
  prepare_debian_chroot_resolver
  install -d "${ROOT_MNT}/proc" "${ROOT_MNT}/sys" \
    "${ROOT_MNT}/dev" "${ROOT_MNT}/run"

  mount --types proc proc "${ROOT_MNT}/proc"
  CHROOT_MOUNTS+=("${ROOT_MNT}/proc")

  mount --rbind /sys "${ROOT_MNT}/sys"
  CHROOT_MOUNTS+=("${ROOT_MNT}/sys")
  mount --make-rslave "${ROOT_MNT}/sys"

  mount --rbind /dev "${ROOT_MNT}/dev"
  CHROOT_MOUNTS+=("${ROOT_MNT}/dev")
  mount --make-rslave "${ROOT_MNT}/dev"

  mount --types tmpfs --options mode=0755,nosuid,nodev \
    tmpfs "${ROOT_MNT}/run"
  CHROOT_MOUNTS+=("${ROOT_MNT}/run")

  [[ "$(findmnt -rn -M "${ROOT_MNT}/proc" -o FSTYPE)" == proc ]] || \
    die "The Debian chroot does not have procfs mounted."
  [[ "$(findmnt -rn -M "${ROOT_MNT}/sys" -o FSTYPE)" == sysfs ]] || \
    die "The Debian chroot does not have sysfs mounted."
  findmnt -rn -M "${ROOT_MNT}/dev" >/dev/null || \
    die "The Debian chroot does not have /dev mounted."
  [[ "$(findmnt -rn -M "${ROOT_MNT}/run" -o FSTYPE)" == tmpfs ]] || \
    die "The Debian chroot does not have a private tmpfs on /run."
}

prepare_debian_emulation() {
  (( TARGET_NEEDS_QEMU == 1 )) || return 0

  install -Dm755 "${QEMU_RISCV_STATIC}" \
    "${ROOT_MNT}/usr/bin/qemu-riscv64-static"
  chroot "${ROOT_MNT}" /usr/bin/qemu-riscv64-static --version >/dev/null 2>&1 || \
    die "The copied qemu-riscv64-static cannot run inside the Debian root."
  ensure_riscv64_binfmt
}

write_debian_apt_sources() {
  install -d "${ROOT_MNT}/etc/apt/sources.list.d"
  : > "${ROOT_MNT}/etc/apt/sources.list"
  cat > "${ROOT_MNT}/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: ${DEBIAN_MIRROR}
Suites: ${DEBIAN_SUITE} ${DEBIAN_SUITE}-updates
Components: ${DEBIAN_APT_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${DEBIAN_SECURITY_MIRROR}
Suites: ${DEBIAN_SUITE}-security
Components: ${DEBIAN_APT_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

install_policy_rc_d() {
  install -d "${ROOT_MNT}/usr/sbin"
  cat > "${ROOT_MNT}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
  chmod 755 "${ROOT_MNT}/usr/sbin/policy-rc.d"
}

configure_debian_wireless_regdb() {
  # Debian's default signature uses its own kernel key. This project builds
  # upstream Linux, whose trusted regdb keys require the packaged upstream pair.
  [[ -s "${ROOT_MNT}/usr/lib/firmware/regulatory.db-upstream" && \
     -s "${ROOT_MNT}/usr/lib/firmware/regulatory.db.p7s-upstream" ]] || \
    die "Debian wireless-regdb lacks its upstream-signed database."
  log "Selecting the upstream-signed Debian regulatory database"
  target_chroot_run \
    "update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream"
  verify_debian_wireless_regdb
}

verify_debian_wireless_regdb() {
  [[ "$(readlink "${ROOT_MNT}/etc/alternatives/regulatory.db")" == \
       /lib/firmware/regulatory.db-upstream && \
     "$(readlink "${ROOT_MNT}/etc/alternatives/regulatory.db.p7s")" == \
       /lib/firmware/regulatory.db.p7s-upstream ]] || \
    die "The regulatory database/signature pair does not match upstream kernel keys."
}

bootstrap_debian_rootfs() {
  local -a debootstrap_args=(
    --arch="${DEBIAN_ARCH}"
    --variant=minbase
    --components="${DEBIAN_COMPONENTS}"
    --keyring="${DEBIAN_BOOTSTRAP_KEYRING}"
    --force-check-sig
  )
  local package_set="${DEBIAN_REQUIRED_PACKAGES}"

  if (( TARGET_NEEDS_QEMU == 1 )); then
    debootstrap_args+=(--foreign)
  fi

  log "Bootstrapping Debian 13 (${DEBIAN_SUITE}) for ${DEBIAN_ARCH}"
  debootstrap "${debootstrap_args[@]}" \
    "${DEBIAN_SUITE}" "${ROOT_MNT}" "${DEBIAN_MIRROR}"

  [[ -x "${ROOT_MNT}/bin/bash" ]] || die "Debootstrap did not install the target shell."
  install_policy_rc_d
  write_debian_apt_sources
  printf '%s UTF-8\n' "${LOCALE_VALUE}" > "${ROOT_MNT}/etc/locale.gen"
  printf '%s\n' "${TIMEZONE_VALUE}" > "${ROOT_MNT}/etc/timezone"

  prepare_debian_emulation
  mount_chroot_fs

  if (( TARGET_NEEDS_QEMU == 1 )); then
    log "Completing the foreign Debian bootstrap"
    target_chroot_run "/debootstrap/debootstrap --second-stage"

    # The foreign debootstrap second stage owns its temporary /proc and /sys
    # mounts and unmounts them when it exits.  Reset the stale tracking list
    # and recreate the complete chroot environment before apt/dpkg continue.
    cleanup_chroot_mounts
    mount_chroot_fs
  fi

  package_set+=" ${DEBIAN_PACKAGES}"

  log "Installing Debian base and PineTab-V userspace packages"
  target_chroot_run \
    "dpkg --configure -a && apt-get update && apt-get install -y ${package_set} && locale-gen '${LOCALE_VALUE}' && systemctl enable systemd-resolved.service serial-getty@ttyS0.service && apt-get clean"

  configure_debian_wireless_regdb

  target_chroot_run \
    "systemctl enable NetworkManager.service ssh.service bluetooth.service gdm3.service && systemctl set-default graphical.target"

  # iio-sensor-proxy is a static D-Bus/udev-activated service, so installing
  # its unit and 80-iio-sensor-proxy.rules is sufficient and `enable` would be
  # an error.  The SC7A20 is built into the kernel and creates the IIO device
  # early enough for the udev rule to pull in the proxy before GNOME starts.
  [[ -x "${ROOT_MNT}/usr/libexec/iio-sensor-proxy" ]] || \
    die "Debian did not install the IIO sensor proxy executable."
  [[ -s "${ROOT_MNT}/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules" ]] || \
    die "Debian did not install the IIO sensor proxy udev rule."

  # Make the ALSA/UCM card available as soon as each graphical user session
  # starts.  PipeWire itself remains a per-user service, as intended.
  target_chroot_run \
    "systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service"

  log "Creating the default PineTab-V desktop user ${DEBIAN_DESKTOP_USER}"
  target_chroot_run \
    "if ! id -u '${DEBIAN_DESKTOP_USER}' >/dev/null 2>&1; then useradd --badname --create-home --user-group --shell /bin/bash --comment '${DEBIAN_DESKTOP_USER}' '${DEBIAN_DESKTOP_USER}'; fi && usermod --append --groups sudo,audio,video,render,input,pipewire '${DEBIAN_DESKTOP_USER}' && printf '%s:%s\\n' '${DEBIAN_DESKTOP_USER}' '${DEBIAN_DESKTOP_PASSWORD}' | chpasswd"

  cleanup_chroot_mounts
  [[ -r "${ROOT_MNT}/etc/os-release" ]] || die "Debian bootstrap did not create /etc/os-release."
  grep -Fqx 'ID=debian' "${ROOT_MNT}/etc/os-release" || \
    die "The bootstrapped root filesystem is not Debian."
  grep -Fqx 'VERSION_CODENAME=trixie' "${ROOT_MNT}/etc/os-release" || \
    die "The bootstrapped root filesystem is not Debian 13 trixie."
}

stage_pinetabv_desktop_input_defaults() {
  local dconf_profile="${ROOT_MNT}/etc/dconf/profile/user"
  local dconf_defaults="${ROOT_MNT}/etc/dconf/db/local.d/00-pinetabv-input"

  log "Configuring GNOME for PineTab-V touchpad button areas"
  install -d "$(dirname "${dconf_profile}")" "$(dirname "${dconf_defaults}")"
  cat > "${dconf_profile}" <<'EOF'
user-db:user
system-db:local
EOF
  cat > "${dconf_defaults}" <<'EOF'
[org/gnome/desktop/peripherals/touchpad]
tap-to-click=true
two-finger-scrolling-enabled=true
click-method='areas'
EOF
}

install_pinetabv_desktop_input_defaults() {
  stage_pinetabv_desktop_input_defaults
  mount_chroot_fs
  target_chroot_run "dconf update"
  cleanup_chroot_mounts
  [[ -s "${ROOT_MNT}/etc/dconf/db/local" ]] || \
    die "The PineTab-V GNOME input defaults were not compiled."
}

configure_rootfs() {
  local boot_partuuid=""
  local root_partuuid=""

  boot_partuuid="$(blkid -s PARTUUID -o value "${PART_BOOT}")"
  root_partuuid="$(blkid -s PARTUUID -o value "${PART_ROOT}")"
  [[ -n "${boot_partuuid}" ]] || die "Failed to determine boot PARTUUID."
  [[ -n "${root_partuuid}" ]] || die "Failed to determine root PARTUUID."

  prompt_for_root_password
  set_shadow_hash "${ROOT_MNT}/etc/shadow" root "${ROOT_PASSWORD_HASH}"

  printf '%s\n' "${HOSTNAME_VALUE}" > "${ROOT_MNT}/etc/hostname"
  cat > "${ROOT_MNT}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME_VALUE}
::1       localhost ip6-localhost ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters
EOF
  printf 'LANG=%s\n' "${LOCALE_VALUE}" > "${ROOT_MNT}/etc/default/locale"
  printf '%s\n' "${TIMEZONE_VALUE}" > "${ROOT_MNT}/etc/timezone"
  [[ -e "${ROOT_MNT}/usr/share/zoneinfo/${TIMEZONE_VALUE}" ]] || \
    die "Timezone file was not installed: ${TIMEZONE_VALUE}"
  ln -snf "/usr/share/zoneinfo/${TIMEZONE_VALUE}" "${ROOT_MNT}/etc/localtime"

  cat > "${ROOT_MNT}/etc/fstab" <<EOF
PARTUUID=${boot_partuuid}  /boot  vfat  defaults,noatime  0  2
PARTUUID=${root_partuuid}  /      ext4  defaults,noatime  0  1
EOF

  install -d "${ROOT_MNT}/etc/systemd/system/getty.target.wants"
  ln -snf /usr/lib/systemd/system/serial-getty@.service \
    "${ROOT_MNT}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
  # The udev-generated systemd-backlight instance saves the selected PWM
  # brightness during shutdown and restores it on the next boot.
  rm -f -- \
    "${ROOT_MNT}/etc/systemd/system/systemd-backlight@backlight:backlight.service"

  cat > "${ROOT_MNT}/etc/motd" <<EOF
Debian 13 for PineTab-V

Useful commands after boot:
  apt update && apt full-upgrade
  nmtui
  aplay -l
  v4l2-ctl --list-devices
  media-ctl -p

The custom kernel package is retained in /opt/pinetabv/kernel-packages/.
EOF

  printf '%s\n' "${boot_partuuid}" > "${WORKDIR}/boot.partuuid"
  printf '%s\n' "${root_partuuid}" > "${WORKDIR}/root.partuuid"
}

build_kernel_deb() {
  local package_root="${BUILD_DIR}/debian-package-root"
  local package_dtb_dir="${BUILD_DIR}/debian-package-root/boot/dtbs"
  local package_usr_dtb_dir="${BUILD_DIR}/debian-package-root/usr/lib/linux-image-${KERNEL_RELEASE}/starfive"
  local package_module_dir="${BUILD_DIR}/debian-package-root/usr/lib/modules/${KERNEL_RELEASE}"
  local kernel_dtb_dir="${BUILD_DIR}/linux/arch/riscv/boot/dts/starfive"
  local rtw89_module_rel="kernel/drivers/net/wireless/realtek/rtw89/rtw89_core.ko"
  local rtw89_build="${BUILD_DIR}/linux/drivers/net/wireless/realtek/rtw89/rtw89_core.ko"
  local installed_size=""
  local package_basename=""
  local packaged_file=""
  local verify_dir=""

  KERNEL_IMAGE_PACKAGE="linux-image-${KERNEL_RELEASE}"
  package_basename="${KERNEL_IMAGE_PACKAGE}_${KDEB_PKGVERSION}_${DEBIAN_ARCH}.deb"
  KERNEL_IMAGE_DEB="${KERNEL_PACKAGE_DIR}/${package_basename}"

  [[ -s "${BUILD_DIR}/linux/arch/riscv/boot/Image" ]] || \
    die "Cannot package a missing PineTab-V kernel Image."
  [[ -s "${BUILD_DIR}/linux/System.map" && \
     -s "${BUILD_DIR}/linux/.config" ]] || \
    die "Cannot package an incomplete PineTab-V kernel build."
  [[ -s "${kernel_dtb_dir}/${PINETABV_DTB}" && \
     -s "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" ]] || \
    die "Cannot package the two verified PineTab-V DTBs."
  [[ -s "${rtw89_build}" ]] || \
    die "The verified kernel build lacks the PineTab-V rtw89 module."

  rm -rf -- "${KERNEL_PACKAGE_DIR}"
  rm -rf -- "${package_root}"
  install -d "${KERNEL_PACKAGE_DIR}" "${package_root}"

  log "Staging ${KERNEL_IMAGE_PACKAGE} modules for the riscv64 Debian package"
  make -C "${SRC_DIR}/linux" \
    O="${BUILD_DIR}/linux" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    LOCALVERSION= \
    INSTALL_MOD_PATH="${package_root}" \
    modules_install >/dev/null

  [[ -d "${package_root}/lib/modules/${KERNEL_RELEASE}" ]] || \
    die "modules_install did not stage modules for ${KERNEL_RELEASE}."
  install -d "${package_root}/usr/lib"
  mv "${package_root}/lib/modules" "${package_root}/usr/lib/modules"
  rmdir "${package_root}/lib"

  [[ -s "${package_module_dir}/modules.dep" ]] || \
    die "modules_install did not create metadata for ${KERNEL_RELEASE}."
  rm -f -- "${package_module_dir}/build" "${package_module_dir}/source"

  install -Dm644 "${BUILD_DIR}/linux/arch/riscv/boot/Image" \
    "${package_root}/boot/Image"
  install -Dm644 "${BUILD_DIR}/linux/arch/riscv/boot/Image" \
    "${package_root}/boot/vmlinuz-${KERNEL_RELEASE}"
  install -Dm644 "${BUILD_DIR}/linux/System.map" \
    "${package_root}/boot/System.map-${KERNEL_RELEASE}"
  install -Dm644 "${BUILD_DIR}/linux/.config" \
    "${package_root}/boot/config-${KERNEL_RELEASE}"

  install -Dm644 "${kernel_dtb_dir}/${PINETABV_DTB}" \
    "${package_dtb_dir}/${PINETABV_DTB}"
  install -Dm644 "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" \
    "${package_dtb_dir}/${PINETABV_FALLBACK_DTB}"
  install -Dm644 "${kernel_dtb_dir}/${PINETABV_DTB}" \
    "${package_dtb_dir}/starfive/pine64_pinetabv.dtb"
  install -Dm644 "${kernel_dtb_dir}/${PINETABV_DTB}" \
    "${package_usr_dtb_dir}/${PINETABV_DTB}"
  install -Dm644 "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" \
    "${package_usr_dtb_dir}/${PINETABV_FALLBACK_DTB}"

  install -Dm644 "${SRC_DIR}/linux/COPYING" \
    "${package_root}/usr/share/doc/${KERNEL_IMAGE_PACKAGE}/copyright"
  install -d "${package_root}/DEBIAN"
  installed_size="$(du -sk "${package_root}" | awk '{print $1}')"
  cat > "${package_root}/DEBIAN/control" <<EOF
Package: ${KERNEL_IMAGE_PACKAGE}
Version: ${KDEB_PKGVERSION}
Section: kernel
Priority: optional
Architecture: ${DEBIAN_ARCH}
Maintainer: ${KERNEL_PACKAGE_MAINTAINER}
Installed-Size: ${installed_size}
Depends: kmod
Provides: linux-image
Description: Linux ${KERNEL_RELEASE} for the Pine64 PineTab-V
 This package contains the verified PineTab-V kernel, modules, and the two
 board-revision DTBs used by the project's U-Boot boot configuration.
EOF
  cat > "${package_root}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e

if command -v depmod >/dev/null 2>&1; then
  depmod -a '${KERNEL_RELEASE}'
fi

exit 0
EOF
  chmod 755 "${package_root}/DEBIAN/postinst"

  (
    cd "${package_root}"
    while IFS= read -r -d '' packaged_file; do
      md5sum "${packaged_file#./}"
    done < <(find ./boot ./usr -type f -print0 | sort -z)
  ) > "${package_root}/DEBIAN/md5sums"

  log "Building ${KERNEL_IMAGE_PACKAGE} ${KDEB_PKGVERSION} with dpkg-deb"
  dpkg-deb --root-owner-group --build \
    "${package_root}" "${KERNEL_IMAGE_DEB}" >/dev/null

  [[ "$(dpkg-deb --field "${KERNEL_IMAGE_DEB}" Package)" == \
      "${KERNEL_IMAGE_PACKAGE}" ]] || \
    die "The generated .deb has the wrong package name."
  [[ "$(dpkg-deb --field "${KERNEL_IMAGE_DEB}" Version)" == \
      "${KDEB_PKGVERSION}" ]] || \
    die "The generated .deb has the wrong version."
  [[ "$(dpkg-deb --field "${KERNEL_IMAGE_DEB}" Architecture)" == \
      "${DEBIAN_ARCH}" ]] || \
    die "The generated .deb has the wrong architecture."

  verify_dir="$(mktemp -d "${BUILD_DIR}/verify-kernel-deb.XXXXXX")"
  dpkg-deb --extract "${KERNEL_IMAGE_DEB}" "${verify_dir}"
  [[ -s "${verify_dir}/boot/vmlinuz-${KERNEL_RELEASE}" ]] || \
    die "The kernel package lacks /boot/vmlinuz-${KERNEL_RELEASE}."
  cmp -s "${BUILD_DIR}/linux/arch/riscv/boot/Image" \
    "${verify_dir}/boot/vmlinuz-${KERNEL_RELEASE}" || \
    die "The packaged kernel differs from the verified PineTab-V Image."
  cmp -s "${BUILD_DIR}/linux/arch/riscv/boot/Image" \
    "${verify_dir}/boot/Image" || \
    die "The packaged U-Boot Image differs from the verified kernel."
  [[ -s "${verify_dir}/usr/lib/modules/${KERNEL_RELEASE}/modules.dep" ]] || \
    die "The kernel package lacks module metadata for ${KERNEL_RELEASE}."
  cmp -s "${rtw89_build}" \
    "${verify_dir}/usr/lib/modules/${KERNEL_RELEASE}/${rtw89_module_rel}" || \
    die "The packaged rtw89 module differs from the verified kernel build."
  cmp -s "${kernel_dtb_dir}/${PINETABV_DTB}" \
    "${verify_dir}/boot/dtbs/${PINETABV_DTB}" || \
    die "The package does not contain the selected PineTab-V DTB."
  cmp -s "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" \
    "${verify_dir}/boot/dtbs/${PINETABV_FALLBACK_DTB}" || \
    die "The package does not contain the fallback PineTab-V DTB."
  cmp -s "${kernel_dtb_dir}/${PINETABV_DTB}" \
    "${verify_dir}/boot/dtbs/starfive/pine64_pinetabv.dtb" || \
    die "The packaged PineTab-V DTB alias does not match the selected board."
  rm -rf -- "${verify_dir}"
  rm -rf -- "${package_root}"

  log "Verified Debian kernel package ${KERNEL_IMAGE_DEB}"
}

build_hardware_support_deb() {
  local package_root="${BUILD_DIR}/debian-support-package-root"
  local package_dir="${BUILD_DIR}/debian-support-packages"
  local verify_dir=""
  local policy_file=""
  local -a policy_files=(
    etc/libinput/local-overrides.quirks
    etc/dconf/profile/user
    etc/dconf/db/local.d/00-pinetabv-input
    etc/udev/rules.d/71-pinetabv-camera.rules
    etc/wireplumber/wireplumber.conf.d/51-pinetabv-audio.conf
    etc/wireplumber/wireplumber.conf.d/51-pinetabv-camera.conf
    usr/share/alsa/ucm2/PineTabV/PineTab-V.conf
    usr/share/alsa/ucm2/PineTabV/HiFi.conf
    usr/local/bin/pinetabv-camera-select
    usr/local/bin/gnome-control-center
    usr/local/share/dbus-1/services/org.gnome.Settings.service
    usr/local/sbin/pinetabv-input-report
    usr/local/sbin/pinetabv-wireless-report
    usr/local/sbin/pinetabv-display-report
    usr/local/sbin/pinetabv-camera-report
    usr/local/bin/pinetabv-camera-capture
    usr/share/alsa-card-profile/mixer/profile-sets/pinetabv.conf
    usr/share/alsa-card-profile/mixer/paths/pinetabv-output-speaker.conf
    usr/share/alsa-card-profile/mixer/paths/pinetabv-output-headphones.conf
    usr/share/alsa-card-profile/mixer/paths/pinetabv-output-off.conf
    usr/share/alsa-card-profile/mixer/paths/pinetabv-input-internal-mic.conf
    usr/share/alsa-card-profile/mixer/paths/pinetabv-input-headset-mic.conf
    usr/share/alsa-card-profile/mixer/paths/pinetabv-input-off.conf
  )

  HARDWARE_SUPPORT_DEB="${package_dir}/pinetabv-hardware-support_${KDEB_PKGVERSION}_all.deb"
  rm -rf -- "${package_root}"
  install -d "${package_root}/DEBIAN" "${package_dir}"
  (
    ROOT_MNT="${package_root}"
    install_pinetabv_input_policy
    install_pinetabv_input_diagnostics
    install_pinetabv_settings_compat
    stage_pinetabv_desktop_input_defaults
    install_pinetabv_audio_ucm
    install_pinetabv_camera_policy
    install_pinetabv_wireless_diagnostics
    install -Dm755 "${SELF_DIR}/tests/collect-pinetabv-display.sh" \
      "${ROOT_MNT}/usr/local/sbin/pinetabv-display-report"
    install -Dm755 "${SELF_DIR}/tests/collect-pinetabv-camera.sh" \
      "${ROOT_MNT}/usr/local/sbin/pinetabv-camera-report"
    install -Dm755 "${SELF_DIR}/tests/capture-pinetabv-camera.py" \
      "${ROOT_MNT}/usr/local/bin/pinetabv-camera-capture"
    verify_pinetabv_camera_policy
  )
  cat > "${package_root}/DEBIAN/control" <<EOF
Package: pinetabv-hardware-support
Version: ${KDEB_PKGVERSION}
Section: admin
Priority: optional
Architecture: all
Maintainer: ${KERNEL_PACKAGE_MAINTAINER}
Depends: firmware-realtek, wireless-regdb, network-manager, wpasupplicant, bluez, rfkill, iw, udev, wireplumber (>= 0.5), pipewire, alsa-ucm-conf, alsa-utils, libinput-tools, dconf-cli, libspa-0.2-modules, libspa-0.2-libcamera, libcamera-tools, libcamera-ipa, v4l-utils, gstreamer1.0-pipewire, gstreamer1.0-plugins-good, gnome-snapshot, python3
Description: PineTab-V audio, input, camera and wireless integration
 Expose the hardware ISP to desktop camera applications through PipeWire
 V4L2, hide its raw Bayer diagnostic node, and provide a sensor selector.
 Select the repository regulatory database signed by an upstream kernel key.
 Configure ES8316 audio routing and the keyboard-cover touchpad.
 Run GNOME Settings with a board-specific software-rendering workaround.
 This package uses the distribution's unmodified libcamera and firmware.
EOF
  for policy_file in "${policy_files[@]}"; do
    if [[ "${policy_file}" == etc/* ]]; then
      printf '/%s\n' "${policy_file}"
    fi
  done > "${package_root}/DEBIAN/conffiles"
  cat > "${package_root}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# A reboot loads the new kernel and restarts the desktop camera monitors.
if [ "$1" = configure ]; then
  update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream
  dconf update
fi
if [ "$1" = configure ] && [ -S /run/udev/control ] && command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules
fi
EOF
  chmod 755 "${package_root}/DEBIAN/postinst"
  dpkg-deb --root-owner-group --build "${package_root}" "${HARDWARE_SUPPORT_DEB}" >/dev/null
  [[ "$(dpkg-deb --field "${HARDWARE_SUPPORT_DEB}" Version)" == "${KDEB_PKGVERSION}" && \
     "$(dpkg-deb --field "${HARDWARE_SUPPORT_DEB}" Architecture)" == all ]] || \
    die "The hardware support package has incorrect metadata."
  verify_dir="$(mktemp -d "${BUILD_DIR}/verify-support-deb.XXXXXX")"
  dpkg-deb --extract "${HARDWARE_SUPPORT_DEB}" "${verify_dir}"
  for policy_file in "${policy_files[@]}"; do
    cmp -s "${package_root}/${policy_file}" "${verify_dir}/${policy_file}" || \
      die "The hardware support package differs from its staged ${policy_file}."
  done
  [[ "$(readlink "${verify_dir}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V ES8316 Audio.conf")" == \
     ../../PineTabV/PineTab-V.conf ]] || die "The packaged UCM card mapping is missing."
  rm -rf -- "${verify_dir}" "${package_root}"
  log "Verified Debian hardware support package ${HARDWARE_SUPPORT_DEB}"
}

install_hardware_support_deb() {
  [[ -s "${HARDWARE_SUPPORT_DEB}" ]] || die "The hardware support package is missing."
  install -Dm644 "${HARDWARE_SUPPORT_DEB}" \
    "${ROOT_MNT}/opt/pinetabv/hardware-support-packages/$(basename "${HARDWARE_SUPPORT_DEB}")"
  mount_chroot_fs
  if (( TARGET_NEEDS_QEMU == 1 )); then
    ensure_riscv64_binfmt
  fi
  target_chroot_run "apt-get install -y '/opt/pinetabv/hardware-support-packages/$(basename "${HARDWARE_SUPPORT_DEB}")'"
  cleanup_chroot_mounts
  verify_pinetabv_camera_policy
}

install_kernel_deb() {
  local package_basename=""

  [[ -s "${KERNEL_IMAGE_DEB}" ]] || die "Missing Debian kernel package."
  package_basename="$(basename "${KERNEL_IMAGE_DEB}")"
  install -d "${ROOT_MNT}/opt/pinetabv/kernel-packages"
  install -m644 "${KERNEL_IMAGE_DEB}" \
    "${ROOT_MNT}/opt/pinetabv/kernel-packages/${package_basename}"

  log "Installing ${KERNEL_IMAGE_PACKAGE} into Debian"
  mount_chroot_fs
  if (( TARGET_NEEDS_QEMU == 1 )); then
    ensure_riscv64_binfmt
  fi
  target_chroot_run \
    "apt-get install -y --no-install-recommends '/opt/pinetabv/kernel-packages/${package_basename}' && depmod -a '${KERNEL_RELEASE}' && dpkg-query -W '${KERNEL_IMAGE_PACKAGE}'"
  cleanup_chroot_mounts

  [[ -s "${BOOT_MNT}/vmlinuz-${KERNEL_RELEASE}" ]] || \
    die "Installing the kernel package did not populate the FAT /boot partition."
  cmp -s "${BUILD_DIR}/linux/arch/riscv/boot/Image" \
    "${BOOT_MNT}/vmlinuz-${KERNEL_RELEASE}" || \
    die "The installed Debian vmlinuz differs from the compiled Image."
}

finish_debian_chroot() {
  rm -f -- "${ROOT_MNT}/usr/sbin/policy-rc.d"
  if (( TARGET_NEEDS_QEMU == 1 )); then
    rm -f -- "${ROOT_MNT}/usr/bin/qemu-riscv64-static"
    restore_riscv64_binfmt
  fi

  ln -snf /run/systemd/resolve/stub-resolv.conf "${ROOT_MNT}/etc/resolv.conf"
  : > "${ROOT_MNT}/etc/machine-id"
  if [[ -e "${ROOT_MNT}/var/lib/dbus/machine-id" && \
        ! -L "${ROOT_MNT}/var/lib/dbus/machine-id" ]]; then
    : > "${ROOT_MNT}/var/lib/dbus/machine-id"
  fi
}

verify_debian_target() {
  verify_debian_wireless_regdb
  local package_basename="$(basename "${KERNEL_IMAGE_DEB}")"
  local package_record=""
  local camera_package=""
  local bluetooth_firmware=""

  grep -Fqx 'ID=debian' "${ROOT_MNT}/etc/os-release" || \
    die "The target no longer identifies as Debian."
  grep -Fqx 'VERSION_CODENAME=trixie' "${ROOT_MNT}/etc/os-release" || \
    die "The target no longer identifies as Debian 13 trixie."
  grep -Fq 'Suites: trixie trixie-updates' \
    "${ROOT_MNT}/etc/apt/sources.list.d/debian.sources" || \
    die "The Debian 13 archive suites are not pinned correctly."
  grep -Fq 'Suites: trixie-security' \
    "${ROOT_MNT}/etc/apt/sources.list.d/debian.sources" || \
    die "The Debian 13 security suite is missing."

  [[ -s "${ROOT_MNT}/opt/pinetabv/kernel-packages/${package_basename}" ]] || \
    die "The reusable PineTab-V kernel package is missing from the image."
  [[ -x "${ROOT_MNT}/usr/libexec/iio-sensor-proxy" && \
     -s "${ROOT_MNT}/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules" && \
     -s "${ROOT_MNT}/usr/lib/systemd/system/iio-sensor-proxy.service" ]] || \
    die "The final Debian image lacks the IIO sensor-proxy integration."
  grep -Fq 'Package: iio-sensor-proxy' "${ROOT_MNT}/var/lib/dpkg/status" || \
    die "The final Debian image does not record iio-sensor-proxy as installed."
  cmp -s "${KERNEL_IMAGE_DEB}" \
    "${ROOT_MNT}/opt/pinetabv/kernel-packages/${package_basename}" || \
    die "The retained kernel package differs from the package that was installed."
  cmp -s "${BUILD_DIR}/linux/arch/riscv/boot/Image" \
    "${BOOT_MNT}/vmlinuz-${KERNEL_RELEASE}" || \
    die "The dpkg-owned vmlinuz differs from the compiled kernel."

  package_record="$(awk -v RS='' -v package="${KERNEL_IMAGE_PACKAGE}" '
    {
      count = split($0, lines, "\n")
      found = 0
      for (i = 1; i <= count; i++)
        if (lines[i] == "Package: " package)
          found = 1
      if (found) {
        print $0
        exit
      }
    }
  ' "${ROOT_MNT}/var/lib/dpkg/status")"
  [[ "${package_record}" == *'Status: install ok installed'* ]] || \
    die "The PineTab-V kernel package is not installed according to dpkg."
  [[ "${package_record}" == *'Architecture: riscv64'* ]] || \
    die "The installed PineTab-V kernel package has the wrong architecture."
  [[ "${package_record}" == *"Version: ${KDEB_PKGVERSION}"* ]] || \
    die "The installed PineTab-V kernel package has the wrong version."

  # libcamera and its IPA/SPA plugins come directly from the Debian archive.
  # Do not pin the library ABI or replace these packages with local builds.
  for camera_package in pinetabv-hardware-support libcamera-tools libcamera-ipa libspa-0.2-libcamera libspa-0.2-modules gstreamer1.0-pipewire gstreamer1.0-plugins-good gnome-snapshot; do
    package_record="$(awk -v RS='' -v package="${camera_package}" '
      {
        count = split($0, lines, "\n")
        found = 0
        for (i = 1; i <= count; i++)
          if (lines[i] == "Package: " package)
            found = 1
        if (found) {
          print $0
          exit
        }
      }
    ' "${ROOT_MNT}/var/lib/dpkg/status")"
    [[ "${package_record}" == *'Status: install ok installed'* ]] || \
      die "The Debian camera package ${camera_package} is not installed."
  done
  [[ -x "${ROOT_MNT}/usr/bin/cam" ]] || \
    die "The Debian libcamera camera diagnostic tool is missing."
  find "${ROOT_MNT}/usr/lib/${DEBIAN_ARCH}-linux-gnu/spa-0.2" \
    -type f -name '*libcamera*.so' -print -quit | grep -q . || \
    die "The PipeWire libcamera SPA plugin is missing."
  [[ -s "${ROOT_MNT}/usr/lib/${DEBIAN_ARCH}-linux-gnu/spa-0.2/v4l2/libspa-v4l2.so" && \
     -s "${ROOT_MNT}/usr/lib/${DEBIAN_ARCH}-linux-gnu/gstreamer-1.0/libgstpipewire.so" && \
     -s "${ROOT_MNT}/usr/share/applications/org.gnome.Snapshot.desktop" ]] || \
    die "The GNOME camera application or its PipeWire V4L2 backend is missing."

  [[ ! -e "${ROOT_MNT}/usr/sbin/policy-rc.d" ]] || \
    die "The temporary Debian service-start policy remains in the image."
  [[ ! -e "${ROOT_MNT}/usr/bin/qemu-riscv64-static" ]] || \
    die "The build-host QEMU emulator remains in the image."
  [[ ! -s "${ROOT_MNT}/etc/machine-id" ]] || \
    die "The Debian image contains a reused machine ID."
  [[ -L "${ROOT_MNT}/etc/resolv.conf" && \
     "$(readlink "${ROOT_MNT}/etc/resolv.conf")" == \
       /run/systemd/resolve/stub-resolv.conf ]] || \
    die "The Debian resolver link is not configured for systemd-resolved."
  [[ -L "${ROOT_MNT}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" ]] || \
    die "The PineTab-V ttyS0 login service is not enabled."
  [[ -L "${ROOT_MNT}/etc/systemd/system/sysinit.target.wants/systemd-resolved.service" ]] || \
    die "systemd-resolved is not enabled."
  [[ -x "${ROOT_MNT}/usr/sbin/gdm3" ]] || \
    die "The GNOME Display Manager is not installed."
  [[ -x "${ROOT_MNT}/usr/bin/dialog" ]] || \
    die "The dialog program required by debconf is not installed."
  [[ -x "${ROOT_MNT}/usr/bin/libinput" ]] || \
    die "The libinput diagnostics tool is not installed."
  [[ -s "${ROOT_MNT}/etc/dconf/db/local" ]] || \
    die "The GNOME input defaults database is missing."
  grep -Fqx "click-method='areas'" \
    "${ROOT_MNT}/etc/dconf/db/local.d/00-pinetabv-input" || \
    die "GNOME does not default to left/right touchpad button areas."
  grep -Fqx 'tap-to-click=true' \
    "${ROOT_MNT}/etc/dconf/db/local.d/00-pinetabv-input" || \
    die "GNOME does not enable touchpad tapping by default."
  [[ -L "${ROOT_MNT}/etc/systemd/system/display-manager.service" && \
     "$(basename "$(readlink "${ROOT_MNT}/etc/systemd/system/display-manager.service")")" == \
       gdm3.service ]] || \
    die "GDM3 is not the enabled display manager."
  [[ -L "${ROOT_MNT}/etc/systemd/system/default.target" && \
     "$(basename "$(readlink "${ROOT_MNT}/etc/systemd/system/default.target")")" == \
       graphical.target ]] || \
    die "Debian does not default to graphical.target."
  awk -F: -v user="${DEBIAN_DESKTOP_USER}" \
    '$1 == user { found = 1 } END { exit !found }' \
    "${ROOT_MNT}/etc/passwd" || \
    die "The default ${DEBIAN_DESKTOP_USER} desktop account is missing."
  [[ -d "${ROOT_MNT}/home/${DEBIAN_DESKTOP_USER}" ]] || \
    die "The default ${DEBIAN_DESKTOP_USER} desktop home directory is missing."
  for desktop_group in sudo audio video render input pipewire; do
    awk -F: -v user="${DEBIAN_DESKTOP_USER}" -v group="${desktop_group}" \
      '$1 == group { count = split($4, members, ","); for (i = 1; i <= count; i++) if (members[i] == user) found = 1 } END { exit !found }' \
      "${ROOT_MNT}/etc/group" || \
      die "The default ${DEBIAN_DESKTOP_USER} account is not in the ${desktop_group} group."
  done
  [[ -L "${ROOT_MNT}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" ]] || \
    die "NetworkManager is not enabled."
  [[ -L "${ROOT_MNT}/etc/systemd/system/multi-user.target.wants/ssh.service" ]] || \
    die "The OpenSSH server is not enabled."
  [[ -L "${ROOT_MNT}/etc/systemd/system/bluetooth.target.wants/bluetooth.service" ]] || \
    die "The Bluetooth service is not enabled."
  [[ -x "${ROOT_MNT}/usr/bin/pipewire" && \
     -x "${ROOT_MNT}/usr/bin/wireplumber" ]] || \
    die "The Debian GNOME PipeWire audio session is incomplete."
  [[ -s "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/PineTab-V.conf" && \
     -s "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/HiFi.conf" ]] || \
    die "The PineTab-V ALSA UCM profile is missing."
  [[ -L "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V.conf" && \
     "$(readlink "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V.conf")" == \
       ../../PineTabV/PineTab-V.conf ]] || \
    die "The PineTab-V ALSA UCM soundcard mapping is missing."
  [[ -L "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V ES8316 Audio.conf" && \
     "$(readlink "${ROOT_MNT}/usr/share/alsa/ucm2/conf.d/soundcard/PineTab-V ES8316 Audio.conf")" == \
       ../../PineTabV/PineTab-V.conf ]] || \
    die "The PineTab-V ES8316 ALSA UCM card-name mapping is missing."
  [[ "$(grep -Fc 'PlaybackPCM "hw:${CardId},1"' \
       "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/HiFi.conf")" == 2 ]] || \
    die "The PineTab-V ALSA UCM profile does not route playback to PCM 1."
  [[ "$(grep -Fc 'CapturePCM "hw:${CardId},0"' \
       "${ROOT_MNT}/usr/share/alsa/ucm2/PineTabV/HiFi.conf")" == 2 ]] || \
    die "The PineTab-V ALSA UCM profile does not route capture to PCM 0."
  [[ -s "${ROOT_MNT}/usr/lib/firmware/rtw89/rtw8852b_fw-1.bin" ]] || \
    die "Debian firmware-realtek lacks the RTL8852B Wi-Fi firmware."
  bluetooth_firmware="$(
    find "${ROOT_MNT}/usr/lib/firmware/rtl_bt" -maxdepth 1 \
      -type f -name 'rtl8852bu_fw.bin*' -print -quit
  )"
  [[ -n "${bluetooth_firmware}" ]] || \
    die "Debian firmware-realtek lacks the RTL8852BU Bluetooth firmware."
}

verify_target_layout() {
  verify_target_layout_common
  verify_debian_target
}

main() {
  parse_args "$@"
  ensure_root "$@"
  confirm_target
  validate_debian_options

  require_cmd awk basename blkid blockdev chmod chown chroot cmp cp curl dd \
    debootstrap depmod dirname dpkg dpkg-deb du fdtget find findmnt flock git \
    gcc grep install ln losetup lsblk make md5sum mkfs.ext4 mkfs.vfat mktemp \
    mount mv openssl partprobe readlink rm rmdir sed \
    sgdisk sha256sum sleep sort stat sync tail tar truncate udevadm \
    umount uname
  require_cross_toolchain
  detect_target_execution

  prepare_workdirs
  acquire_build_lock
  prepare_debian_archive_keyring
  setup_target_node
  partition_target
  format_filesystems

  fetch_sources
  build_spl_tool
  build_uboot
  build_opensbi_payload
  build_uboot_fit
  build_kernel
  build_kernel_deb
  build_hardware_support_deb

  mount_target_filesystems
  bootstrap_debian_rootfs
  configure_rootfs
  install_pinetabv_input_policy
  install_hardware_support_deb
  install_pinetabv_desktop_input_defaults
  install_pinetabv_audio_ucm
  install_kernel_deb
  install_powervr_firmware
  install_boot_files
  write_bootloader_partitions
  finish_debian_chroot
  verify_target_layout
  finalize_target

  log "Done."
  if [[ -n "${TARGET_DEVICE}" ]]; then
    log "Debian 13 SD card ready: ${TARGET_DEVICE}"
  else
    log "Debian 13 disk image ready: ${IMAGE_FILE}"
  fi
  log "Kernel release: ${KERNEL_RELEASE}"
  log "Kernel package: ${KERNEL_IMAGE_DEB}"
  log "Default DTB: ${PINETABV_DTB}"
  log "OpenSBI ref: ${OPENSBI_EFFECTIVE_REF}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
