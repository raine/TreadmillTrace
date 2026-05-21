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
4. Use the treadmill remote or panel, not WalkingMate, during the capture.
5. The tool will ask you to press return after exact steps like:
   - idle for 15 seconds
   - start from the remote or panel
   - speed exactly 1.0, 2.0, 3.0, and optionally 4.0
   - incline 1, 2, and back to 0 if supported
   - stop from the remote or panel
6. Send the generated `treadmill-trace-*.jsonl` file.

Please also tell us whether the treadmill display was using km/h or mph.
