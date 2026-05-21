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
3. Leave the treadmill idle for 15 seconds.
4. Start the treadmill using the remote or panel, then wait 15 seconds.
5. Set known speeds from the remote or panel, waiting 15 seconds each.
6. Try incline levels if supported, waiting 15 seconds each.
7. Stop the treadmill from the remote or panel.
8. Press return in the tool to disconnect and finish the log.
9. Send the generated `treadmill-trace-*.jsonl` file.
