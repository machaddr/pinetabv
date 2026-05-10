#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DEVICE=""
IMAGE_FILE=""
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-32}"
ASSUME_YES=0

GENTOO_INIT="${GENTOO_INIT:-systemd}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-pinetabv}"
TIMEZONE_VALUE="${TIMEZONE_VALUE:-UTC}"
LOCALE_VALUE="${LOCALE_VALUE:-en_US.UTF-8}"
WORKDIR="${WORKDIR:-${SELF_DIR}/work-pinetabv}"
INSTALL_TARGET_NETWORK_PACKAGES="${INSTALL_TARGET_NETWORK_PACKAGES:-1}"
TARGET_NETWORK_PACKAGES="${TARGET_NETWORK_PACKAGES:-sys-kernel/linux-firmware net-wireless/wireless-regdb net-wireless/wpa_supplicant net-misc/dhcpcd app-misc/neofetch sys-block/parted}"
QEMU_RISCV_STATIC="${QEMU_RISCV_STATIC:-}"

BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-512}"
BOOT_LABEL="${BOOT_LABEL:-BOOT}"
ROOT_LABEL="${ROOT_LABEL:-GENTOOROOT}"

STAGE3_BASE_URL="${STAGE3_BASE_URL:-https://distfiles.gentoo.org/releases/riscv/autobuilds}"
PORTAGE_SNAPSHOT_URL="${PORTAGE_SNAPSHOT_URL:-https://distfiles.gentoo.org/snapshots/portage-latest.tar.xz}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/starfive-tech/linux.git}"
KERNEL_REF="${KERNEL_REF:-pinetabv-6.6.y-devel}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-starfive_visionfive2_defconfig}"
KERNEL_COMPAT_PATCH="${KERNEL_COMPAT_PATCH:-${SELF_DIR}/patches/linux-pinetabv-compat.patch}"

UBOOT_REPO="${UBOOT_REPO:-https://github.com/starfive-tech/u-boot.git}"
UBOOT_REF="${UBOOT_REF:-pinetabv-devel}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-pine64_pinetabv_defconfig}"
UBOOT_COMPAT_PATCH="${UBOOT_COMPAT_PATCH:-${SELF_DIR}/patches/u-boot-pinetabv-compat.patch}"

OPENSBI_REPO="${OPENSBI_REPO:-https://github.com/riscv-software-src/opensbi.git}"
OPENSBI_REF="${OPENSBI_REF:-latest}"
SPL_TOOL_REPO="${SPL_TOOL_REPO:-https://github.com/starfive-tech/Tools.git}"
SPL_TOOL_REF="${SPL_TOOL_REF:-master}"

PINETABV_DTB="${PINETABV_DTB:-jh7110-pinetab-v-20230614.dtb}"
PINETABV_FALLBACK_DTB="${PINETABV_FALLBACK_DTB:-jh7110-pinetab-v.dtb}"

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
BOOT_MNT="${MNT_DIR}/boot"

LOOP_DEV=""
TARGET_NODE=""
PART_SPL=""
PART_UBOOT=""
PART_BOOT=""
PART_ROOT=""
STAGE3_TARBALL=""
PORTAGE_SNAPSHOT_TARBALL=""
STAGE3_URL=""
OPENSBI_EFFECTIVE_REF=""
KERNEL_RELEASE=""
CHROOT_MOUNTS=()
ORIGINAL_RISCV64_BINFMT_INTERPRETER=""
ORIGINAL_RISCV64_BINFMT_FLAGS=""
ORIGINAL_RISCV64_BINFMT_MAGIC_HEX=""
ORIGINAL_RISCV64_BINFMT_MASK_HEX=""
TEMP_RISCV64_BINFMT_ACTIVE=0

TYPE_GUID_SPL="2E54B353-1271-4842-806F-E436D6AF6985"
TYPE_GUID_UBOOT="BC13C2FF-59E6-4262-A352-B275FD6F7172"

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

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --target /dev/sdX [--yes]
  ${SCRIPT_NAME} --image /path/pinetabv-gentoo.img [--size-gb 32] [--yes]

Options:
  --target PATH      Block device to erase and provision.
  --image PATH       Create and provision a raw disk image file instead.
  --size-gb N        Image size in GiB when --image is used. Default: ${IMAGE_SIZE_GB}
  --yes              Skip the destructive-write confirmation prompt.
  --help             Show this help.

