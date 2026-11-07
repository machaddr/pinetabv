# PineTab-V Debian 13 Linux 7.3 image builder

This project builds bootable Debian 13 `riscv64` images for the PINE64
PineTab-V, using the Linux **7.3.0-pinetabv** kernel configuration, ordered
hardware-enablement patch series, PineTab-V U-Boot, OpenSBI payload, SPL,
firmware and board-revision DTBs.

The standalone `build-pinetabv-debian-sd.sh` builder can create a raw image or
write directly to a block device.

All diagnostic programs live under `tests/`; there are intentionally no test
wrappers in the project root.

This is an integration and hardware-test project. Successful compilation,
DTB validation and QEMU userspace boot do not prove that DSI, cameras, sound,
charging, radio, GPU or suspend work electrically on every tablet. Use the
physical UART workflow before treating an image as reliable.

## Pinned boot stack

| Component | Ref | Commit |
| --- | --- | --- |
| Linux mainline release | `v7.3` | `c03c1a14507dfaf8b856c2608f9ac216021fc222` |
| StarFive/PineTab-V U-Boot | `pinetabv-devel` | `196f587b957a7a7b2900de53b1cafb6ae034de0d` |
| OpenSBI | `v1.9` | `cbf9f6734dd85a982c63e3cb5db7ffe09da839ca` |
| StarFive SPL tool | `master` | `a9df16e9b8a6f36c55d3a74cb9ac269c0f871739` |

The builder aborts when a named ref does not resolve to its pinned commit.
Linux identifies itself as `7.3.0-pinetabv` and does not use a dirty suffix.

## Hardware coverage

The ordered series in `patches/linux-7.3/series` contains 116 patches. It keeps
the Linux 7.3 JH7110 implementation and adds the PineTab-V-specific pieces that
are absent or incomplete.

| Hardware | Implementation |
| --- | --- |
| Display | Verisilicon DC8200, JH7110 display NoC, Cadence DSI, M31 D-PHY TX and BOE/Jadard JD9365 panel initialization |
| Backlight | OpenCores PTC PWM controller and `pwm-backlight` on the board PWM/GPIO wiring |
| Touch | Goodix GT911 over I2C with reset and interrupt GPIOs |
| Regulators | AXP15060 through the AXP20x MFD/regulator framework and the board rail map |
| Charging | SC89890H support in the BQ25890-family driver, board limits, IRQ and OTG regulator control |
| Battery | CW2015 gauge, vendor battery profile, low-state-of-charge alert and charger relationship |
| Cameras | OV5640, GC02M2, GPIO video mux, Cadence CSI-2 RX and experimental JH7110 CAMSS pipeline |
| Audio | JH7110 DesignWare I2S, ES8316 codec, microphones, headphone and speaker amplifier topology |
| GPU | Experimental PowerVR BXE-4-32 kernel support and exact BVNC firmware |
| Storage | microSD, eMMC, SPI NOR and PCIe/NVMe board wiring |
| Connectivity | Cadence USB3, RTL8852BU Wi-Fi/Bluetooth, rfkill and required Realtek firmware |
| Other devices | HYM8563 RTC, keys, hall switch, LEDs, thermal sensor, watchdog and revision-2 SC7A20 accelerometer |

Recent reliability fixes include:

- removing the unsafe panel `prepare_prev_first` sequence that could reset and
  initialize the Jadard controller after the DSI host had started video;
- retrying the complete PineTab-V panel reset/command sequence after a
  transient DSI transfer failure;
- retrieving JH7110 I2S firmware match data and programming the internal MCLK
  and BCLK rates before reset release, preventing both controllers from timing
  out;
- preserving the vendor PineTab-V direct-link topology, with capture on the
  JH7110 receive DAI and playback on the transmit DAI sharing the ES8316 codec;
- associating the SC89890H power supply with its firmware node so CW2015 can
  resolve its `power-supplies` reference;
- avoiding optional rtw89 ACPI `_DSM` calls when a Device Tree device has no
  ACPI companion; and
- clearing primary-plane enable during an atomic disable and explicitly
  programming linear scanout instead of inheriting firmware tiling settings;
- building the revision-2 SC7A20 accelerometer transport and core into the
  kernel, validating its vendor orientation matrix in the generated DTB, and
  installing `iio-sensor-proxy` for GNOME automatic rotation; and
