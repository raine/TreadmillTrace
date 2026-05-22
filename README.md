# TreadmillTrace

Standalone macOS BLE capture tool for FTMS treadmills and walking pads.

## Build

```sh
swift build -c release
```

The binary will be at:

```sh
.build/release/TreadmillTrace
```

## Run

```sh
.build/release/TreadmillTrace
```

Optional:

```sh
.build/release/TreadmillTrace --output ~/Desktop/vitalwalk.jsonl --scan-seconds 15
```

## User capture script

1. Run the tool and choose the Vitalwalk/treadmill from the list.
2. Stand off the belt for safety.
3. Follow the prompts in the terminal.
4. Enter whether the treadmill display uses `kmh`, `mph`, or unknown.
5. Use the treadmill remote or panel, not WalkingMate, during the capture.
6. For each phase, set the requested treadmill state first, then press return. The tool records the next 15 seconds automatically.
7. The tool asks for exact steps like:
   - idle
   - start from the remote or panel
   - speed exactly 1.0, 2.0, 3.0, and optionally 4.0 if supported
   - incline steps only if the treadmill reports incline support
   - stop from the remote or panel
8. Send the generated `treadmill-trace-*.jsonl` file.