Environment overrides:
  GENTOO_INIT=openrc|systemd
  INSTALL_TARGET_NETWORK_PACKAGES=0|1
  TARGET_NETWORK_PACKAGES="sys-kernel/linux-firmware net-wireless/wireless-regdb net-wireless/wpa_supplicant net-misc/dhcpcd app-misc/neofetch"
  QEMU_RISCV_STATIC=/usr/bin/qemu-riscv64-static
  PORTAGE_SNAPSHOT_URL=https://distfiles.gentoo.org/snapshots/portage-latest.tar.xz
  CROSS_COMPILE=riscv64-unknown-linux-gnu-
  HOSTNAME_VALUE=pinetabv
  TIMEZONE_VALUE=UTC
  LOCALE_VALUE=en_US.UTF-8
  PINETABV_DTB=jh7110-pinetab-v-20230614.dtb
  ROOT_PASSWORD=...
  ROOT_PASSWORD_HASH=...
  WORKDIR=${WORKDIR}

Notes:
  - The script builds StarFive's PineTab-V vendor U-Boot branch, vendor kernel
    branch, OpenSBI, and lays them out on a JH7110-compatible GPT.
  - The default DTB targets the PineTab-V 2023-06-14 board description. If your
    device is a different revision and fails to boot the panel or keys properly,
    rerun with PINETABV_DTB=${PINETABV_FALLBACK_DTB}.
EOF
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
  if [[ -n "${CROSS_COMPILE}" ]]; then
    command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || die "Cross compiler not found: ${CROSS_COMPILE}gcc"
    return
  fi

  local prefix
  for prefix in riscv64-unknown-linux-gnu- riscv64-linux-gnu-; do
    if command -v "${prefix}gcc" >/dev/null 2>&1; then
      CROSS_COMPILE="${prefix}"
      return
    fi
  done

  die "No suitable RISC-V cross toolchain found. Install one and/or set CROSS_COMPILE."
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

  die "INSTALL_TARGET_NETWORK_PACKAGES=1 requires qemu-riscv64-static. Install qemu-user-static or set QEMU_RISCV_STATIC."
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

  [[ "${INSTALL_TARGET_NETWORK_PACKAGES}" == "1" ]] || return

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

  [[ "${INSTALL_TARGET_NETWORK_PACKAGES}" == "1" ]] || return
  (( TEMP_RISCV64_BINFMT_ACTIVE == 1 )) || return
  [[ -e "${register_file}" ]] || return

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
  if [[ -n "${path}" ]] && findmnt -rn -T "${path}" >/dev/null 2>&1; then
    umount -R "${path}" || umount -Rl "${path}" || true
  fi
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
  [[ "${GENTOO_INIT}" == "openrc" || "${GENTOO_INIT}" == "systemd" ]] || die "GENTOO_INIT must be openrc or systemd."
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

assert_target_is_idle() {
  local path="$1"
  local mounted=""

  mounted="$(lsblk -nrpo NAME,MOUNTPOINT "${path}" 2>/dev/null | awk '$2 != "" {print $1 ":" $2}')"
  [[ -z "${mounted}" ]] || die "Target has mounted partitions:\n${mounted}"
}

setup_target_node() {
  if [[ -n "${TARGET_DEVICE}" ]]; then
    [[ -b "${TARGET_DEVICE}" ]] || die "Target is not a block device: ${TARGET_DEVICE}"
    assert_target_is_idle "${TARGET_DEVICE}"
    TARGET_NODE="${TARGET_DEVICE}"
    return
  fi

  install -d "$(dirname "${IMAGE_FILE}")"
  truncate -s "${IMAGE_SIZE_GB}G" "${IMAGE_FILE}"
  LOOP_DEV="$(losetup --show -Pf "${IMAGE_FILE}")"
  TARGET_NODE="${LOOP_DEV}"
}

refresh_partition_nodes() {
  sync
  if [[ -n "${LOOP_DEV}" ]]; then
    losetup -d "${LOOP_DEV}"
    LOOP_DEV="$(losetup --show -Pf "${IMAGE_FILE}")"
    TARGET_NODE="${LOOP_DEV}"
  else
    partprobe "${TARGET_NODE}"
  fi
  udevadm settle
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
}

