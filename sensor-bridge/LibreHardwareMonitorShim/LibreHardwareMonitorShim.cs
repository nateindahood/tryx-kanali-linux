// Stand-in for LibreHardwareMonitorLib.dll, for TRYX KANALI running under Wine.
//
// The real library reads sensors through a Windows kernel driver, which Wine cannot
// load. This replacement implements only the API surface KANALI's Screen.exe uses
// (same namespaces, type names, enum values and member signatures) and serves the
// values that the Linux-side `tryx-sensord` writes to /dev/shm/tryx-sensors.txt,
// visible inside Wine as Z:\dev\shm\tryx-sensors.txt.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Threading;

namespace LibreHardwareMonitor.Hardware
{
    // Enum member order must match the real library: Screen.exe has the numbers compiled in.
    public enum HardwareType
    {
        Motherboard, SuperIO, Cpu, Memory, GpuNvidia, GpuAmd, GpuIntel, Storage, Network,
        Cooler, EmbeddedController, Psu, Battery, PowerMonitor
    }

    public enum SensorType
    {
        Voltage, Current, Power, Clock, Temperature, Load, Frequency, Fan, Flow, Control, Level,
        Factor, Data, SmallData, Throughput, TimeSpan, Timing, Energy, Noise, Conductivity, Humidity
    }

    public interface ISensor
    {
        string Name { get; set; }
        SensorType SensorType { get; }
        float? Value { get; }
    }

    public interface IHardware
    {
        HardwareType HardwareType { get; }
        string Name { get; set; }
        ISensor[] Sensors { get; }
        IHardware[] SubHardware { get; }
        void Update();
    }

    /// <summary>Latest snapshot of the key=value file written by tryx-sensord.</summary>
    internal static class LinuxSensors
    {
        const double StaleSeconds = 15;
        static readonly object Lock = new object();
        static Dictionary<string, string> _values = new Dictionary<string, string>();
        static DateTime _readAt = DateTime.MinValue;

        static string FilePath
        {
            get
            {
                string p = Environment.GetEnvironmentVariable("TRYX_SENSORS_WINPATH");
                return string.IsNullOrEmpty(p) ? @"Z:\dev\shm\tryx-sensors.txt" : p;
            }
        }

        public static void Refresh(bool force)
        {
            lock (Lock)
            {
                if (!force && (DateTime.UtcNow - _readAt).TotalMilliseconds < 500) return;
                _readAt = DateTime.UtcNow;
                var v = new Dictionary<string, string>();
                try
                {
                    foreach (string line in File.ReadAllLines(FilePath))
                    {
                        int i = line.IndexOf('=');
                        if (i > 0) v[line.Substring(0, i)] = line.Substring(i + 1);
                    }
                }
                catch (Exception) { /* file missing or mid-rename: keep empty */ }

                // Ignore data if tryx-sensord stopped updating it
                long ts;
                if (v.TryGetValue("ts", out string tsText) &&
                    long.TryParse(tsText, NumberStyles.Integer, CultureInfo.InvariantCulture, out ts))
                {
                    double age = (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds - ts;
                    if (age > StaleSeconds) v.Clear();
                }
                _values = v;
            }
        }

        public static bool HasData { get { Refresh(false); lock (Lock) return _values.Count > 0; } }

        public static string Text(string key)
        {
            Refresh(false);
            lock (Lock) return _values.TryGetValue(key, out string s) && s.Length > 0 ? s : null;
        }

        public static float? Number(string key)
        {
            string s = Text(key);
            float f;
            return s != null && float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out f) ? f : (float?)null;
        }
    }

    internal sealed class Sensor : ISensor
    {
        readonly string _key;
        readonly float _scale;

        public Sensor(string name, SensorType type, string key, float scale = 1f)
        {
            Name = name; SensorType = type; _key = key; _scale = scale;
        }

        public string Name { get; set; }
        public SensorType SensorType { get; private set; }

        public float? Value
        {
            get
            {
                float? v = LinuxSensors.Number(_key);
                return v.HasValue ? v.Value * _scale : (float?)null;
            }
        }
    }

    internal sealed class Hardware : IHardware
    {
        readonly string _nameKey;
        string _name;