- exposing 101 PWM brightness levels and using systemd-backlight to save the
  selected level at shutdown and restore it on the next boot.

The revision-5 update fixes display startup reset/retry handling and separates
desktop microphone selection from output selection. It adds independent
**Off** routes for playback and capture, and corrects camera input reselection
and desktop size negotiation.
Build and tablet-update instructions are below. Prebuilt images and update
bundles are not included in this source repository.
Repeated physical boots and camera capture still need testing on the tablet.

The revision-3 update corrects inverted physical volume keys, ES8316 clock and
duplex-format state, microphone selection with ordinary headphones, and
includes the keyboard-cover policy in the update package. GNOME Settings uses
a board-specific software-rendering/media workaround for the reported
Mouse & Touchpad panel crash; the exact crash still needs a tablet backtrace.

Revision 4 addresses the follow-up report that startup/shutdown noise occurs
only on speakers and lasted longer with revision 3. It corrects speaker
amplifier sequencing, removes the board's delayed playback power-down and
replaces indefinite idle playback with a one-second suspend timeout.

Micro-HDMI remains intentionally disabled. The available StarFive HDMI code is
tied to an older display architecture and is not a compliant drop-in addition
to the current DC8200 graph/bridge driver.

## Board revisions and DTBs

The default is the revision-2 DTB:

- `jh7110-pine64-pinetab-v-20240730.dtb`: revision 2.0, panel reset on system
  GPIO51, volume-up on AON GPIO0 and SC7A20 accelerometer at `0x18`.
- `jh7110-pine64-pinetab-v-20230614.dtb`: revision 1.0, volume-up on system
  GPIO51 and no controllable panel reset.

Volume-down uses system GPIO49 on both revisions. The builder validates the
GPIO controller, pin, polarity and Linux keycode for both buttons in each DTB.

Both fresh DTBs are installed. The selected one is also copied to
`/dtbs/starfive/pine64_pinetabv.dtb`. Select the old board only when necessary:

```bash
sudo PINETABV_DTB=jh7110-pine64-pinetab-v-20230614.dtb \
  ./build-pinetabv-debian-sd.sh --image ./pinetabv-debian.img --yes
```

## Host requirements

The builder requires Linux with root privileges and:

- a complete `riscv64-linux-gnu-*` cross toolchain;
- `git`, `curl`, GNU Make, GCC, OpenSSL and normal kernel build tools;
- `sgdisk`, `losetup`, `partprobe`, `udevadm` and `util-linux`;
- `mkfs.vfat`, `mkfs.ext4` and `e2fsck`;
- `fdtget` from Device Tree Compiler tools;
- `qemu-riscv64-static` plus working `binfmt_misc` for foreign target commands;
- `debootstrap` with a Debian 13/trixie script; and
- `dpkg` and `dpkg-deb`.

Debian Release-file authentication is mandatory. The builder uses the host's
`debian-archive-keyring.gpg` when present; otherwise it downloads Debian's
pinned `debian-archive-keyring_2025.1_all.deb`, verifies the published SHA-256,
extracts its archive keyring into the build workspace, and passes it to debootstrap with
`--force-check-sig` before touching the target image.

The Debian builder stages the already verified kernel Image, modules and two
PineTab-V DTBs, then creates a native `riscv64` binary package directly with
`dpkg-deb`. It does not require Debian's `debhelper`, `fakeroot`, kernel header
package dependencies or a Debian build host. The normal cross compiler remains
`riscv64-linux-gnu-gcc`.

The builder prompts for a root password. Non-interactive builds must provide
`ROOT_PASSWORD` or a precomputed `ROOT_PASSWORD_HASH`.

Build downloads, sources and staging live under `work-pinetabv-debian/`.
The UART and QEMU tools place new logs in its `logs/` directory unless a
different output path is supplied.

## Build Debian 13

Debian 13 “trixie” is pinned by codename rather than the moving `stable` alias.
It is bootstrapped with the official `riscv64` architecture from
`https://deb.debian.org/debian`.

```bash
sudo ./build-pinetabv-debian-sd.sh \
  --image ./pinetabv-debian.img --yes
```

Direct microSD installation is also supported:

```bash
sudo ./build-pinetabv-debian-sd.sh --target /dev/sdX
```

The Debian builder:

1. performs a two-stage foreign `debootstrap` through
   `qemu-riscv64-static` when the host is not RISC-V;
2. pins `trixie`, `trixie-updates` and `trixie-security` using deb822 APT
   sources with `main`, `contrib`, `non-free` and `non-free-firmware`;
3. suppresses service starts inside the build chroot with a temporary
   `policy-rc.d`;
4. installs systemd, NetworkManager, WPA supplicant, BlueZ, Realtek firmware,
   ALSA, V4L2 and the official Debian `libcamera-tools`, `libcamera-ipa` and
   `libspa-0.2-libcamera` binary packages;
5. builds and byte-verifies a `linux-image-7.3.0-pinetabv` `riscv64` binary
   package with `dpkg-deb`, containing `/boot/Image`, the versioned kernel,
   modules and both PineTab-V DTBs;
6. installs that package with APT while the real FAT filesystem is mounted at
   `/boot`;
7. retains the exact `.deb` in `/opt/pinetabv/kernel-packages/` inside the
   image and under `work-pinetabv-debian/build/debian-packages/` on the host;
8. separately installs and byte-compares `/Image`, both DTBs, config and
   System.map for the PineTab-V U-Boot layout; and
9. removes the temporary emulator, service policy and machine identity before
   publishing the image.

The default package version is `7.3.0-1+pinetabv5`. Increment
`KDEB_PKGVERSION` when publishing a changed patch set:

```bash
sudo KDEB_PKGVERSION=7.3.0-1+pinetabv6 \
  ./build-pinetabv-debian-sd.sh --image ./pinetabv-debian.img --yes
```

The package metadata identifies `André Machado <machaddr@falanet.org>` as its
maintainer. Override `KERNEL_PACKAGE_MAINTAINER` only when another person takes
responsibility for a separately published package build.

Do not install Debian's generic `linux-image-riscv64` in this image unless you
also deliberately redesign its boot integration. The PineTab-V extlinux entry
boots the uncompressed `/Image` without an initramfs.

## Image layout and safety

The image uses a four-partition GPT:

| Partition | Purpose |
| --- | --- |
| 1 | StarFive/JH7110 SPL at the ROM-required offset |
| 2 | Verified OpenSBI plus PineTab-V U-Boot FIT payload |
| 3 | 512 MiB FAT32 boot filesystem |
| 4 | ext4 Debian root filesystem |

Image builds are transactional. A temporary `*.building.*` image is created
beside the requested destination and is published only after boot files,
PARTUUIDs, DTBs, kernel modules, firmware, SPL and U-Boot pass read-only final
verification. A failed build does not replace the requested image.

Direct `--target` mode is destructive and requires an explicit confirmation
unless `--yes` is supplied. Verify the block-device path before accepting.

The extlinux menus contain:

- `debian`, the normal default;
- `debian-diagnostics`, adding verbose kernel and DRM logging; and
- `debian-alternate-pcb`, loading the other dated PineTab-V DTB.

## Test the final image

All tests are under `tests/`.

Run the final Debian image:

```bash
./tests/test-pinetabv-images.sh --timeout 120
```

Supply a non-default path or run the QEMU tool directly:

```bash
./tests/test-pinetabv-images.sh \
  --distro debian --debian-image ./pinetabv-debian.img --timeout 120

./tests/run-pinetabv-qemu-uart.sh \
  --image ./pinetabv-debian.img --timeout 120
```

The QEMU runner verifies before booting that:

- GPT partitions 3 and 4 exist;
- extlinux defaults to Debian;
- `/Image` and the 2024-07-30 DTB are selected;
- the root PARTUUID matches the kernel command line;
- the `*-diagnostics` entry contains UART and DRM debug arguments; and
- the image enters Linux `7.3.0-pinetabv`, mounts root and reaches the expected
  Debian ttyS0 login.

QEMU uses `snapshot=on` and cannot modify the source image. QEMU's `virt`
machine is not JH7110 and cannot validate SPL/U-Boot hardware handoff, DSI,
the panel, backlight, cameras, I2S, PMIC, charger, battery, GPU, Wi-Fi or
Bluetooth.