format_filesystems() {
  log "Formatting boot and root filesystems"
  mkfs.vfat -F 32 -n "${BOOT_LABEL}" "${PART_BOOT}" >/dev/null
  mkfs.ext4 \
    -L "${ROOT_LABEL}" \
    "${PART_ROOT}" >/dev/null
}

stage3_manifest_name() {
  printf 'latest-stage3-rv64_lp64d-%s.txt' "${GENTOO_INIT}"
}

resolve_stage3_url() {
  local manifest_url="${STAGE3_BASE_URL}/$(stage3_manifest_name)"
  local relpath=""

  relpath="$(curl -fsSL "${manifest_url}" | awk '/\.tar\.xz/ { print $1; exit }')"
  [[ -n "${relpath}" ]] || die "Unable to parse stage3 manifest: ${manifest_url}"

  STAGE3_URL="${STAGE3_BASE_URL}/${relpath}"
  STAGE3_TARBALL="${DOWNLOAD_DIR}/$(basename "${relpath}")"
  PORTAGE_SNAPSHOT_TARBALL="${DOWNLOAD_DIR}/$(basename "${PORTAGE_SNAPSHOT_URL}")"
}

download_file() {
  local url="$1"
  local dest="$2"

  if [[ -f "${dest}" ]]; then
    log "Using cached download ${dest}"
    return
  fi

  log "Downloading ${url}"
  curl -fL --retry 5 --retry-delay 2 --retry-connrefused -o "${dest}" "${url}"
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

apply_kernel_compat_patches() {
  [[ -f "${KERNEL_COMPAT_PATCH}" ]] || die "Missing kernel compatibility patch: ${KERNEL_COMPAT_PATCH}"

  log "Applying kernel compatibility patch ${KERNEL_COMPAT_PATCH}"
  if git -C "${SRC_DIR}/linux" apply --reverse --check --whitespace=nowarn "${KERNEL_COMPAT_PATCH}" >/dev/null 2>&1; then
    log "Kernel compatibility patch already applied"
    return
  fi

  git -C "${SRC_DIR}/linux" apply --check --whitespace=nowarn "${KERNEL_COMPAT_PATCH}"
  git -C "${SRC_DIR}/linux" apply --whitespace=nowarn "${KERNEL_COMPAT_PATCH}"
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
  clone_ref "${UBOOT_REPO}" "${UBOOT_REF}" "${SRC_DIR}/u-boot"
  clone_ref "${OPENSBI_REPO}" "${OPENSBI_EFFECTIVE_REF}" "${SRC_DIR}/opensbi"
  clone_ref "${SPL_TOOL_REPO}" "${SPL_TOOL_REF}" "${SRC_DIR}/tools"
  apply_kernel_compat_patches
  apply_u_boot_compat_patches
}

build_spl_tool() {
  log "Building StarFive spl_tool"
  make -C "${SRC_DIR}/tools/spl_tool" clean >/dev/null
  make -C "${SRC_DIR}/tools/spl_tool" >/dev/null
}

build_opensbi() {
  log "Building OpenSBI ${OPENSBI_EFFECTIVE_REF}"
  make -C "${SRC_DIR}/opensbi" \
    O="${BUILD_DIR}/opensbi" \
    PLATFORM=generic \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    -j "${JOBS}" >/dev/null
}

kernel_configure() {
  local kernel_src="${SRC_DIR}/linux"
  local kernel_build="${BUILD_DIR}/linux"
  local config_tool="${kernel_src}/scripts/config"

  log "Configuring PineTab-V kernel"
  make -C "${kernel_src}" \
    O="${kernel_build}" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    "${KERNEL_DEFCONFIG}" >/dev/null

  "${config_tool}" --file "${kernel_build}/.config" \
    --set-str LOCALVERSION -pinetabv \
    --enable SECCOMP \
    --enable RFKILL_GPIO \
    --enable KEYBOARD_GPIO \
    --enable FRAMEBUFFER_CONSOLE_ROTATION \
    --enable TOUCHSCREEN_GOODIX \
    --enable BATTERY_CW2015 \
    --enable CHARGER_SC89890H \
    --enable DRM_PANEL_STARFIVE_JADARD \
    --enable DRM_PANEL_PINETAB_V \
    --enable STARFIVE_DSI \
    --enable SND_SOC_ES8316_TABV \
    --module VIDEO_GC02M2 \
    --module VIDEO_OV5640 \
    --module RTL8852BU

  make -C "${kernel_src}" \
    O="${kernel_build}" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    olddefconfig >/dev/null
}

build_kernel() {
  kernel_configure

  log "Building PineTab-V kernel"
  make -C "${SRC_DIR}/linux" \
    O="${BUILD_DIR}/linux" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    -j "${JOBS}" \
    Image modules dtbs >/dev/null

  KERNEL_RELEASE="$(
    make -s -C "${SRC_DIR}/linux" \
      O="${BUILD_DIR}/linux" \
      ARCH=riscv \
      CROSS_COMPILE="${CROSS_COMPILE}" \
      kernelrelease
  )"
}