        public Hardware(HardwareType type, string name, string nameKey, params ISensor[] sensors)
        {
            HardwareType = type; _name = name; _nameKey = nameKey; Sensors = sensors;
        }

        public HardwareType HardwareType { get; private set; }

        public string Name
        {
            get { return (_nameKey != null ? LinuxSensors.Text(_nameKey) : null) ?? _name; }
            set { _name = value; }
        }

        public ISensor[] Sensors { get; private set; }
        public IHardware[] SubHardware { get { return new IHardware[0]; } }
        public void Update() { LinuxSensors.Refresh(true); }
    }

    public class Computer
    {
        readonly List<IHardware> _hardware = new List<IHardware>();
        bool _open;

        public bool IsBatteryEnabled { get; set; }
        public bool IsControllerEnabled { get; set; }
        public bool IsCpuEnabled { get; set; }
        public bool IsGpuEnabled { get; set; }
        public bool IsMemoryEnabled { get; set; }
        public bool IsMotherboardEnabled { get; set; }
        public bool IsNetworkEnabled { get; set; }
        public bool IsPsuEnabled { get; set; }
        public bool IsStorageEnabled { get; set; }

        public IList<IHardware> Hardware
        {
            get
            {
                if (_open) AddGpuIfAvailable();
                return _hardware;
            }
        }

        public void Open()
        {
            // tryx-sensord may still be starting up when KANALI starts
            for (int i = 0; i < 50 && !LinuxSensors.HasData; i++) Thread.Sleep(100);
            _hardware.Clear();

            if (IsCpuEnabled)
                _hardware.Add(new Hardware(HardwareType.Cpu, "CPU", "cpu.name",
                    new Sensor("CPU Total", SensorType.Load, "cpu.load"),
                    new Sensor("Core (Tctl/Tdie)", SensorType.Temperature, "cpu.temp"),
                    new Sensor("Cores (Average)", SensorType.Clock, "cpu.clock"),
                    new Sensor("Package", SensorType.Power, "cpu.power")));

            if (IsMemoryEnabled)
                _hardware.Add(new Hardware(HardwareType.Memory, "Generic Memory", null,
                    new Sensor("Memory Used", SensorType.Data, "mem.used_gb")));

            if (IsNetworkEnabled)
                _hardware.Add(new Hardware(HardwareType.Network, "Network", null,
                    new Sensor("Upload Speed", SensorType.Throughput, "net.up"),
                    new Sensor("Download Speed", SensorType.Throughput, "net.down")));

            _open = true;
            AddGpuIfAvailable();
        }

        void AddGpuIfAvailable()
        {
            if (!IsGpuEnabled) return;
            foreach (IHardware h in _hardware)
                if (h.HardwareType == HardwareType.GpuNvidia || h.HardwareType == HardwareType.GpuAmd ||
                    h.HardwareType == HardwareType.GpuIntel) return;

            HardwareType type;
            switch (LinuxSensors.Text("gpu.vendor"))
            {
                case "nvidia": type = HardwareType.GpuNvidia; break;
                case "amd": type = HardwareType.GpuAmd; break;
                case "intel": type = HardwareType.GpuIntel; break;
                default: return;
            }
            _hardware.Add(new Hardware(type, "GPU", "gpu.name",
                new Sensor("GPU Core", SensorType.Load, "gpu.load"),
                new Sensor("GPU Core", SensorType.Temperature, "gpu.temp"),
                new Sensor("GPU Core", SensorType.Clock, "gpu.clock"),
                new Sensor("GPU Package", SensorType.Power, "gpu.power"),
                new Sensor("D3D Dedicated Memory Total", SensorType.SmallData, "gpu.vram_bytes", 1f / (1024 * 1024))));
        }

        public void Close()
        {
            _open = false;
            _hardware.Clear();
        }
    }
}

namespace LibreHardwareMonitor.PawnIo
{
    /// <summary>
    /// KANALI checks this at startup and otherwise runs the PawnIO kernel-driver installer,
    /// which can't work under Wine. Report a sufficiently new version as installed.
    /// </summary>
    public class PawnIo
    {
        public static Version Version { get { return new Version(2, 2, 0, 0); } }
        public static bool IsInstalled { get { return Version != null; } }
    }
}
