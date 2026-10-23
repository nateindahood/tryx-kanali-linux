# Updating the cooler's firmware from Linux with a Windows VM

Needed if your cooler is still on the **old Android firmware** (`lsusb` shows
`18d1:2d03 ... Android Open Accessory`, product `cm01`). Current KANALI only offers screen
management after a one-time migration to TRYX's new Linux-based firmware, and that flash has to run
on Windows. If you have a Windows PC available, just use that. Otherwise, use a VM as below.

> **Risk:** this flashes firmware. The steps below are what worked after two failed attempts.
> Both failures were recoverable (see [Recovery](#recovery-cooler-stuck-or-gone-from-usb)),
> but follow the guide exactly anyway.

## Why a naive VM setup fails

During the update the cooler **reboots into Rockchip loader mode** (`2207:350a`, "USB
download gadget"), gets flashed, then reboots again with **new USB IDs** (`391a:xxxx`). The loader
mode is fragile:

| Pitfall | What happens | Fix (the script does all of these) |
|---|---|---|
| Passing the device through **by vendor/product ID** (the default in virt-manager / VirtualBox) | The VM loses the cooler the moment it reboots into loader mode | Pass through **by physical USB port** |
| QEMU puts the device behind an **emulated 12 Mb/s USB hub** (happens when the default xHCI controller's 4 ports are taken by the tablet + SPICE redirect slots) | High-speed loader transfers fail, Windows resets the device, KANALI reports *update failed* | xHCI with 15 ports, no SPICE redirect slots → cooler gets a direct 480 Mb/s port |
| **USB resets** forwarded from Windows to the real device | Loader stops responding (`device not accepting address, error -71`) | `guest-reset=false` on the passed-through device |
| **Shutting down the VM** while the cooler is in loader mode | QEMU releases/resets the device → loader dies | Never stop the VM until the update finishes |

## Requirements

- CPU virtualization enabled (AMD SVM / Intel VT-x). Check that `/dev/kvm` exists.
- QEMU ≥ 6.1, libvirt, virt-manager, OVMF (UEFI) and swtpm (virtual TPM):
  - Ubuntu / Pop!_OS / Debian: `sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system virt-manager ovmf swtpm-tools`
  - Fedora: `sudo dnf install @virtualization swtpm-tools`
  - Arch: `sudo pacman -S qemu-full libvirt virt-manager edk2-ovmf swtpm`
- Add yourself to the `libvirt` and `kvm` groups, then **log out and back in**:
  `sudo usermod -aG libvirt,kvm $USER`
- The udev rule from this project (`./tryx-kanali install ...` installs it). It gives your user
  access to the cooler in **every** mode (old firmware, loader, new firmware) so the VM can take it.
- A **Windows 11 ISO** from Microsoft ("Download Windows 11 Disk Image (ISO) for x64 devices").
  No product key is needed for this.
- ~70 GB free disk space (the VM disk grows as Windows uses space), 8 GB RAM for the VM.

## Steps

1. **Quit KANALI** on Linux (tray icon → quit) so nothing on the host holds the cooler.

2. **Create and start the VM** (it runs as your user, not as a system service):
   ```bash
   scripts/create-flash-vm.sh ~/Downloads/Win11_*.iso
   ```
   The script finds the cooler's USB port, builds the VM with the fixes above, starts it and
   opens its window. While the VM runs, the cooler belongs to the VM and its screen may go dark.

3. **Boot the installer:** click into the VM window and **press a key** at
   *"Press any key to boot from CD or DVD"*. If you miss it you land in a grey UEFI menu;
   reset the VM (virt-manager: *Force Reset*) and try again.

4. **Install Windows 11:** *"I don't have a product key"* → Home or Pro → *Custom install*
   on the empty disk. For a local account on the Microsoft-account screen: **Shift+F10**,
   type `start ms-cxh:localonly`, Enter.

5. **Eject the ISO** after the install, otherwise the VM boots the installer again and
   complains that *"you started an upgrade and booted from installation media"*:
   ```bash
   virsh -c qemu:///session change-media tryx-flash sdb --eject --live --config
   ```
   If that dialog already appeared, eject, then click **Yes**.

6. **In Windows:** download KANALI from tryx.com, install it, open it. It shows a
   *New Firmware Version* prompt. Click **Update Now**. Allow any Rockchip driver prompt.

7. **Wait.** The cooler disconnects, reappears as `2207:350a` (loader), and after a minute or two
   reappears as `391a:xxxx`. KANALI reports success and the screen manager appears.
   **Do not shut down, pause or reset the VM during this.**

8. **Shut down Windows** (Start → Shut down). The cooler returns to Linux. Run
   `tryx-kanali doctor`: it should now show `391a:xxxx - new Tryx firmware`.

9. **Delete the VM** if you don't need it again:
   ```bash
   virsh -c qemu:///session undefine tryx-flash --nvram --tpm --remove-all-storage
   ```

You can follow the cooler's USB activity from Linux during the update with
`journalctl -kf | grep -i usb`.

## Recovery: cooler stuck or gone from USB

Symptoms: the cooler screen is dark, `lsusb` doesn't show it (or shows `2207:350a` forever), and
the kernel log has `device descriptor read/64, error -71` / `device not accepting address`.

1. If the VM is running and the update is clearly dead, shut the VM down.
2. **Shut the PC down completely and switch off the PSU (or unplug it) for ~15 seconds.**
   A reboot is not enough: the motherboard keeps powering the USB header.
3. Power on. In both failures we hit, the cooler came back on its **previous firmware**:
   the failure happened before anything was written. Fix the cause (use the script) and retry.

If the cooler stays in loader mode (`2207:350a`) even after a power cycle, the flash was
interrupted while writing. The loader is still there to flash again, so retry the update in the VM.
