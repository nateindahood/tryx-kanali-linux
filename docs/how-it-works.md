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

## The temperature bridge

`Screen.exe` gets all CPU/GPU readings from `LibreHardwareMonitorLib.dll` (LibreHardwareMonitor),
which reads hardware registers through the PawnIO kernel driver. Under Wine `Computer.Open()`
fails (`NullReferenceException`), KANALI logs *"LibreHardwareMonitor 初始化已降级"* ("initialization
degraded") and falls back to WMI, which only gives RAM figures. It also tries to run the PawnIO
driver installer on every start.

The library isn't strong-name signed, so a replacement with the same assembly name loads fine.
`sensor-bridge/LibreHardwareMonitorShim` implements exactly the surface `Screen.exe` uses (found by
listing its IL member references):

- `Computer` (`Is*Enabled` setters, `Open`, `Close`, `Hardware` → `IList<IHardware>`)
- `IHardware` (`HardwareType`, `Name`, `Sensors` → `ISensor[]`, `Update`)
- `ISensor` (`Name`, `SensorType`, `Value` → `float?`)
- `HardwareType` / `SensorType` enums with the **same member order** (values are compiled into `Screen.exe`)
- `PawnIo.Version` / `IsInstalled` (reports 2.2.0.0 so KANALI skips the driver installer)

Sensor names follow what `Screen.exe` matches on: `CPU Total` (load), `Core (Tctl/Tdie)`
(temperature, any `Core*`), `Cores (Average)` (clock), `Package` (power), `GPU Core`
(load/temperature/clock), `GPU Package` (power), `Upload Speed`/`Download Speed`.

Values come from `/dev/shm/tryx-sensors.txt` (`Z:\dev\shm\tryx-sensors.txt` inside Wine), written
by `sensor-bridge/tryx-sensord` once a second. Data older than 15 s is ignored. From there the
values follow KANALI's normal path: `Screen.exe` `dynamic` → UI → `CMD_Update_UIItemText` to the
cooler, sent every second while the screen layout contains system-info labels.

## The network fix

Every request from KANALI's main process (GIPHY downloads, `kanali2-api.tryxzone.com`: update
and firmware checks, material library, usage logs) failed after ~20 ms and was logged as
`{ type: 'canceled', respMsg: '数据请求超时' }`, KANALI's catch-all for "no response", even
though plain `https.get` from the same process works.

Attaching to the main process with `--inspect` (the `EnableNodeCliInspectArguments` fuse is on)
and calling KANALI's own `giphy:downloadMedia` IPC handler showed the real error:
`connect UNKNOWN 146.75.93.32:443`. The bundled axios 0.27 calls `socket.setKeepAlive(true, 60000)`
when the request gets its socket, i.e. *before* the TCP connect. On Windows libuv applies
`SO_KEEPALIVE`/`TCP_KEEPALIVE` at connect time, and under Wine 9 that makes `connect` fail.
Enabling keep-alive after the `connect` event works.

KANALI can't be given a `--require` (`NODE_OPTIONS` is limited in packaged Electron apps), and
Electron 25 checks `resources/app.asar` before a `resources/app/` folder. So we edit the one value
in `app.asar`'s `package.json`: `"main": "./out/main/index.js"` → `"main": "../tryxboot.js"`,
padded with spaces to the same byte length so nothing else in the archive moves (asar integrity
validation is off in this build). `tryxboot.js` patches `net.Socket.prototype.setKeepAlive` to defer
until connected, then `require`s the original entry point recorded in `tryxboot.json`.
`app.getAppPath()`, the app name/version and the settings folder are unchanged.

Separately, `console.log` in KANALI's main process throws `EBADF` under Wine when stdout is a
pipe, so `tryx-kanali run` sends KANALI's output to a log file.

## Known limitations

- **CPU package power:** RAPL energy counters are root-only on current kernels.