build_uboot() {
  local opensbi_fw="${BUILD_DIR}/opensbi/platform/generic/firmware/fw_dynamic.bin"

  [[ -f "${opensbi_fw}" ]] || die "OpenSBI firmware not found: ${opensbi_fw}"

  log "Building PineTab-V U-Boot"
  make -C "${SRC_DIR}/u-boot" \
    O="${BUILD_DIR}/u-boot" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    "${UBOOT_DEFCONFIG}" >/dev/null

  make -C "${SRC_DIR}/u-boot" \
    O="${BUILD_DIR}/u-boot" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    OPENSBI="${opensbi_fw}" \
    -j "${JOBS}" >/dev/null

  "${SRC_DIR}/tools/spl_tool/spl_tool" -c -f "${BUILD_DIR}/u-boot/spl/u-boot-spl.bin" >/dev/null
}

mount_target_filesystems() {
  log "Mounting target filesystems"
  mount "${PART_ROOT}" "${ROOT_MNT}"
  mount "${PART_BOOT}" "${BOOT_MNT}"
}

extract_rootfs() {
  log "Extracting Gentoo stage3"
  tar xpf "${STAGE3_TARBALL}" -C "${ROOT_MNT}" --xattrs-include='*' --numeric-owner
  install -d "${ROOT_MNT}/boot"
}

