# Gentoo PineTab-V SD Builder

`build-pinetabv-gentoo-sd.sh` builds a bootable Gentoo `riscv64` SD card or raw disk image for the PineTab-V.

It does four device-specific things that matter here:

- pulls the current Gentoo `rv64_lp64d` stage3 archive directly from Gentoo's `latest-stage3-...` metadata
- builds StarFive's PineTab-V vendor U-Boot branch plus OpenSBI
- builds StarFive's PineTab-V vendor Linux branch with PineTab-V options forced on
- lays the card out with the JH7110 SD-boot GPT partitions that U-Boot's StarFive documentation expects

## What It Produces

- partition 1: SPL (`2E54B353-1271-4842-806F-E436D6AF6985`)
- partition 2: U-Boot FIT image
- partition 3: FAT32 `/boot`
- partition 4: ext4 Gentoo root filesystem

The boot partition gets:

- `Image`
- `dtbs/`
- `uEnv.txt`
- `vf2_uEnv.txt`
- `extlinux/extlinux.conf`

The installed root filesystem gets:

- `/etc/fstab`
- `/etc/hostname`
- `/etc/timezone`
- `/etc/locale.gen`
- `/etc/portage/repos.conf/pinetabv.conf`

## Host Prerequisites

The script expects a Linux host with:

- root privileges
- a RISC-V cross toolchain named either `riscv64-unknown-linux-gnu-*` or `riscv64-linux-gnu-*`
- `git`, `curl`, `make`, `gcc`, `openssl`
- `sgdisk`, `losetup`, `partprobe`, `udevadm`
- `mkfs.vfat`, `mkfs.ext4`, `tune2fs`

On Gentoo, the cross compiler path the script targets matches the current crossdev-based RISC-V flow documented on the Gentoo wiki.

## Typical Usage

Write straight to a microSD card:

```bash
sudo ./build-pinetabv-gentoo-sd.sh --target /dev/sdX
```

Build a raw disk image instead:

```bash
sudo ./build-pinetabv-gentoo-sd.sh --image ./pinetabv-gentoo.img --size-gb 8
```

Use OpenRC instead of systemd:

```bash
sudo GENTOO_INIT=openrc ./build-pinetabv-gentoo-sd.sh --target /dev/sdX
```

If your tablet behaves more like the older board description:

```bash
sudo PINETABV_DTB=jh7110-pinetab-v.dtb ./build-pinetabv-gentoo-sd.sh --target /dev/sdX
```

The script prompts for the target root password unless you preseed one:

```bash
sudo ROOT_PASSWORD='change-me-now' ./build-pinetabv-gentoo-sd.sh --target /dev/sdX
```

## Notes

- The default DTB is `jh7110-pinetab-v-20230614.dtb`, because the vendor kernel tree carries both `jh7110-pinetab-v.dtb` and `jh7110-pinetab-v-20230614.dtb`, and the latter matches the 2023-06-14 PineTab-V board description shipped in that tree.
- The kernel base is `starfive_visionfive2_defconfig`, then the script forces PineTab-V-specific options back on, including `CONFIG_SECCOMP=y`, `CONFIG_DRM_PANEL_PINETAB_V`, `CONFIG_DRM_PANEL_STARFIVE_JADARD`, `CONFIG_TOUCHSCREEN_GOODIX`, `CONFIG_CHARGER_SC89890H`, and `CONFIG_SND_SOC_ES8316_TABV`.
- The installed rootfs adds a `pinetabv` overlay repo entry but does not automatically emerge overlay packages. That keeps the image build host-agnostic and avoids trying to run target binaries on the build host.

## First Boot

- Insert the card.
- Boot the PineTab-V from microSD. PINE64's PineTab-V documentation notes that boot selection is controlled by the `Vol-` and `Vol+` switches.
- Log in as `root` with the password you supplied to the script.
- Run:

```bash
locale-gen
emerge --sync
emaint sync -r pinetabv
emerge -avuDN @world
```

If you want to move to the overlay's ebuilds later, the repo stub is already in place at `/etc/portage/repos.conf/pinetabv.conf`.

## Sources

- PINE64 PineTab-V page: https://wiki.pine64.org/wiki/PineTab-V
- PINE64 PineTab-V releases page: https://wiki.pine64.org/wiki/PineTab-V_Releases
- U-Boot StarFive VisionFive 2 board docs: https://docs.u-boot.org/en/v2025.07/board/starfive/visionfive2.html
- U-Boot Star64 board docs with JH7110 SD-boot GPT details: https://docs.u-boot.org/en/latest/board/starfive/pine64_star64.html
- Gentoo downloads page: https://www.gentoo.org/downloads/
- Gentoo RISC-V autobuild metadata directory: https://distfiles.gentoo.org/releases/riscv/autobuilds/
- Gentoo VisionFive 2 wiki page: https://wiki.gentoo.org/wiki/VisionFive_2
