# How it works

Notes from reverse-engineering KANALI 2.6.0 (2026-10-08), for anyone extending this to other
models or newer versions.

## KANALI's pieces

KANALI is an Electron app (`KANALI.exe`) with helper programs in `resources/Connect/`:

| Component | Language | Role |
|---|---|---|
| `KANALI.exe` | Electron/Node | UI. Talks to the helpers over named pipes |
| `tm/UDB.exe` | native C++ | **Device middleware** for screen coolers. Named pipe `\\.\pipe\TryxBridge`. Protobuf "Tryx.USBProtocol" over USB |
| `Screen.exe` | .NET Framework 4.6 | Hardware monitoring (LibreHardwareMonitor + WMI) and ROTA fans over HID. Pipe `\\.\pipe\TryxScreenPipe` |
| `adb/`, `fastboot.exe`, `rkDriver/` | | Used for the Android → Linux firmware migration (PanoRK) |

`Screen.exe` needs .NET Framework 4.x in the prefix (`winetricks dotnet48`); without it the
UI starts but nothing that depends on the helper works.

## How UDB.exe finds devices

`UDB.exe` enumerates three Windows device-interface classes with SetupAPI:

| GUID | Kind | Used for |
|---|---|---|
| `GUID_DEVINTERFACE_USB_DEVICE` `{a5dcbf10-6530-11d2-901f-00c04fb951ed}` | 0 | **New Tryx firmware** (vendor `391a`): opened with `CreateFile`, then `ReadFile`/`WriteFile` (on Windows the device is bound to the USB printer driver) |
| `GUID_DEVINTERFACE_HID` | 1 | HID-based Tryx devices |
| `GUID_DEVINTERFACE_COMPORT` `{86e0d1e0-8089-11d0-9ce4-08003e301f73}` | 2 | Old Android firmware's CDC-ACM serial port |

It parses `vid_XXXX&pid_XXXX` out of the interface path and keeps devices whose PID is in its
supported list (logged at startup as `XXXX Supported.`: 1001, 1011, 1021, 1031, 1041, 1051,
1061, 1071, 1081, 1091, 10A1, 10B1, 10C1, 10D1, 10E1, 1101, 1111, 1121, 2011, 2021, 2031,
3011, 3021, 3031, 4011, 4021, 0256, 2D03, 2D04, 2D05).

Wine doesn't expose real USB devices through those interfaces, so `UDB.exe` finds nothing.

## The shim

On Linux the new-firmware cooler is a single **USB printer-class** interface (class 07/01/02),
bound to the kernel's `usblp` driver → `/dev/usb/lpN`, a plain bidirectional byte stream over the
bulk endpoints. That is exactly what `UDB.exe` reads and writes. So:

1. **udev** gives the logged-in user access and a stable name: `/dev/tryx-<pid>`
   (e.g. `/dev/tryx-1011`).
2. **Wine registry**: a device-interface entry under
   `HKLM\System\CurrentControlSet\Control\DeviceClasses\{a5dcbf10-…}` with
   `SymbolicLink = \\?\usb#vid_391a&pid_1011#tryxkanali#{a5dcbf10-…}`, a matching
   `Enum\USB\VID_391A&PID_1011\TRYXKANALI` device, and `#\Control\Linked = 1` so
   `SetupDiGetClassDevs(..., DIGCF_PRESENT)` returns it.
3. **Wine dosdevices symlink**: Wine resolves an unknown `\\?\name` path to
   `$WINEPREFIX/dosdevices/<name>`, so
   `dosdevices/usb#vid_391a&pid_1011#tryxkanali#{a5dcbf10-…}` → `/dev/tryx-1011`
   makes `CreateFile` on the interface path open the Linux device.

Result in `udb_*.log`:
```
[Hotplug] ONLINE reason=initial_enumeration vid=0x391A pid=0x1011 mi=255 kind=0 path=\\?\usb#vid_391a&pid_1011#tryxkanali#{…}
WinUsbDevice.Open: success
[Auth] DeviceInfo ready: sn=… 
```

`tryx-kanali run` re-runs the registration for any newly seen product ID before starting KANALI.

### Old Android firmware (for reference)

The old firmware (`18d1:2d03`, Rockchip "cm01", Android 11) exposes CDC-ACM serial + ADB. The
same trick works through `GUID_DEVINTERFACE_COMPORT` → `/dev/ttyACM*`, and `UDB.exe` gets the
device online. But the KANALI UI routes PIDs 2D03/2D04/2D05 to the **PanoRK firmware-migration**
flow only (`CMD_Ntf_DevOnline` → `panoRK:deviceOnline`) and never adds them to the managed
device list. So there's no screen management on that firmware, whatever you do on the Linux side.
This project therefore doesn't install the serial shim. Update the firmware instead.

## Known limitations

- **Temperatures:** `Screen.exe` → LibreHardwareMonitor needs a kernel driver (PawnIO/WinRing0).
  Not possible under Wine. A Linux-side sensor bridge (hwmon → KANALI) would be a possible future project.
- **TRYX cloud API:** requests from KANALI under Wine time out (`数据请求超时`, "request timed out"), although the
  API is reachable from Linux. Not investigated yet.
