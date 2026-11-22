# Xiaomi Mi Pad 5 Pro (elish) — Linux Driver Package<br>Sensors · Fingerprint · GNSS · Camera

[中文说明](README.md)

A repeatable **driver / system-integration package** for the **Xiaomi Mi Pad 5 Pro**
(Qualcomm **SM8250 / elish**, CSOT panel, Wi-Fi model) running Armbian Linux.
It bundles four subsystems on one shared kernel / DTB / boot image:

- **Sensors (SLPI/SSC)** — ambient light, accelerometer, rotation-vector orientation, compass heading;
- **Fingerprint (Goodix GF3626)** — fprintd enroll/verify, GDM lock/login, sudo fingerprint;
- **GNSS (Airoha AG3335)** — QUP5 UART + `airoha-gnssd` + gpsd + GeoClue2;
- **Camera (OV8856 / OV13B10 / Hi556)** — full-resolution photo/record, GPU debayer, Venus H.264/HEVC
  encode, two V4L2 virtual cameras, PipeWire/portal, rear autofocus.

- **Version**: 2026.11.21
- **Device**: Xiaomi Mi Pad 5 Pro (elish, CSOT panel, Wi-Fi)
- **System**: Armbian 26.8.14 (Ubuntu 24.04 noble) + kernel `6.18.44-current-sm8250`
- **License**: original parts of this package are **MIT** (see `LICENSE`); upstream components keep their own licenses.

> **Packaging policy**: this package contains **code, patches, system configuration, scripts and docs only**.
> It does **not** ship firmware, device data, logs, fingerprint templates, keys/serials, PAM backups,
> or prebuilt userspace binaries. The only bundled binary is the **model-level combined DTB**
> (no per-unit private information; rationale in `kernel/dtb/README.md`).
> Required vendor data/firmware is extracted from **your own device / official distributions** —
> see `docs/DEVICE-DATA-EXTRACTION.md`.

---

## Contents