## Physical UART capture

Connect the Pine64 UART adapter to the tablet's USB 2.0 Type-C debug port—the
lower port, furthest from the power button—not the charging/power Type-C port.
Start capture before powering on the tablet:

```bash
./tests/capture-pinetabv-uart.sh \
  --distro debian --image ./pinetabv-debian.img --device /dev/ttyUSB0
```

Press `Ctrl-]` to stop. The tool keeps raw and cleaned logs and reports
markers for:

- exact kernel and dated DTB;
- root mount and userspace/login;
- DRM/framebuffer and DSI/panel failures;
- I2S/soundcard errors;
- SC89890H/CW2015 errors;
- OV5640, GC02M2, CSI and CAMSS failures;
- spurious rtw89 ACPI `_DSM` calls; and
- microSD controller/root-device failures.

Analyze an existing capture or print image-derived, read-only U-Boot commands:

```bash
./tests/capture-pinetabv-uart.sh \
  --distro debian --analyze ./uart.log

./tests/capture-pinetabv-uart.sh \
  --distro debian --image ./pinetabv-debian.img --print-commands
```

## Kernel configuration safeguards

The kernel configuration starts from RISC-V `defconfig`, enables every
PineTab-V dependency, runs `olddefconfig`, then asserts the final built-in,
module and disabled states. Unrelated DRM hardware drivers are disabled; DRM
core/helpers, DC8200, JH7110 Cadence DSI, the BOE panel and PowerVR remain.

Root filesystem, MMC, UART and framebuffer-console support are built in so the
normal extlinux entries do not depend on an initramfs.

The SC7A20 I2C transport, ST accelerometer core and mount-matrix support are
also built in for the revision-2 board. Debian installs the static,
D-Bus/udev-activated `iio-sensor-proxy` service; it must not be manually
enabled as a conventional boot service. On physical hardware, verify the
complete rotation path with:

```bash
dmesg | grep -Ei 'sc7a20|st_accel|iio'
grep . /sys/bus/iio/devices/iio:device*/in_accel_{x,y,z}_raw
cat /sys/bus/iio/devices/iio:device*/in_accel_mount_matrix
systemctl status iio-sensor-proxy
monitor-sensor --accel
```

`CONFIG_RISCV_USER_CFI` is disabled. JH7110 U74 cores do not implement the
Zicfilp/Zicfiss extensions needed by that optional userspace vDSO, so disabling
it removes no usable PineTab-V feature and avoids unsupported toolchain notes.

## Display corruption fixes

The console and GNOME videos show corruption during redraws. The display
patches now address both the initial mapping problem and the remaining
swapchain/imported-buffer synchronization gaps:

- Select cached non-coherent GEM allocations when JH7110 cannot provide an
  uncached mapping, and keep the fbcon shadow buffer and atomic dirty callback.
- Flush the complete allocation when selecting a different framebuffer. DRM
  scene damage describes changes since the previous frame, so it cannot limit
  cache flushing for a newly selected buffer.
- Synchronize imported DMA-BUF scatterlists explicitly. Their allocation flag
  is cleared by PRIME even though the importing DC8200 remains non-coherent.
- Calculate same-buffer damage offsets from the framebuffer origin, including
  cropped sources and allocations without final-row padding.
- Clear inherited tiling, rotation, scaling, clear, ROI and decompression state
  before fetching a linear primary framebuffer.

On the tablet, the expected diagnostic is:

```text
scanout cache maintenance: explicit=1 dma-coherent=0 uncached-mapping=0
```

Repeat console scrolling, GNOME menu open/close, rotation, blank/unblank and
suspend/resume while capturing UART. `primary plane ... FIFO underflow` and
`video stream error` are failures. The synchronization tests exercise the
actual driver C functions; they cannot establish that the physical display
is fully corrected. PowerVR rendering and firmware remain experimental.

## Camera support and repository libcamera

The builder retains unmodified Debian libcamera packages. Debian's
libcamera 0.4.0 simple pipeline does not recognize `starfive-camss`; GNOME
Camera instead uses the stock PipeWire V4L2 backend with the hardware ISP.
The WirePlumber policy hides the raw Bayer diagnostic node and exposes the
processed NV12 output as **PineTab-V Camera**.

