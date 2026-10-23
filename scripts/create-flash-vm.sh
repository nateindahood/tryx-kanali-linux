#!/usr/bin/env bash
# create-flash-vm.sh - create a Windows 11 VM (libvirt *user session*) with the Tryx
# cooler passed through BY USB PORT, so KANALI's firmware update can run from Linux.
#
# Usage: scripts/create-flash-vm.sh [--dry-run] <Windows 11 ISO>
#
# Why it is built this way (each of these broke a real flash attempt):
#  * Port-based passthrough: during a flash the cooler reboots into Rockchip loader
#    mode (2207:350a) and comes back with new IDs. Passing it by vendor/product ID
#    would lose it mid-flash; passing the physical port follows it.
#  * guest-reset=false: the loader mode does not survive a USB reset. Windows' reset
#    requests are not forwarded to the real device.
#  * xHCI with 15 ports and no SPICE redirect slots: otherwise QEMU puts the cooler
#    behind an emulated 12 Mb/s hub and the high-speed loader transfers fail.
# See docs/firmware-update-windows-vm.md for the full walkthrough.

set -euo pipefail

NAME="${VM_NAME:-tryx-flash}"
VM_DIR="${VM_DIR:-$HOME/VMs}"
RAM_MB="${VM_RAM_MB:-8192}"
CPUS="${VM_CPUS:-4}"
DISK_GB="${VM_DISK_GB:-64}"
CONN="qemu:///session"

die() { echo "Error: $*" >&2; exit 1; }

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
ISO="${1:-}"
[ -n "$ISO" ] && [ -f "$ISO" ] || die "Usage: $0 [--dry-run] <Windows 11 ISO>"
ISO=$(readlink -f "$ISO")

for c in virt-install virsh qemu-system-x86_64 qemu-img python3; do
    command -v "$c" >/dev/null || die "'$c' not found. Install QEMU/libvirt (see docs/firmware-update-windows-vm.md)."
done
[ -e /dev/kvm ] || die "/dev/kvm missing - enable virtualization (AMD SVM / Intel VT-x) in the BIOS."
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "No access to /dev/kvm - add yourself to the 'kvm' group and log out/in."
qemu-system-x86_64 -device usb-host,help 2>/dev/null | grep -q guest-reset \
    || die "QEMU is too old (needs usb-host 'guest-reset', QEMU >= 6.1)."
ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/edk2/*/OVMF_CODE*.fd /usr/share/edk2-ovmf/*/OVMF_CODE*.fd >/dev/null 2>&1 \
    || echo "Warning: OVMF (UEFI firmware) not found in the usual places; virt-install may fail." >&2
command -v swtpm >/dev/null || die "'swtpm' not found (needed for the virtual TPM Windows 11 requires)."