- [Support status at a glance](#support-status-at-a-glance)
- [Tested system versions](#tested-system-versions)
- [Measured results](#measured-results-2026-11-21-same-device)
- [Package layout](#package-layout)
- [Installation](#installation)
- [Building](#building)
- [Verification](#verification)
- [Known limitations](#known-limitations)
- [Credits / upstream](#credits--upstream)
- [License](#license-mit)

---

## Support status at a glance

> ✅ works (tested) · ⚠️ works with known limitations · 🚫 limited / incomplete · — not present on this device

| Subsystem | Component | Status | Notes |
|---|---|---|---|
| **Sensors** | SLPI/SSC stack: accelerometer, ambient light, rotation vector, compass heading | ✅ | Auto-brightness / auto-rotate work; sensors ready **~21 s** after boot (after M2) |
| Sensors | Boot-time acceleration (L2/M1/M2) | ✅ | Early service start + writable hexrpc registry: PD init 35 s → **8.2 s** |
| Sensors | Suspend/resume recovery | ✅ | Sleep hook + worker; sensors re-claimed **3–6 s** after resume (after 0009) |
| Sensors | **s2idle sleep death** (whole system hangs after wake, needs long power press) | ✅ | **Root-caused and fixed**: `kernel/patches/0009-fastrpc-listener-unfreezable.patch`; **20 s2idle cycles** (incl. 10 h 47 m and 5 h 50 m sleeps) with **zero crashes**, 11-19 → 11-21 |
| Sensors | Raw gyroscope / magnetometer axes / proximity (SAR) | 🚫 | Not exposed by userspace (libssc/udev layer); not a hardware-driver gap |
| **Fingerprint** | Goodix GF3626: fprintd enroll/verify, GDM lock/login, sudo | ✅ | TA must be extracted from your own device; TA-refusal watchdog included |
| **Biometric auth (optional)** | bioauth: generic PAM biometric stack (fingerprint/password, single fullscreen UI, optional sudo/pkexec wiring) | ✅ | **Not installed by default**; `--with-bioauth`, docs in `bioauth/INSTALL.md` |
| **GNSS** | Airoha AG3335: QUP5 UART + PAIR + gpsd + GeoClue2 | ✅ | Real outdoor fix validated (mode=3, 12 sats); GeoClue location + compass heading; Pure Maps validated |
| **Camera** | Front OV8856 3280×2464 / rear OV13B10 4208×3120 full-res photo/record | ✅ | GPU debayer + Venus HEVC/H.264 at ~30 fps; two V4L2 virtual cameras |
| Camera | Rear AF/AE/AWB, CN3927V VCM, EEPROM 24c64 | ✅ | Software AF sweep writes the focus sysfs |
| Camera | PipeWire / xdg-desktop-portal / Snapshot | ✅ | Two `media.role=Camera` nodes; portal frame capture validated |
| Camera | LSC / CCM image tuning | ✅ | **No tuning data is shipped**; only on-device read-only extraction scripts. After local extraction: enabled by default (rear vignetting 4.4× → ~1×); neutral/off without data; disable with `ELISH_LSC=0`/`ELISH_CCM=0` |
| Camera | Hi556 depth sensor | ⚠️ | **RAW streaming verified** (2592×1944 SGRBG10 @ ~30 fps, checker test pattern); nodes merged into the **single joint DTB**; no depth/colour userland yet |
| Camera | Front and rear streaming simultaneously | 🚫 | CAMSS/DTB resource limit; one camera at a time |
| **Camera flash / torch** | Rear flash LED (PM8150L `white:flash`): boot-flash fix + torch | ✅ | **Boot-logo flash fixed** (default `flash-led/` component); optional GNOME 46 Quick Settings torch toggle + `torch` CLI (`--with-torch`, not installed by default) |
| **Kernel/System** | Combined DTB (sensor vmids + fingerprint node + GNSS QUP5 UART + camera nodes + Hi556) | ✅ | Model-level, no per-unit private data; see `kernel/dtb/README.md` |
| Kernel | fastrpc SDSP VMID / sensors-PD, QSEECOM/TEE, mdt_loader, qcom_scm, goodix_fp_spi | ✅ | Fingerprint/sensor kernel layer |
| Kernel | LPASS pinctrl clock-timeout defer (pogo keyboard/USB random failures) | ✅ | Stand-alone patch `kernel/patches/0002-…` |
| Kernel | SMB5 Type-C legacy/100 mA resume hang | ✅ | Verified with 3 suspend/resume cycles with charger attached |
| System | Display/touch/pen/hall/battery/audio/Wi-Fi/BT/USB HID/GPU/UFS/PCIe/Venus | ⚠️ | Platform baseline; **audio fixed on 2026-11-13** (PulseAudio/WirePlumber PCM contention; see `docs/HARDWARE-STATUS.md`) |
| System | Screen orientation / tablet mode / auto-rotate configuration | ⚠️ | `tablet_mode=on/off/auto`, `rebuild_mode`; optional `tablet-mode/` component (Quick Settings switch + uinput virtual hall) works without a cover |
| System | Pogo keyboard after suspend/resume | ✅ | HID-hang workaround (default `pogo/` component): every wake pulses the keyboard reset GPIO (TLMM 141) 3 s after resume; keyboard re-enumerates in ~1–1.5 s. **Do not** use `authorized`/`USBDEVFS_RESET`/controller rebind |
| System | Charging | ⚠️ | 5 V baseline + **PD 9 V fast charge + bq2597x dual charge pumps working** (~18–20 W at the battery); PPS 11 V with keep-alive works reliably (~20.5 W at 50–56 %, +8 % over fixed) via the optional `pps-charger/` service; 66 W would need the vendor proprietary protocol |
| — | 5G variant | — | This unit is Wi-Fi only (5G variant is outside this package's test scope; other misc hardware is absent on all variants) |

The authoritative hardware baseline is [`docs/HARDWARE-STATUS.md`](docs/HARDWARE-STATUS.md).

---

## Tested system versions

| Item | Value |
|---|---|
| Device | Xiaomi Mi Pad 5 Pro (codename **elish**, CSOT panel, Wi-Fi) |
| SoC | Qualcomm Snapdragon 870 (**SM8250**) |
| Distribution | **Armbian 26.8.14 noble** (Ubuntu 24.04 LTS userspace), GNOME 46 |
| Kernel | **`6.18.44-current-sm8250`** (Armbian sm8250 baseline + this package's patches; see `kernel/README.md` for BTF/ABI requirements) |
| Boot | The Linux slot is read from `abl_boot_partition_label` in `/boot/armbianEnv.txt` (`boot_b` on this unit; the scripts follow it and **never hardcode** it); only that slot is written, the **Android slot is not touched** |
| Panel | CSOT (combined DTB is `sm8250-xiaomi-elish-csot.dtb`; BOE variant untested) |
| Kernel source (to build) | Matching Armbian sm8250 tree (e.g. `/var/tmp/kbuild-src`); not included |
| Dependencies | Ubuntu 24.04 packages; the installer's `--deps` installs them |

> Sensor data/firmware, fingerprint TA, GNSS flash images and camera calibration dumps are **not**
> included; extract them from your own device / official distributions —
> see [`docs/DEVICE-DATA-EXTRACTION.md`](docs/DEVICE-DATA-EXTRACTION.md).

---

## Measured results (2026-11-21, same device)

One elish unit (CSOT), Armbian noble + `6.18.44-current-sm8250` **release build #13** (no debug options),
clean boot; sleep tests include 10-hour-class sleeps.

### Boot / sensors / resume

| Metric | Measured |
|---|---|
| Desktop ready (systemd `Startup finished`) | **21.42 s** (kernel 3.16 s + userspace 18.26 s; `graphical.target` at 17.96 s) |
| Boot → sensors usable | **20.92 s** (`hexrpc-boot.log [start] up=20.92 sensors OK`) |
| PD registry initialisation (SLPI start → sensors OK) | **8.2 s** (~36–42 s before the M2 writable registry) |
| iio state | active, single instance, **NRestarts=0** |
| Lid close → resume → sensors re-claimed | **3.3 s** (first) / **6.0 s** (worker starts iio if it is not running); s2idle |
| Auto-rotate after resume | works (tested) |
| s2idle sleep death | **Fixed** (0009): **20 s2idle cycles** from 11-19 to 11-21 (incl. 10 h 47 m, 5 h 50 m, 5 h 43 m, 3 h 33 m sleeps) with **zero** PDM/fatal/crash-detected events; release #13: 4 cycles the same day, 0 crashes (`suspend_stats` success=4 fail=0) |
| Sensor self-check | **14 OK / 0 FAIL**; zero PDM crashes |

### Fingerprint (full verification 2026-11-13; re-checked 2026-11-21)

| Metric | Measured |
|---|---|
| `fprintd-list` | Goodix QSEE match-on-chip, template already enrolled |
| Enroll / verify | ✅ (`fprintd-enroll` / `fprintd-verify`) |
| GDM lock / login | ✅ (`enable-fingerprint-authentication=true`) |
| sudo fingerprint | ✅ (`pam_fprintd` 8 s timeout → password fallback; legacy optional `--pam` stack) |
| TA-refusal recovery | ✅ `fp-ta-watchdog` reloads the loader automatically |
| Fingerprint self-check | **OK=19 / WARN=1 / FAIL=0** (WARN: legacy optional `--pam` sudo stack not enabled) |

### GNSS (outdoor verification 2026-11-13)

| Metric | Measured |
|---|---|
| Path | `/dev/ttyHS1` (921600) → `airoha_gps.ko` → `airoha-gnssd` → `/dev/ttyGNSS0` → gpsd |
| NMEA | 1 Hz, 3939+ sentences forwarded; `gpsd` TPV normal (`mode=1` indoors is expected) |
| Outdoor fix | **mode=3, 12 sats, GGA quality=1** (fix within 2 minutes) |
| GeoClue2 | `gps-nmea-share` → `/run/gps-share.sock`; GeoClue location works |
| Compass | `CompassHeading` measured ≈176–177°; GeoClue heading works |
| Map apps | GNOME Maps (location); Pure Maps 3.5.1 (location + compass) validated |

### Camera (measured 2026-11-12; pipeline unchanged)

| Metric | Measured |
|---|---|
| Front | 3280×2464 PNG; HEVC 20 Mbps recording **30.05 fps** |
| Rear | 3120×4208 PNG; HEVC 20 Mbps recording **29.96 fps** |
| GPU debayer | front 11.0–12.1 ms/frame; rear 18.7–19.8 ms/frame (p95 ≤14.7 / ≤22.1) |
| Venus encode throughput (uncapped) | 3280×2464 HEVC **135 fps**; 4208×3120 HEVC **90.6 fps** |
| Virtual cameras | `/dev/video2` (front, NV12 3280×2464), `/dev/video20` (rear, NV12 3120×4208) |
| PipeWire / portal | two `media.role=Camera` nodes; portal `OpenPipeWireRemote` + Snapshot validated |
| Rear software AF | best in-room focus=640 (0–1023) |
| LSC tuning | rear vignetting 4.4× → ~1× (after on-device extraction; data not shipped) |
| Hi556 depth | RAW10 2592×1944 SGRBG10 @ ~30 fps, checker test pattern passed (2026-11-20) |
| Camera self-check | **OK=23 / WARN=0 / FAIL=0** |

### Flash / torch (2026-11-20)

| Metric | Measured |
|---|---|
| Rear flash blink during boot logo | ✅ Fixed: LED state restore no longer writes `white:flash` (LED events **2 → 0**) |
| Torch | ✅ `torch` CLI (logind `SetBrightness`, works as a normal user); optional GNOME 46 Quick Settings toggle (ACTIVE in headless Shell test; needs logout/login) |
| Photo flash (`flash_strobe`) | 🚫 no software support (`CONFIG_V4L2_FLASH_LED_CLASS` not enabled; needs kernel/camera backend work) |

### Charging / fast charge (2026-11-21)

| Metric | Measured |
|---|---|
| Charger | USB-C PD 3.0 + PPS (`port0/power_operation_mode=usb_power_delivery`, TCPM contract 9 V / 3 A) |
| Before the fix | 1.36 A at the battery ≈ **5.4 W** (PMIC default FCC 1.5 A, never programmed by the driver) |
| After the fix (`0010`) | **3.7–3.8 A ≈ 15 W** at the battery at low SoC (55–66 %), VBUS 8.73–8.75 V, AICL 3.3 A, temp ≤40 °C |
| Step charging (`0011–0013`) | 6 A below 70 %, 4 A 70–80 %, 2.5 A 80–88 %, 1.5 A 88–93 %, 1 A 93–97 %, 0.5 A ≥97 %; **premature Full fixed** (keeps charging at 89–92 % instead of stopping at 83 %) |
| 5 V mode | keeps the conservative 1.5 A; restored on unplug |
| bq2597x dual pumps (`0014–0015`) | probe/notifier fix makes master/slave **present=1** and they charge in parallel at 9 V; battery **~18–20 W** at low SoC; pumps are disabled when SoC ≥96 % to avoid overcharge |
| PPS keep-alive (`pps-charger/`, optional) | PPS APDO added to the sink caps (DTB `d7840b30…`); the local charger has a **~13 s PPS watchdog** and sends a hard reset unless the request is refreshed, so the service re-sends it every **8 s** (11 V held 2 min without a reset); ~20.5 W at the battery at 50–56 % (fixed 9 V ≈ 18.9 W, +8 %), short test 11 V/4 A reached 23.5 W+; reverts to 9 V at ≥41.5 °C |
| Remaining | 66 W would need the vendor 11 V/6 A proprietary handshake + pump coordination; JEITA current limiting (`docs/TODO.md` §1) |

### Combined self-check (`install/check-all.sh`, 2026-11-21)

| Item | Result |
|---|---|
| Combined DTB (sensor vmids + fingerprint + GNSS + camera nodes) | ✅ pass |
| Sensor stack | **14 OK / 0 FAIL** |
| Fingerprint stack | 19 OK / 1 WARN / 0 FAIL (WARN = optional legacy `--pam` stack not enabled) |
| GNSS stack | normal (polkit rule can only WARN when not run as root) |
| initramfs firmware invariant | ✅ no SLPI firmware |
| Camera stack | 23 OK / 0 FAIL |
| Flash boot-blink fix | ✅ pass (`flash-led/verify.sh`) |
| Pogo keyboard wake reset | ✅ pass (`pogo/verify.sh`; hook skips when keyboard absent) |
| GNOME torch (optional) | SKIP when not installed, ✅ when installed |
| apt state | `linux-image/dtb/headers-current-sm8250`, `armbian-firmware-full`, `libfprint-2-2` are held |

> Run `sudo ./install/check-all.sh` for the complete self-check (root can read more system files).

---

## Package layout

```
README.md / README.en.md / QUICKSTART.md / INSTALL.md / NOTES.md / PATCHES.md / VERSIONS.md / MANIFEST.md
LICENSE / SHA256SUMS / install.sh (one-click entry = wrapper around install/turnkey.sh)
kernel/        unified kernel: driver sources/patches, kernel config, initramfs hook, model-level
               combined DTB (with Hi556), one-shot build/install script, Linux boot-slot rebuild script
sensors/       sensor sub-package: systemd/udev/D-Bus integration, boot/resume scripts,
               hexrpc/libssc/iio patches and build notes, data-extraction scripts, docs
fingerprint/   fingerprint sub-package: qsee-supplicant/libfprint sources and patches,
               udev/systemd/PAM config, TA extraction, install/verify/uninstall scripts, docs
bioauth/       optional generic PAM biometric stack (PAM module + daemon + GTK4 fullscreen helper);
               not installed by default
gnss/          GNSS sub-package: airoha_gps driver source, airoha-gnssd/gps-nmea-share userspace,
               systemd/gpsd/GeoClue integration, protocol and troubleshooting docs, flash-repair notes
camera/        camera sub-package: elish-camera GPU pipeline (full-res front/rear, GPU debayer,
               Venus encode, virtual cameras, autoserve, autofocus), helper scripts,
               udev/autostart/resume integration, install.sh + verify.sh
flash-led/     rear flash boot-blink fix (default component): Armbian LED state restore guard
pogo/          default component: pogo keyboard wake reset (sleep hook + keyboard reset GPIO pulse)
torch/         optional GNOME 46 Quick Settings torch toggle + torch CLI (not installed by default)
tablet-mode/   optional tablet-mode switch (on/off/auto) + GNOME 46 Quick Settings toggle
               (not installed by default; uinput helper + systemd service for devices without cover)
pps-charger/   optional controlled 11 V PPS fast-charge service (8 s keep-alive + thermal
               bands; enabled by default once installed)
install/       installer: one-click turnkey.sh, extract-all.sh, build-userspace.sh,
               backup-boot.sh, check-all.sh, file placement map
docs/          authoritative hardware baseline, TODO, history, upgrade impact/risk,
               device-data extraction guide, hardening notes
```

---

## Installation

> Detailed steps: [`QUICKSTART.md`](QUICKSTART.md) (one-click) and [`INSTALL.md`](INSTALL.md) (manual).
> All install scripts support `--help` and `--dry-run`; installed components are skipped (`--force` rebuilds).

### 0. Prerequisites

- Xiaomi Pad 5 Pro (elish, CSOT) with Armbian noble already flashed;
- root (sudo; if you removed passwordless sudo via hardening, authorize with **fingerprint or password**);
- two device files (not shipped):
  - Android vendor partition image (e.g. `vendor_a.img`, read-only dump)
  - pMOS SLPI firmware package `firmware-xiaomi-elish-slpi-*.apk`
- fingerprint TA (optional; reused if `/lib/firmware/gfenu.*` already exists);
- network (userspace components `git clone` upstream sources; the kernel needs a matching source tree).

### 1. One-click full install (recommended)

```bash
# preview → install → optional kernel/DTB → reboot and verify
./install.sh --dry-run --android /path/vendor_a.img --pmos /path/firmware-xiaomi-elish-slpi-*.apk
sudo ./install.sh --android /path/vendor_a.img --pmos /path/firmware-xiaomi-elish-slpi-*.apk --yes
```

- **Kernel/DTB is a hard dependency**: sensor/fastrpc/fingerprint/GNSS/camera drivers all need the
  patched kernel + combined DTB. `--with-kernel` is an explicit opt-in because it writes the Linux
  boot slot and needs a matching kernel source tree — for a fresh system it is **not** optional
  (the installer pre-checks DTB/modules and warns when skipped).
- **Combined DTB (with Hi556)**: `--with-dtb --write-boot` installs only the DTB and rebuilds the Linux
  slot; `--with-kernel` installs it as part of the kernel step.
- **Camera LSC/CCM**: the `--android` stage also extracts `com.qti.tuned.*.bin` and generates
  `src/tuning_data.h` locally at build time (data not shipped/committed); neutral LSC/CCM is used when absent.

### 2. Per-component install

| Component | Command |
|---|---|
| Kernel / DTB (required first time) | `sudo ./kernel/build-and-install.sh --kernel-src <src> --write-boot`; DTB only: `sudo ./kernel/install-dtb.sh [--write-boot]` |
| Sensors | `sudo ./sensors/install/install-system-files.sh` (+ `install-data.sh` after extraction) |
| Fingerprint | `sudo ./install/build-userspace.sh --skip-hexrpc --skip-libssc --skip-iio` + `sudo ./fingerprint/install/install-fingerprint-files.sh` |
| GNSS | `sudo ./gnss/install/install.sh` (`airoha_gps.ko` is built by the kernel step) |
| Camera | `sudo ./camera/install.sh` + `bash ./camera/elish-camera/verify.sh` |
| Flash fix (default) | `sudo ./flash-led/install.sh` (turnkey installs it automatically) |
| Pogo keyboard wake reset (default) | `sudo ./pogo/install.sh` (turnkey installs it automatically; `--no-pogo` skips) |
| GNOME torch (optional) | `sudo ./torch/install.sh` (logout/login afterwards) |
| Tablet-mode switch (optional) | `sudo ./tablet-mode/install.sh` (on/off/auto; logout/login afterwards) |
| PPS fast-charge service (optional, enabled) | `sudo ./pps-charger/install.sh` (turnkey: `--with-pps-charger`) |
| bioauth (optional, not default) | `sudo ./install.sh --no-deps --skip-extract --skip-build --with-bioauth --yes` (sudo/pkexec wiring: `bioauth/INSTALL.md`) |
| Hardening (optional, recommended) | disable GDM autologin, remove passwordless sudo, keep fingerprint authorization: `docs/HARDENING.md` |

Manual details: `sensors/INSTALL.md`, `fingerprint/INSTALL.md`, `gnss/INSTALL.md`, `camera/README.md`,
kernel `kernel/README.md`.

### 3. Data / firmware extraction (not shipped)

```bash
sudo ./install/extract-all.sh --android <vendor.img> --pmos <slpi.apk> [--fingerprint-adb] [--out DIR]
```
It extracts and verifies automatically (registry=155 / config=40 / proto=79 / slpi.mbn md5). Full list and
manual methods: [`docs/DEVICE-DATA-EXTRACTION.md`](docs/DEVICE-DATA-EXTRACTION.md).

---

## Building

- The **one-click installer** clones upstream sources, applies this package's patches and builds/installs
  (sources cached in `/var/tmp/elish-build`);
- Manual build steps:
  - kernel: `kernel/README.md` (steps A/B, config checks, BTF/ABI triplet)
  - hexrpc: `sensors/userspace/hexrpc/README.md` (v0.3.2 + this package's patches)
  - libssc / iio: `sensors/userspace/*/README.md`
  - fingerprint: `fingerprint/INSTALL.md` (qsee-supplicant, libfprint goodix-qsee)
  - camera: `camera/elish-camera/Makefile` (`make -C camera/elish-camera`)
- Validated source versions/commits and installed sha256 references: root `VERSIONS.md`
  (sub-package READMEs list their own component versions).

---

## Verification

```bash
sudo ./install/check-all.sh         # combined self-check (DTB/sensors/fingerprint/GNSS/camera/flash/initramfs/apt)
sensor-status                       # sensor overview (services/firmware path/PDM/iio/values)
bash camera/elish-camera/verify.sh  # camera stack
./kernel/compat-check.sh --src <new kernel tree>   # read-only pre-upgrade patch/copy compatibility dry-run
sudo ./fingerprint/install/verify-fingerprint.sh "$USER"
sudo ./gnss/install/verify.sh
sudo ./flash-led/verify.sh          # boot-flash fix
sudo ./pogo/verify.sh               # default: pogo keyboard wake reset
sudo ./torch/verify.sh              # optional torch (SKIP when not installed)
sudo ./tablet-mode/verify.sh        # optional tablet-mode switch (SKIP when not installed)
sudo ./pps-charger/verify.sh         # optional PPS fast-charge service (SKIP when not installed)
sudo ./kernel/dtb/verify-combined-dtb.sh
```

---

## Known limitations

- Sensor PD occasionally hangs silently (**~1/14** clean boots): firmware-side issue, a clean reboot
  recovers, not fixable from this package;
- Raw gyroscope / magnetometer axes / proximity not exposed (libssc/udev layer gap);
- Camera: Hi556 has no depth/colour userland; front+rear cannot stream simultaneously; front camera has
  fixed focus; Flatpak/COSMIC portal backend limitations;
- Pogo keyboard may HID-hang after resume; the default `pogo/` component pulses the keyboard reset
  GPIO 3 s after each wake (re-enumeration ~1–1.5 s; keys typed within 3 s may be lost). **Do not** use
  `authorized`/`USBDEVFS_RESET`/controller rebind;
- Fingerprint TA must be extracted from your own device; `libfprint-2-2` upgrades overwrite the
  self-built library (hold it); kernel/firmware upgrades require redoing the steps in
  `docs/UPGRADE-IMPACT-ALL.md`;
- sudo fingerprint PAM is security-sensitive (legacy optional `--pam` stack): make sure password fallback
  works before enabling;
- The GNOME torch extension needs logout/login (GNOME 46 cannot hot-load new extensions);
- Photo flash (`flash_strobe`) is unsupported: `CONFIG_V4L2_FLASH_LED_CLASS` is not enabled and the camera
  software has no flash control;
- Charging: 5 V baseline + PD 9 V fast charge + bq2597x dual pumps (~18–20 W at low SoC); optional `pps-charger/` 11 V keep-alive reaches ~20.5 W (exits at 88 %/premature Full for trickle to 100 %); 66 W still needs the vendor proprietary protocol (`docs/TODO.md` §1);
- Firefox on native Wayland **loses touch input after long sleep** — an upstream Firefox bug
  (mozilla 2032822 / 2026258), unrelated to this driver package.

---

## Credits / upstream

This package is the result of wide upstream integration plus significant reverse-engineering,
porting and validation work. Thanks to:

### Upstream projects

| Project | Use | License |
|---|---|---|
| [Linux kernel](https://git.kernel.org/) / [mainline](https://github.com/torvalds/linux) | kernel base and driver frameworks | GPL-2.0 |
| [Armbian build](https://github.com/armbian/build) / armbian-firmware | sm8250 baseline, config, sensor firmware data | GPL-2.0 / various |
| [linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) | SLPI/SSC FastRPC file service (hexagonrpcd 0.3.2) | GPL-2.0 |
| [mmcallister/libssc](https://codeberg.org/mmcallister/libssc) | SSC sensor discovery/communication library (0.4.4) | LGPL-2.1 |
| [hadess/iio-sensor-proxy](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy) | IIO→D-Bus SensorProxy | GPL-2.0-or-later |
| [wrobelda/libfprint](https://github.com/wrobelda/libfprint) (goodix-qsee) | Goodix QSEE fingerprint driver | LGPL-2.1 |
| [wrobelda/qsee-supplicant](https://github.com/wrobelda/qsee-supplicant) | QSEE supplicant / app-loader | GPL-2.0 |
| [postmarketOS](https://gitlab.com/postmarketOS) (device-xiaomi-elish / firmware packages) | SLPI single-file firmware source | various |
| PipeWire / WirePlumber | camera/audio media pipeline | MIT / MIT |
| [v4l2loopback](https://github.com/v4l2loopback/v4l2loopback) | virtual cameras | GPL-2.0 |
| Mesa / EGL / GLES / libdrm / GBM | GPU debayer rendering | MIT / various |
| GeoClue / gpsd / Pure Maps | location stack and map apps | LGPL / BSD / GPL |
| quectel-open-source/GNSSTool and other GNSS references | AG3335 protocol reference | various |
| Community hexrpc writable-registry patches (suckbluefrog / gennro / Armada OS packaging) | M2 writable sensor registry | with upstream patches |

### People / AI contributions

- **caitming** — project lead, device experiments, kernel/driver integration, testing and maintenance;
- **DeepSeek Harness AI Agent (deepseek-flash)** — read-only reverse-engineering analyses, sensor boot
  acceleration L2/M1/M2 and resume recovery, hexrpc writable-registry patch adaptation, root-causing the
  s2idle sleep death and the fastrpc `PF_NOFREEZE` fix, camera/fingerprint/GNSS integration validation,
  installer and documentation (including this README).

---

## License (MIT)

Original parts of this package (installer, system configuration, scripts, documentation) are released
under the **MIT License**, see [`LICENSE`](LICENSE).

> Upstream code/patches (kernel and driver patches, hexagonrpc, libssc, iio-sensor-proxy, libfprint,
> qsee-supplicant, PipeWire, v4l2loopback, etc.) keep their own licenses (mostly GPL-2.0 / LGPL-2.1 /
> MIT); refer to each upstream repository. Redistribution/modification must comply with those licenses.

---

## Maintenance

- Hardware baseline: `docs/HARDWARE-STATUS.md` (authoritative)
- TODO / known issues: `docs/TODO.md`; development/deployment history: `docs/HISTORY.md`
- Upgrade impact: `docs/UPGRADE-IMPACT-ALL.md`; kernel upgrade risk and checklist: `docs/KERNEL-UPGRADE-RISK.md`
- Rollback/rescue: `kernel/README.md` and the automatic backups taken by the install scripts (the Linux
  boot slot and key configs are backed up before kernel/system changes)