bootstrap_portage_tree() {
  log "Installing Gentoo Portage snapshot into target root filesystem"
  rm -rf "${ROOT_MNT}/var/db/repos/gentoo"
  install -d "${ROOT_MNT}/var/db/repos"
  tar xpf "${PORTAGE_SNAPSHOT_TARBALL}" -C "${ROOT_MNT}/var/db/repos"

  if [[ -d "${ROOT_MNT}/var/db/repos/portage" && ! -e "${ROOT_MNT}/var/db/repos/gentoo" ]]; then
    mv "${ROOT_MNT}/var/db/repos/portage" "${ROOT_MNT}/var/db/repos/gentoo"
  fi

  [[ -d "${ROOT_MNT}/var/db/repos/gentoo" ]] || die "Portage snapshot did not provide /var/db/repos/gentoo"
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

configure_rootfs() {
  local root_partuuid=""

  root_partuuid="$(blkid -s PARTUUID -o value "${PART_ROOT}")"
  [[ -n "${root_partuuid}" ]] || die "Failed to determine root PARTUUID."

  prompt_for_root_password
  set_shadow_hash "${ROOT_MNT}/etc/shadow" root "${ROOT_PASSWORD_HASH}"

  printf '%s\n' "${HOSTNAME_VALUE}" > "${ROOT_MNT}/etc/hostname"
  printf '%s UTF-8\n' "${LOCALE_VALUE}" > "${ROOT_MNT}/etc/locale.gen"
  printf '%s\n' "${TIMEZONE_VALUE}" > "${ROOT_MNT}/etc/timezone"

  if [[ -e "${ROOT_MNT}/usr/share/zoneinfo/${TIMEZONE_VALUE}" ]]; then
    ln -snf "/usr/share/zoneinfo/${TIMEZONE_VALUE}" "${ROOT_MNT}/etc/localtime"
  else
    warn "Timezone file not found in stage3: ${TIMEZONE_VALUE}"
  fi

  install -d "${ROOT_MNT}/etc/portage/repos.conf"
  install -d "${ROOT_MNT}/var/db/repos/pinetabv"
  install -d "${ROOT_MNT}/var/db/repos/pinetabv/metadata"
  cat > "${ROOT_MNT}/etc/portage/repos.conf/pinetabv.conf" <<EOF
[pinetabv]
location = /var/db/repos/pinetabv
sync-type = git
sync-uri = https://gitlab.com/bingch/gentoo-overlay.git
auto-sync = no
masters = gentoo
EOF

  cat > "${ROOT_MNT}/var/db/repos/pinetabv/metadata/layout.conf" <<EOF
masters = gentoo
EOF

  cat > "${ROOT_MNT}/etc/fstab" <<EOF
LABEL=${BOOT_LABEL}  /boot  vfat  defaults,noatime  0  2
LABEL=${ROOT_LABEL}  /      ext4  defaults,noatime  0  1
EOF

  if [[ "${GENTOO_INIT}" == "openrc" && -f "${ROOT_MNT}/etc/inittab" ]]; then
    if ! grep -q 'ttyS0' "${ROOT_MNT}/etc/inittab"; then
      printf '%s\n' 's0:12345:respawn:/sbin/agetty 115200 ttyS0 vt100' >> "${ROOT_MNT}/etc/inittab"
    fi
  fi

  cat > "${ROOT_MNT}/etc/motd" <<EOF
Gentoo for PineTab-V

First steps after boot:
  1. locale-gen
  2. emerge --sync
  3. emaint sync -r pinetabv
  4. emerge -avuDN @world
  5. Edit /etc/wpa_supplicant/wpa_supplicant.conf for your Wi-Fi credentials
EOF

  printf '%s\n' "${root_partuuid}" > "${WORKDIR}/root.partuuid"
}

install_kernel_modules() {
  log "Installing kernel modules into root filesystem"
  make -C "${SRC_DIR}/linux" \
    O="${BUILD_DIR}/linux" \
    ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    INSTALL_MOD_PATH="${ROOT_MNT}" \
    modules_install >/dev/null
}

mount_chroot_fs() {
  install -d "${ROOT_MNT}/proc" "${ROOT_MNT}/sys" "${ROOT_MNT}/dev" "${ROOT_MNT}/run"

  mount --types proc /proc "${ROOT_MNT}/proc"
  CHROOT_MOUNTS+=("${ROOT_MNT}/proc")

  mount --rbind /sys "${ROOT_MNT}/sys"
  mount --make-rslave "${ROOT_MNT}/sys"
  CHROOT_MOUNTS+=("${ROOT_MNT}/sys")

  mount --rbind /dev "${ROOT_MNT}/dev"
  mount --make-rslave "${ROOT_MNT}/dev"
  CHROOT_MOUNTS+=("${ROOT_MNT}/dev")

  mount --bind /run "${ROOT_MNT}/run"
  CHROOT_MOUNTS+=("${ROOT_MNT}/run")
}

target_chroot_run() {
  local command_string="$1"

  if command -v arch-chroot >/dev/null 2>&1; then
    arch-chroot "${ROOT_MNT}" /qemu-riscv64-static /bin/bash -c \
      "export HOME=/root TERM='${TERM:-dumb}' LANG=C LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; ${command_string}"
    return
  fi

  chroot "${ROOT_MNT}" /qemu-riscv64-static /bin/bash -c \
    "export HOME=/root TERM='${TERM:-dumb}' LANG=C LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; ${command_string}"
}

target_portage_command() {
  local emerge_script=""
  local python_bin=""

  emerge_script="$(find "${ROOT_MNT}/usr/lib/python-exec" -mindepth 2 -maxdepth 2 -path '*/emerge' | sort | tail -n 1)"
  [[ -n "${emerge_script}" ]] || die "Unable to locate the target Portage emerge entry point in ${ROOT_MNT}/usr/lib/python-exec."

  python_bin="$(basename "$(dirname "${emerge_script}")")"
  [[ -x "${ROOT_MNT}/usr/bin/${python_bin}" ]] || die "Unable to locate target Python interpreter: /usr/bin/${python_bin}"

  printf '/usr/bin/%s %s' "${python_bin}" "${emerge_script#${ROOT_MNT}}"
}

append_temp_makeconf_features() {
  local make_conf="${ROOT_MNT}/etc/portage/make.conf"

  install -d "${ROOT_MNT}/etc/portage"
  touch "${make_conf}"
  cat >> "${make_conf}" <<'EOF'

# pinetabv-qemu-begin
FEATURES="${FEATURES} -pid-sandbox -network-sandbox"
# pinetabv-qemu-end
EOF
}

remove_temp_makeconf_features() {
  local make_conf="${ROOT_MNT}/etc/portage/make.conf"
  local tmp_file

  [[ -f "${make_conf}" ]] || return

  tmp_file="$(mktemp)"
  awk '
    /^# pinetabv-qemu-begin$/ { skip = 1; next }
    /^# pinetabv-qemu-end$/ { skip = 0; next }
    !skip { print }
  ' "${make_conf}" > "${tmp_file}"
  mv "${tmp_file}" "${make_conf}"
}

configure_wpa_supplicant() {
  local template="${ROOT_MNT}/etc/wpa_supplicant/wpa_supplicant.conf"
  local systemd_template="${ROOT_MNT}/etc/wpa_supplicant/wpa_supplicant-wlu1u4i2.conf"

  install -d -m 700 "${ROOT_MNT}/etc/wpa_supplicant"
  cat > "${template}" <<'EOF'
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
    ssid="replace-me"
    psk="replace-me"
}
EOF
  chmod 600 "${template}"
  cp "${template}" "${systemd_template}"
  chmod 600 "${systemd_template}"
}