The reported `Failed to media_pipeline_start: -32` is `EPIPE`: the old capture
ioctl changed buffer dimensions while the ISP source stayed at its previous
size. The processed node now negotiates both together. It reports valid
sizes/frame intervals and crops within the active sensor image. The front
sensor's native size is 1280x720; smaller outputs are crops, with no upscaling.
Buffer allocation, format changes and sensor selection share one lock, and a
failed sensor switch restores the previous route and formats.

Both physical sensors share one ISP and appear as one desktop camera source.
Close GNOME Camera before selecting the other sensor, then open it again:

```bash
pinetabv-camera-select front
pinetabv-camera-select rear
```

The selector waits briefly for PipeWire to release idle capture buffers. It
uses the stable `/dev/pinetabv-camera` alias rather than a video device number.
The schematic's camera LED is a flash LED, separate from sensor streaming;
these changes do not force it on continuously.

For sustained capture checks on the tablet:

```bash
sudo python3 tests/capture-pinetabv-camera.py --camera front --output front.nv12
sudo python3 tests/capture-pinetabv-camera.py --camera rear --output rear.nv12
```

This helper configures the media graph and checks all 120 captured frames.
The kernel routing remains OV5640/rear on mux input 1 and CSI lanes 2/1, or
GC02M2/front on input 0 and lane 1, following both board schematics.

## Wireless startup fixes

The reported absence of Wi-Fi interfaces and the Bluetooth USB/Oops trace
match a shared radio initialization defect. Both schematics connect the
RTL8852BU module through a GL850G USB 2-only hub and leave its SuperSpeed
pins unconnected. The driver's automatic USB 3 mode switch can disconnect
the combined device before Wi-Fi registration, disrupting Bluetooth commands
in parallel. The board-specific quirk keeps RTL8852B behind hub `05e3:0608`
in USB 2 mode. Other machines, chips and hub models retain their normal path.
The supplied `lsusb` photo confirms this hub ID.

The Bluetooth driver also had an independent error-handling bug: a failed
security-register read could return NULL instead of an error pointer. The
patch preserves the original error and prevents the observed NULL dereference
in `btrtl_download_firmware`; it does not hide a continuing USB protocol error.

`cfg80211` and `mac80211` now load as modules after the root filesystem is
available, so the regulatory database can be read. Debian selects the
repository's upstream-signed database, matching this custom kernel's trusted
keys. Its default Debian-signed alternative does not match those keys.
Signature verification remains enabled. Missing `rtw8852b_fw-2.bin` alone is
not a load failure: this driver deliberately supports the installed `fw-1.bin`
fallback, which the supplied log shows was loaded.

After reboot, verify Wi-Fi enumeration/scanning and Bluetooth power/pairing.
If either still fails, collect the complete read-only report:

```bash
sudo /usr/local/sbin/pinetabv-wireless-report > wireless-report.txt
```

The reporter includes `/usr/sbin` in PATH, where Debian installs `rfkill` and
`iw`, and bounds each command with a timeout.

## Audio and GNOME Settings corrections

The ES8316 driver now restores its MCLK divider on every rate change and
preserves the other direction's serial word length during simultaneous
playback and recording. Duplex streams must share a physical sample width,
and their BCLK calculation uses that width consistently. The desktop policy
uses the board's fixed-clock 48 kHz rate and software volume, enables DAC
soft ramping, and disables analog input-to-headphone bypass paths.

The follow-up tablet test localized the noise to speaker startup/shutdown;
headphones were clean. Revision 3's indefinite idle playback prolonged that
noise, so revision 4 restores playback suspension after one second. Capture
retains normal idle suspension, and USB/Bluetooth audio keep their own settings.

