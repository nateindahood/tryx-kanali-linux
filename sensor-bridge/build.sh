#!/usr/bin/env bash
# Rebuild the stand-in LibreHardwareMonitorLib.dll from source (needs the .NET SDK 8+).
# The prebuilt sensor-bridge/LibreHardwareMonitorLib.dll in the repo is the output of this.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
dotnet build LibreHardwareMonitorShim -c Release -o "$PWD/build"
cp build/LibreHardwareMonitorLib.dll .
rm -rf build LibreHardwareMonitorShim/{bin,obj}
sha256sum LibreHardwareMonitorLib.dll