install_target_network_packages() {
  local package_keyword_file="${ROOT_MNT}/etc/portage/package.accept_keywords/pinetabv-network"
  local license_file="${ROOT_MNT}/etc/portage/package.license/pinetabv-network"
  local makeopts_conf="${ROOT_MNT}/etc/portage/env/pinetabv-cross-build.conf"
  local package_env_file="${ROOT_MNT}/etc/portage/package.env/pinetabv-cross-build"
  local portage_cmd=""
  local rc=0
  local pkg

  [[ "${INSTALL_TARGET_NETWORK_PACKAGES}" == "1" ]] || return

  require_qemu_static
  log "Installing target network packages into the image"

  install -Dm755 "${QEMU_RISCV_STATIC}" "${ROOT_MNT}/qemu-riscv64-static"
  cp /etc/resolv.conf "${ROOT_MNT}/etc/resolv.conf"
  install -d "${ROOT_MNT}/etc/portage/package.accept_keywords" \
    "${ROOT_MNT}/etc/portage/package.license" \
    "${ROOT_MNT}/etc/portage/gnupg" \
    "${ROOT_MNT}/etc/portage/env" \
    "${ROOT_MNT}/etc/portage/package.env"
  chmod 700 "${ROOT_MNT}/etc/portage/gnupg"

  : > "${package_keyword_file}"
  for pkg in ${TARGET_NETWORK_PACKAGES}; do
    printf '%s ~riscv\n' "${pkg}" >> "${package_keyword_file}"
  done

  cat > "${license_file}" <<EOF
sys-kernel/linux-firmware linux-fw-redistributable
EOF

  if [[ -f "${ROOT_MNT}/var/db/repos/pinetabv/metadata/layout.conf" ]]; then
    if ! grep -q '^masters[[:space:]]*=' "${ROOT_MNT}/var/db/repos/pinetabv/metadata/layout.conf"; then
      printf '\nmasters = gentoo\n' >> "${ROOT_MNT}/var/db/repos/pinetabv/metadata/layout.conf"
    fi
  fi

  cat > "${makeopts_conf}" <<EOF
MAKEOPTS="-j${JOBS}"
EMERGE_DEFAULT_OPTS="--jobs=1 --load-average=1"
EOF

  cat > "${package_env_file}" <<EOF
sys-kernel/linux-firmware pinetabv-cross-build.conf
net-wireless/wireless-regdb pinetabv-cross-build.conf
net-wireless/wpa_supplicant pinetabv-cross-build.conf
net-misc/dhcpcd pinetabv-cross-build.conf
app-misc/neofetch pinetabv-cross-build.conf
EOF

  portage_cmd="$(target_portage_command)"
  append_temp_makeconf_features
  mount_chroot_fs
  ensure_riscv64_binfmt
  set +e
  target_chroot_run "${portage_cmd} --verbose ${TARGET_NETWORK_PACKAGES}"
  rc=$?
  if (( rc == 0 )); then
    target_chroot_run "depmod -a '${KERNEL_RELEASE}'"
    rc=$?
  fi
  set -e
  cleanup_chroot_mounts
  remove_temp_makeconf_features

  rm -f "${ROOT_MNT}/qemu-riscv64-static"
  (( rc == 0 )) || die "Installing target network packages failed."
  configure_wpa_supplicant
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
  install -d "${BOOT_MNT}/dtbs" "${BOOT_MNT}/dtbs/starfive" "${BOOT_MNT}/extlinux"
  install -Dm644 "${kernel_build}/arch/riscv/boot/Image" "${BOOT_MNT}/Image"
  install -Dm644 "${kernel_build}/System.map" "${BOOT_MNT}/System.map-${KERNEL_RELEASE}"
  install -Dm644 "${kernel_build}/.config" "${BOOT_MNT}/config-${KERNEL_RELEASE}"

  install -Dm644 "${kernel_dtb_dir}/${PINETABV_DTB}" "${BOOT_MNT}/dtbs/${PINETABV_DTB}"
  if [[ -f "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" ]]; then
    install -Dm644 "${kernel_dtb_dir}/${PINETABV_FALLBACK_DTB}" "${BOOT_MNT}/dtbs/${PINETABV_FALLBACK_DTB}"
  fi
  install -Dm644 "${kernel_dtb_dir}/${PINETABV_DTB}" "${BOOT_MNT}/dtbs/starfive/pine64_pinetabv.dtb"

  cat > "${BOOT_MNT}/uEnv.txt" <<EOF
boot2=true
fdtfile=${PINETABV_DTB}
kernel_comp_addr_r=0x40200000
kernel_addr_r=0x40200000
initrd_high=0xffffffffffffffff
bootargs=${kernel_cmdline}
EOF
  cp "${BOOT_MNT}/uEnv.txt" "${BOOT_MNT}/vf2_uEnv.txt"

  cat > "${BOOT_MNT}/extlinux/extlinux.conf" <<EOF
default gentoo
menu title PineTab-V Gentoo
timeout 50

label gentoo
  menu label Gentoo Linux (${KERNEL_RELEASE})
  linux /Image
  fdtdir /dtbs
  append ${kernel_cmdline}
EOF
}