# Find the cooler: new Tryx firmware (391a), Rockchip loader (2207), or old Android firmware (18d1 "cm01")
PORT=""
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    vid=$(<"$d/idVendor"); prod=$(cat "$d/product" 2>/dev/null || true)
    case "$vid" in
        391a|2207) PORT=${d##*/}; DEVDIR=$d ;;
        18d1) [ "$prod" = cm01 ] && { PORT=${d##*/}; DEVDIR=$d; } ;;
    esac
done
[ -n "$PORT" ] || die "No Tryx cooler found on USB (looked for 391a:*, 2207:*, 18d1:* 'cm01')."
HOSTBUS=${PORT%%-*}
HOSTPORT=${PORT#*-}
NODE=$(printf '/dev/bus/usb/%03d/%03d' "$(<"$DEVDIR/busnum")" "$(<"$DEVDIR/devnum")")
echo "Cooler found on USB bus $HOSTBUS, port $HOSTPORT ($NODE)"
[ -r "$NODE" ] && [ -w "$NODE" ] \
    || die "No access to $NODE. Install the udev rule first (./tryx-kanali install ...) and re-plug or reboot."

virsh -c "$CONN" dominfo "$NAME" >/dev/null 2>&1 && die "A VM named '$NAME' already exists (set VM_NAME=... or delete it)."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ "$DRY" = 1 ]; then
    DISK="$TMP/$NAME.qcow2"
else
    DISK="$VM_DIR/$NAME.qcow2"
    mkdir -p "$VM_DIR"
    [ -e "$DISK" ] && die "$DISK already exists."
fi
qemu-img create -q -f qcow2 "$DISK" "${DISK_GB}G"

virt-install --connect "$CONN" --name "$NAME" --osinfo win11 \
    --memory "$RAM_MB" --vcpus "$CPUS" --cpu host-passthrough \
    --boot uefi --tpm emulator,model=tpm-crb,version=2.0 \
    --disk path="$DISK",format=qcow2,bus=sata \
    --cdrom "$ISO" \
    --network user,model=e1000e --graphics spice --video qxl \
    --controller type=usb,model=qemu-xhci,alias.name=ua-xhci \
    --qemu-commandline='-device PLACEHOLDER' \
    --print-xml 1 >"$TMP/vm.xml" 2>"$TMP/err" || { cat "$TMP/err" >&2; die "virt-install failed"; }

python3 -I - "$TMP/vm.xml" "$HOSTBUS" "$HOSTPORT" <<'EOF'
import sys, re, json
path, bus, port = sys.argv[1], int(sys.argv[2]), sys.argv[3]
x = open(path).read()
dev = json.dumps({"driver": "usb-host", "bus": "ua-xhci.0", "hostbus": bus,
                  "hostport": port, "guest-reset": False, "id": "tryxcooler"}, separators=(",", ":"))
dev = dev.replace("&", "&amp;").replace('"', "&quot;")
assert x.count('value="PLACEHOLDER"') == 1, "placeholder not found"
x = x.replace('value="PLACEHOLDER"', 'value="%s"' % dev)
x = re.sub(r"<redirdev\b[^>]*spicevmc[^>]*/>\s*", "", x)
x = re.sub(r"<redirdev\b[^>]*spicevmc[^>]*>.*?</redirdev>\s*", "", x, flags=re.S)
x, n = re.subn(r"(<controller\b(?=[^>]*type=['\"]usb['\"])(?=[^>]*model=['\"]qemu-xhci['\"])[^>]*?)(/?>)", r"\1 ports='15'\2", x, count=1)
assert n == 1, "xhci controller not found"
x = x.replace("<on_reboot>destroy</on_reboot>", "<on_reboot>restart</on_reboot>")
open(path, "w").write(x)
EOF

if [ "$DRY" = 1 ]; then
    cat "$TMP/vm.xml"
    exit 0
fi

virsh -c "$CONN" define "$TMP/vm.xml" >/dev/null

# Nothing on the host may hold the cooler while the VM owns it
command -v adb >/dev/null && adb kill-server >/dev/null 2>&1 || true
pgrep -f 'KANALI\\KANALI\.exe' >/dev/null && die "Quit KANALI (Wine) first, then run: virsh -c $CONN start $NAME"

virsh -c "$CONN" start "$NAME" >/dev/null
echo "VM '$NAME' started. Opening its console..."
command -v virt-manager >/dev/null && setsid -f virt-manager -c "$CONN" --show-domain-console "$NAME" >/dev/null 2>&1 || \
    echo "Open it with: virt-manager -c $CONN   (or: virt-viewer -c $CONN $NAME)"

cat <<EOF

Next steps (details: docs/firmware-update-windows-vm.md):
  1. Click into the VM window and PRESS A KEY at "Press any key to boot from CD or DVD".
  2. Install Windows 11 ("I don't have a product key" is fine). After the install,
     eject the ISO so it doesn't boot the installer again:
       virsh -c $CONN change-media $NAME sdb --eject --config
  3. In Windows, install KANALI and click "Update Now" on the firmware prompt.
  4. Do NOT shut down or pause the VM while the update runs. When it is done,
     shut down Windows; the cooler returns to Linux.
  Delete the VM afterwards:
       virsh -c $CONN undefine $NAME --nvram --tpm --remove-all-storage
EOF