The TT8642 speaker amplifiers share GPIO50. Their DAPM output-driver widget
previously sorted before the ES8316 output drivers, allowing the amplifiers
to hear the codec's startup transition. A separate amplifier subsequence
enables them after the codec output stage and disables them before it. The
PineTab-V link also bypasses ALSA's delayed power-down, which otherwise keeps
the analog path powered for another five seconds after PCM closure. No
arbitrary settling delay or gain change is added. These changes address an
observed sequencing defect; physical confirmation of the remaining clicks is
still required. See the upstream
[ASoC pop/click guidance](https://docs.kernel.org/sound/soc/pops-clicks.html)
and [revision-2 schematic, audio sheet](https://files.pine64.org/doc/PineTab/PineTab-V_Schematic_Ver2-20240730.pdf).

The board detects a headphone plug but cannot distinguish headphones from a
headset with a microphone. The internal microphone is therefore the default
with either plug, and remains available. Select **Headset Microphone**
manually in Sound settings when needed. An explicitly saved headset choice
is respected; choose **Internal Microphone** once after updating if an old
selection is restored.

The GNOME Settings launcher uses `GSK_RENDERER=cairo` and `GTK_MEDIA=none`
only on PineTab-V. These documented GTK controls avoid the experimental GPU
and the mouse/touchpad panel's illustrative WebM playback while preserving
its settings controls. The launcher covers desktop/PATH and D-Bus activation;
it leaves the distribution's GNOME executable and translated desktop files
intact. This is a compatibility workaround pending a crash backtrace, not a
confirmed upstream crash fix. Explicit renderer/media environment values
override the defaults for diagnosis.

If Settings still closes, run this from the affected desktop account after
reproducing it:

```bash
/usr/local/sbin/pinetabv-input-report > input-report.txt
```

The report gathers input capabilities, active quirks, recent errors and
existing coredump metadata. It does not record input events or extract process
memory. GTK controls and audio policy follow the upstream documentation:
[GTK runtime controls](https://docs.gtk.org/gtk4/running.html),
[WirePlumber ALSA configuration](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/alsa.html),
and [ALSA UCM values](https://www.alsa-project.org/alsa-doc/alsa-lib/group__ucm.html).

## Update an existing Debian tablet

After a successful build, the default revision-5 packages are written to:

- `work-pinetabv-debian/build/debian-packages/linux-image-7.3.0-pinetabv_7.3.0-1+pinetabv5_riscv64.deb`
- `work-pinetabv-debian/build/debian-support-packages/pinetabv-hardware-support_7.3.0-1+pinetabv5_all.deb`

Copy both `.deb` files to the tablet and compare their `sha256sum` values with
the originals on the build host. In the tablet's package directory run:

```bash
mountpoint -q /boot || sudo mount /boot
sudo apt install ./linux-image-7.3.0-pinetabv_7.3.0-1+pinetabv5_riscv64.deb \
  ./pinetabv-hardware-support_7.3.0-1+pinetabv5_all.deb
sudo reboot
```

The real FAT boot partition must be mounted at `/boot` so the package updates
the Image and DTBs used by U-Boot. The hardware support package supplies the
audio/input policies, Settings compatibility launcher, camera selector,
diagnostics and upstream regulatory-database selection; its dependencies
remain official Debian packages. This package
installation must run on the tablet, not the build host. If dpkg asks about
`51-pinetabv-audio.conf`, install the package maintainer's version to activate
the independent input/output routes.

New Debian images install and retain both packages.

## GPU limitation

The JH7110 GPU is PowerVR BVNC `36.50.54.182`. The builder installs the exact
firmware and enable the kernel driver's explicit experimental gate. This does
not make the GPU an upstream-supported or conformant Vulkan implementation.

Debian 13's `mesa-vulkan-drivers` package does not contain the experimental
PowerVR Vulkan ICD. Hardware-accelerated Vulkan therefore requires a separate
Mesa build with the Imagination experimental driver enabled. Do not describe
the stock Debian userspace as accelerated merely because the kernel module and
firmware load.

## Validation of the 7.3 update

The initial 105-patch update compiled on 2026-10-24. Physical testing then
reported remaining display corruption, camera `EPIPE`, missing radios and a
Bluetooth NULL-pointer Oops. Revision 2 adds fixes for those observed paths.

Revision-2 validation passed on 2026-10-24 using pristine upstream `v7.3` at
`c03c1a14507dfaf8b856c2608f9ac216021fc222`, applies the complete ordered series,
and matched all 112 touched source files. The RISC-V build passed for Image, modules,
both dated DTBs, the Debian kernel package and the hardware support package,
with no compiler warnings or errors. The Image is 29,708,800 bytes.
Package payloads were compared with their staging files, and the builder's
DTB topology and final configuration assertions passed.

Host regression tests extract actual C functions for framebuffer cache
synchronization, camera format negotiation and sensor-switch rollback,
Bluetooth initialization failures, and USB-mode policy. Run them against a
fully patched kernel source:

```bash
python3 tests/test-pinetabv-camera.py
python3 tests/test-pinetabv-camera-format.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-camera-input.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-display-cache.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-bluetooth-init.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-radio-mode.py --kernel-source /path/to/linux
```

Shell syntax, ShellCheck error checks, WirePlumber policy matching, udev-rule
validation and kernel coding-style checks are also performed. Physical camera
capture, the absence of display artifacts and radio operation require a new
tablet test after installing this update.

Historical binary bundles and their build manifests are not included here;
the source patches and regression programs remain available for reproduction.

Revision 3 adds two kernel patches and packages the audio and input policies
for existing tablets as well as new images. Its Image, modules and both DTBs
cross-compile successfully. All 111 patches replay against the pinned kernel,
and the replayed sources match the build tree. The ES8316 regression exercises
the actual C function at six supported sample rates, both duplex start
orders and invalid parameters. The generated UCM and WirePlumber policy are
parsed with their real libraries; microphone priorities, capture suspension
and isolation from other sound cards are checked. Run the new checks with:

```bash
python3 tests/test-pinetabv-audio-clock.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-audio-policy.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-settings.py
```

The policy test needs host ALSA/WirePlumber development libraries and
`pkg-config`. Install freshly built packages on the tablet or build a new
image to use these changes.
Physical checks for residual pops/noise, headphone/internal-mic routing,
volume-key actions and opening GNOME Mouse & Touchpad remain pending.

Revision 4 adds the speaker amplifier subsequence and a PineTab-V-only
immediate power-down-on-close rule. Its additional regression extracts the
real DAPM widget definitions, ordering comparator, amplifier GPIO callback
and core shutdown decision to check startup/shutdown ordering and retention
of the default delay on other sound cards:

```bash
python3 tests/test-pinetabv-speaker-power.py --kernel-source /path/to/linux
```

Revision-4 validation replayed all 113 patches, and the 115 touched
source files match the build tree; Image, modules and DTBs cross-compile
without compiler warnings/errors. Retest short sounds, play/pause, idle, and headphone
insertion/removal on the tablet; a passing host test cannot measure a speaker
transient or establish that all audible clicks are gone.

Revision 5 establishes the JH7110 DSI byte-clock reset before starting wrapper
clocks, retries the complete panel wake-up including its first LP-11 command,
and keeps the backlight off when preparation fails. The desktop audio policy
uses one duplex ACP profile with independent speaker/headphone/Off and
internal-microphone/headset-microphone/Off ports. Changing a microphone no
longer selects a different playback profile. Off disconnects that direction's
signal path; microphone Off does not promise to remove bias needed by jack
detection.

Camera input reselection now preserves the existing crop, formats and buffers.
The ISP advertises its native size and supported common discrete crops to
avoid PipeWire's incorrect translation of stepwise V4L2 size ranges. The real
SPA negotiation test reproduces the old 640×480 rejection and confirms that
the discrete sizes match. Arbitrary aligned `TRY_FMT`/`S_FMT` crops still work.
The GPIO55 white LED is a flash LED in the board schematic, not a recording
indicator. Its staying off is not a test of camera capture. Sensor identity,
probe errors and physical capture still need verification on the tablet.

Additional regression commands are:

```bash
python3 tests/test-pinetabv-display-startup.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-audio-routes.py
python3 tests/test-pinetabv-camera-input.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-camera-enumeration.py --kernel-source /path/to/linux
python3 tests/test-pinetabv-camera-policy.py
```

The camera enumeration test needs PipeWire SPA development headers. The
audio route test requires `spa-acp-tool`, ALSA development files,
`pkg-config` and a native C compiler. It uses a private mock ALSA control card
and null PCMs with the real ACP parser; it does not open the host's hardware.

The support package installs `pinetabv-display-report`,
`pinetabv-camera-report` and `pinetabv-camera-capture`. Reports collect state
without changing modes, sensor selection, LED state or service state. A
capture command explicitly selects/configures a sensor and writes NV12 frames.
Build a new image or install the two freshly built packages using the
tablet-update instructions above to use the new kernel and policies.

## Hardware acceptance

At minimum, repeat these tests on the applicable board revisions:

1. Multiple cold boots, warm reboots and full power cycles from microSD.
2. Panel color patterns, rotation, blank/unblank, suspend/resume, repeated PWM
   brightness sweeps and saved-brightness restoration after a clean reboot.
3. Multi-touch at every edge and corner, including while charging.
4. Charger attach/detach and current/voltage/fault reporting with controlled
   USB sources; never test OTG in a configuration that can back-feed a sink.
5. A controlled full battery charge/discharge cycle and low-SoC interrupt.
6. Front/rear camera enumeration, sensor switching and sustained frame capture
   while monitoring CSI CRC/ECC/FIFO errors.
7. Speakers, headphones, jack state, microphones, capture/playback rates and
   audio suspend/resume.
8. Wi-Fi throughput, Bluetooth pairing/rfkill, USB, eMMC, microSD, NVMe, RTC,
   keys, thermal behavior and the revision-2 accelerometer.
9. GPU cold boot, queue submission, unload/reload, memory pressure, recovery
   and suspend/resume with an appropriate experimental Mesa userspace.

Do not hide a reproducible hardware error with an unbounded retry or delay.
Capture complete UART and `dmesg` evidence and fix the failing dependency or
state transition.

## AI assistance and DCO

AI-assisted patches identify that assistance with an `Assisted-by` trailer.
Every patch still requires human review for correctness, licensing,
provenance, hardware safety and Linux coding style. A human submitting patches
upstream is responsible for understanding the changes and adding or affirming
their own `Signed-off-by` under the Developer Certificate of Origin.

AI assistance does not replace subsystem review or physical testing. Apply
extra scrutiny to the GC02M2 sensor, restored staging CAMSS, SC89890H support,
camera mux/lane selection, DSI/panel timing and experimental PowerVR paths.

## Primary sources

- DRM framebuffer damage contract: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/gpu/drm/drm_plane.c?h=v7.3#n1580
- Linux releases: https://www.kernel.org/
- Linux kernel build/package variables: https://docs.kernel.org/kbuild/kbuild.html
- Linux reset control API: https://docs.kernel.org/driver-api/reset.html
- WirePlumber ALSA/ACP configuration: https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/alsa.html
- PipeWire V4L2 size negotiation: https://github.com/PipeWire/pipewire/blob/1.4.2/spa/plugins/v4l2/v4l2-utils.c
- Linux custom Debian package guidance: https://docs.kernel.org/admin-guide/quickly-build-trimmed-linux.html
- Linux coding-assistant policy: https://docs.kernel.org/process/coding-assistants.html
- Debian 13 release: https://www.debian.org/News/2025/20250809
- Debian 13 RISC-V installation guide: https://www.debian.org/releases/trixie/riscv64/
- Debian foreign debootstrap: https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html
- Debian archive keyring package: https://packages.debian.org/trixie/debian-archive-keyring
- Debian APT sources format: https://manpages.debian.org/trixie/apt/sources.list.5.en.html
- PINE64 PineTab-V schematics: https://pine64.org/documentation/PineTab-V/Further_information/Schematics/
- Revision-1 schematic: https://files.pine64.org/doc/PineTab/PineTab-V_Schematic_Ver1-20230614.pdf
- Revision-2 schematic: https://files.pine64.org/doc/PineTab/PineTab-V_Schematic_Ver2-20240730.pdf
- StarFive PineTab-V vendor tree: https://github.com/starfive-tech/linux/tree/pinetab-v1.3.0
- JH7110 datasheet: https://doc-en.rvspace.org/JH7110/PDF/JH7110_DS.pdf
- Verisilicon mapping capability RFC: https://lore.kernel.org/r/20260930073528.3369325-2-zhengxingda@iscas.ac.cn
- Verisilicon framebuffer synchronization RFC: https://lore.kernel.org/r/20260930073528.3369325-3-zhengxingda@iscas.ac.cn
- Debian libcamera packages: https://packages.debian.org/trixie/libcamera-tools
- Mesa PowerVR status: https://docs.mesa3d.org/drivers/powervr.html
- PowerVR firmware: https://gitlab.freedesktop.org/imagination/linux-firmware/-/tree/powervr/powervr
