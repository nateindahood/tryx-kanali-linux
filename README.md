# tryx-kanali-linux

Run **TRYX KANALI**, the Windows-only control software for TRYX AIO coolers with built-in
screens (e.g. the **Panorama 360** with its 6.5" AMOLED), on **Linux** with Wine, and let it
actually reach the cooler. You can then manage the screen and upload custom animations from Linux.

Out of the box, KANALI installs and opens under Wine but never finds the cooler, can't read
CPU/GPU temperatures, and all of its online features (GIPHY downloads, TRYX's online library,
update checks) fail. This project works out why and fixes all three with a single setup script.

> **Unofficial.** Not affiliated with or supported by TRYX. Use at your own risk, especially
> anything involving firmware updates.

---

## ⚠️ Read first

1. **Your cooler may need a one-time firmware update, done on Windows, first.** Early units
   shipped with an *Android-based* firmware. Current KANALI (2.x) does **not** offer screen
   management for those; it only offers to migrate the firmware, and that flash can't be done
   from Wine. Run `./tryx-kanali doctor` to see which firmware you have.
   ([FAQ](#kanali-opens-but-theres-no-screen--panorama-section),
   [how to update from Linux with a VM](docs/firmware-update-windows-vm.md))
2. **CPU/GPU temperatures come from Linux, not from KANALI's own sensor code.** KANALI's sensor
   library needs a Windows **kernel driver**, which Wine can't run. This project replaces that
   library with a small stand-in that feeds KANALI the readings Linux already has. CPU and GPU
   temperature, load and clock work. A few minor readouts (e.g. CPU package power) don't.
   ([FAQ](#do-cpugpu-temperatures-work))

---

## Quick start

```bash
git clone https://github.com/nateindahood/tryx-kanali-linux.git
cd tryx-kanali-linux
./tryx-kanali install ~/Downloads/KANALI_V2.6.0_20261008.zip   # .zip or .exe from tryx.com
```

The installer script:
1. installs a **udev rule** (asks for your sudo password),
2. creates a dedicated Wine prefix `~/.wine-kanali` and installs **.NET Framework 4.8** into it
   (downloads from Microsoft, **10-20 minutes**),
3. starts the **KANALI installer**. Click through it and keep the default location,
4. registers your cooler with Wine and adds a **"KANALI"** entry to your app menu,
5. sets up the **CPU/GPU temperature bridge** (keeps KANALI's original sensor library as a backup),
6. installs the **network fix** for KANALI's background process (GIPHY, online library, update checks).

Then start **KANALI** from the menu (or `tryx-kanali run`). If the installer already opened
KANALI, quit it from its tray icon and start it from the menu once, so the cooler gets registered.

Check everything with:

```bash
tryx-kanali doctor
```

### Requirements

| | |
|---|---|
| Wine | 9.0 or newer (64-bit), plus **winetricks** |
| Tools | `python3`, `iconv`, `od` (coreutils), `unzip` if you pass a .zip |
| GPU readings | NVIDIA: `nvidia-smi` (comes with the driver) · AMD: `amdgpu` driver |
| System | systemd/udev with `uaccess` (any mainstream desktop distro) |
| Cooler | TRYX cooler on the **new TRYX firmware** (USB vendor `391a`), see above |

Install the requirements:

- **Ubuntu / Pop!_OS / Mint / Debian:** `sudo apt install wine winetricks unzip`
- **Fedora:** `sudo dnf install wine winetricks unzip`
- **Arch / Manjaro:** `sudo pacman -S wine winetricks unzip` (enable `[multilib]`)

### Commands

| Command | What it does |
|---|---|
| `tryx-kanali install <installer>` | Full setup (safe to re-run) |
| `tryx-kanali run` | Start KANALI (what the menu entry runs; registers the cooler first) |
| `tryx-kanali register` | Register connected coolers with Wine again |
| `tryx-kanali doctor` | Check the setup and show which firmware/mode the cooler is in |
| `tryx-kanali sensors status\|on\|off` | Check, enable or disable the CPU/GPU temperature bridge |
| `tryx-kanali uninstall` | Remove the launcher and udev rule, optionally the Wine prefix |

Set `KANALI_PREFIX=/some/path` to use a different Wine prefix.

---

## What works

Tested with **TRYX Panorama 360 ARGB** (`PANO`, USB `391a:1011`, firmware **v2.0.4**),
**KANALI 2.6.0** (2026-10-08), **Wine 9.0**, **Pop!_OS 24.04**:

- ✅ KANALI detects the cooler and shows the screen manager
- ✅ Settings changes reach the cooler
- ✅ CPU temperature, load and clock; GPU temperature, load, clock and power
  (via the temperature bridge), shown in KANALI and on the cooler screen
- ❔ Custom animation / media upload: not verified on Linux yet. It uses the same USB
  channel, so it's expected to work. Reports welcome
- ❌ CPU package power, per-core voltages (not available without root on Linux)
- ✅ GIPHY downloads, TRYX online material library, app/firmware update checks (via the network fix)

Other TRYX screen models (Panorama SE / WB, HOLO, ...) use the same middleware and very
likely work the same way, but are **untested**. Reports welcome! Please include the output
of `tryx-kanali doctor`.

---

## FAQ

### Do CPU/GPU temperatures work?
Yes, through a workaround. KANALI's helper (`Screen.exe`) normally reads sensors with
**LibreHardwareMonitor**, which loads a Windows **kernel driver** (PawnIO) to read CPU/GPU
registers. Wine runs Windows programs, not Windows drivers, so that always fails under Wine
and KANALI only reports RAM usage.

This project replaces `LibreHardwareMonitorLib.dll` inside KANALI with a small stand-in
([source](sensor-bridge/LibreHardwareMonitorShim/LibreHardwareMonitorShim.cs)) that gives KANALI the
readings Linux already has. A tiny Linux service, `tryx-sensord`, collects them from
`k10temp`/`coretemp`, `nvidia-smi` or `amdgpu` about once a second. `tryx-kanali run` starts it
together with KANALI, and it stops by itself a minute after KANALI closes.

| Reading | Status |
|---|---|
| CPU temperature, load, clock | ✅ |
| GPU temperature, load, clock, power: NVIDIA | ✅ tested |
| GPU temperature, load, clock, power: AMD (`amdgpu`) | ⚠️ implemented, untested. Reports welcome |
| Network up/down speed | ✅ |
| CPU package power | ❌ needs root on Linux (RAPL) |
| Intel integrated-GPU readings | ❌ not implemented |

To show values on the cooler, add CPU/GPU items to the screen layout in KANALI and click
**Save** (see the next question). If something looks off: `tryx-kanali sensors status`. To go
back to KANALI's original library: `tryx-kanali sensors off`.

### I changed the text color (or another label setting) but the cooler doesn't change
Click the **Save** button in that settings panel. Picking a color only changes the preview;
nothing is sent to the cooler until you save. The label text can only be black or white
(KANALI's "white" is a light grey).

### KANALI opens but there's no screen / Panorama section
Your cooler is almost certainly on the **old Android firmware**. Check with
`tryx-kanali doctor`, or `lsusb`. On the old firmware the cooler shows up as:

```
ID 18d1:2d03 Google Inc. Android Open Accessory device (audio + ADB)   (product "cm01")
```

KANALI 2.x treats that ID as "PanoRK" and only offers a **firmware migration
(Android → Linux)**. It never shows the screen manager for it. After the migration the cooler
shows up as `391a:xxxx` (e.g. `391a:1011 PANO`) and works with this project.

### How do I do that firmware update if I only run Linux?
Any Windows PC works: install KANALI there, plug the cooler in, click **Update Now**.
Without one, use a **Windows 11 VM** on Linux with the cooler passed through. This works,
but has real pitfalls that can leave the cooler stuck mid-flash, so follow the guide exactly:
**[docs/firmware-update-windows-vm.md](docs/firmware-update-windows-vm.md)**. It includes a
script that builds the VM correctly.

### Can I run the firmware update from KANALI under Wine?
**No, don't.** The flash uses Rockchip's low-level USB loader protocol and Windows drivers
that Wine doesn't provide. If it starts and then fails, the cooler sits in flashing mode.

### My cooler's screen is dark / it disappeared from USB after a failed update
If `lsusb` shows `2207:350a Rockchip ... USB download gadget`, or the kernel log shows
`device not accepting address ... error -71`, the cooler is stuck in its loader. Nothing has
been written at that point, and it's recoverable:
**shut the PC down and switch the PSU off (or unplug it) for ~15 seconds.** A normal reboot
isn't enough, because the motherboard keeps USB powered. The cooler comes back on its previous firmware.

### GIPHY downloads failed / "request timed out" errors
That was a Wine bug, fixed by this project. KANALI's background process makes its web requests
with a library (axios) that switches on TCP keep-alive *before* connecting. Under Wine that makes
every connection fail instantly (`connect UNKNOWN`), and KANALI reported it as a timeout. The
fix is a small bootstrap (`resources/tryxboot.js`) that delays keep-alive until the connection is
up and then starts KANALI unchanged. To load it first, the one `"main"` line in
`resources/app.asar`'s `package.json` is pointed at it (a same-size edit; the original is kept in
`resources/tryxboot.json` and restored by `tryx-kanali uninstall`). `tryx-kanali run` re-applies
it after KANALI updates. Details: [docs/how-it-works.md](docs/how-it-works.md#the-network-fix).

You can also upload your own GIF/MP4/image: in the Panorama screen settings choose a
customization mode and add a local file.

### Do I need ADB? I read the cooler shows up in ADB.
No. On the old Android firmware the screen exposes ADB (it's an Android board), but KANALI
2.x doesn't use it: its ADB path is switched off in the build. On the new firmware there's no ADB at all.

### Why does KANALI under Wine normally not find the cooler?
KANALI's device middleware (`UDB.exe`) looks for the cooler through Windows' device manager
(SetupAPI): it lists USB devices, reads `vid_391a&pid_xxxx` out of the device path and opens
that path. Wine doesn't present real USB devices that way, so KANALI sees nothing. This
project registers the device with Wine's registry and points the device path at the Linux
device node, so KANALI's normal code path just works. Details: [docs/how-it-works.md](docs/how-it-works.md).

### There's a weird KANALI menu entry with a garbled name
The KANALI installer creates Wine menu entries. One has a Chinese name that shows up garbled,
and it runs the **uninstaller**. `tryx-kanali install` hides those and adds a clean "KANALI"
entry instead.

### Does KANALI start automatically at login?
Not on Linux. KANALI's "start with Windows" setting only applies inside Wine. To autostart:
`cp ~/.local/share/applications/tryx-kanali.desktop ~/.config/autostart/`

### How do I update KANALI itself?
Download the new installer and run it inside the same prefix, then start KANALI again:
```bash
WINEPREFIX=~/.wine-kanali wine ~/Downloads/KANALI_Vx.y.z.exe
```

### Which distros does this work on?
Anything with Wine ≥ 9, winetricks and systemd-udev. Developed on Pop!_OS 24.04. The setup
lives entirely in your home directory plus one udev rule, so it's easy to carry to a new
distro: clone the repo and run `install` again.

### Where are the logs?
`~/.local/share/tryx-kanali/kanali-wine.log` (Wine/console output) and
`~/.wine-kanali/drive_c/users/$USER/AppData/Roaming/kanali/logs/`:
- `udb_YYYY-MM-DD.log`: device middleware (USB traffic, device online/offline)
- `YYYY-MM-DD.log`: KANALI app
- `screen-YYYY-MM-DD.log`: hardware-monitor helper

---

## Troubleshooting

Run `tryx-kanali doctor` first. It covers most problems. Then:

| Symptom | Fix |
|---|---|
| `/dev/tryx-XXXX missing` | udev rule not applied yet: re-plug the cooler, reboot, or `sudo udevadm trigger` |
| `... exists but you lack read/write access` | Log out and back in (the `uaccess` tag applies to the active session) |
| `not registered with Wine` | `tryx-kanali register`, then restart KANALI |
| winetricks seems stuck installing .NET | Make sure KANALI isn't running; winetricks waits for every Wine program to exit |
| Cooler on old firmware | See the [firmware update guide](docs/firmware-update-windows-vm.md) |
| Interface class is not printer (07) | Your model works differently: please open an issue with `doctor` output |
| Temperatures show 0 | `tryx-kanali sensors status`; start KANALI via the menu / `tryx-kanali run` (that starts `tryx-sensord`) |

## Uninstall

```bash
tryx-kanali uninstall
```

## License

MIT, see [LICENSE](LICENSE). KANALI itself is proprietary TRYX software and is **not**
included. You download it from TRYX.