write_bootloader_partitions() {
  local uboot_build="${BUILD_DIR}/u-boot"
  local spl_image="${uboot_build}/spl/u-boot-spl.bin.normal.out"
  local uboot_ssbl=""

  [[ -f "${spl_image}" ]] || die "Missing SPL image: ${spl_image}"

  if [[ -f "${uboot_build}/u-boot.itb" ]]; then
    uboot_ssbl="${uboot_build}/u-boot.itb"
  elif [[ -f "${uboot_build}/u-boot.img" ]]; then
    uboot_ssbl="${uboot_build}/u-boot.img"
  else
    die "Missing U-Boot second-stage image: ${uboot_build}/u-boot.itb or ${uboot_build}/u-boot.img"
  fi

  log "Writing SPL and U-Boot"
  dd if="${spl_image}" of="${PART_SPL}" bs=4M conv=fsync,notrunc status=progress
  dd if="${uboot_ssbl}" of="${PART_UBOOT}" bs=4M conv=fsync,notrunc status=progress
}

main() {
  parse_args "$@"
  ensure_root "$@"
  confirm_target

  require_cmd awk blkid curl dd depmod findmnt git gcc install losetup lsblk make mkfs.ext4 mkfs.vfat mount openssl partprobe sgdisk sync tar tune2fs udevadm umount
  require_cross_toolchain

  prepare_workdirs
  setup_target_node
  partition_target
  format_filesystems

  resolve_stage3_url
  download_file "${STAGE3_URL}" "${STAGE3_TARBALL}"
  download_file "${PORTAGE_SNAPSHOT_URL}" "${PORTAGE_SNAPSHOT_TARBALL}"
  fetch_sources
  build_spl_tool
  build_opensbi
  build_uboot
  build_kernel

  mount_target_filesystems
  extract_rootfs
  bootstrap_portage_tree
  configure_rootfs
  install_kernel_modules
  install_target_network_packages
  install_boot_files
  write_bootloader_partitions

  sync

  log "Done."
  if [[ -n "${TARGET_DEVICE}" ]]; then
    log "SD card ready: ${TARGET_DEVICE}"
  else
    log "Disk image ready: ${IMAGE_FILE}"
  fi
  log "Kernel release: ${KERNEL_RELEASE}"
  log "Default DTB: ${PINETABV_DTB}"
  log "OpenSBI ref: ${OPENSBI_EFFECTIVE_REF}"
}

main "$@"
