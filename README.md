# TreadmillTrace

Helper tool for [WalkingMate](https://walkingmate.zendit.fi) that captures macOS BLE diagnostics from FTMS treadmills and walking pads.

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

## Time diagnostic

Use this passive capture when a treadmill timer counts down or WalkingMate saves
multiple workouts during one walk:

```sh
.build/release/TreadmillTrace time-probe --output ~/Desktop/treadmill-time.jsonl
```

The tool guides you through idle, a normal count-up workout, a stopped state,
and a duration-target countdown workout. Use the treadmill remote or panel for
all actions. TreadmillTrace sends no control commands in this mode.

Each phase records raw FTMS Treadmill Data bytes and flags, plus separately
decoded elapsed-time and remaining-time values. At the end, the tool prints the
path of the JSONL file to send with the issue report.

## Vitalwalk diagnostic

Use this guided diagnostic for Vitalwalk speed-control, Pause, incline, and step
issues:

```sh
.build/release/TreadmillTrace vitalwalk-probe
```

The diagnostic validates FTMS Control Point indications, feature flags,
Treadmill Data notifications, and the reported speed range before it allows
movement. It rereads missing capability characteristics for up to 10 seconds
before failing safely.

The belt runs only at the reported minimum raw target and one native increment
above it. The diagnostic never derives a command target from reported speed,
because some Vitalwalk treadmills report speed in km/h while interpreting speed
commands as mph. Stand off the belt and keep the physical stop control within
reach for the entire test.

The guided run captures:

- the physical display unit
- raw `2AD4` minimum, maximum, and increment
- the physical and reported speeds at minimum and one increment
- Control Point results for Request Control, Start, Pause, Stop, speed, and incline
- Machine Status and Training Status around Pause and resume
- optional one-increment incline behavior
- displayed steps, distance, calories, and speed before the final Stop
- FTMS vendor steps and FITSHOW `FFF1` candidate steps for comparison

All numeric and observation prompts validate input. Any command failure,
interruption, or incomplete critical observation triggers an FTMS Stop attempt.
The diagnostic requires zero-speed telemetry or an exact physical `STOPPED`
confirmation before a resume test and before normal exit. Send the generated
`treadmill-trace-*.jsonl` file with the issue report.

## Probe mode

```sh
.build/release/TreadmillTrace --probe
```

Probe mode keeps the raw JSONL capture running while showing a live terminal
view of decoded treadmill stats. Control writes are disabled until you press
`a` to arm the probe. Stand off the belt and keep the treadmill stop control
reachable before arming.

Controls:

- `a`: arm control writes for this session
- `r`: send FTMS Request Control
- space: send FTMS Start/Resume
- `s`: send FTMS Stop
- up/down: speed target up/down by the reported speed increment
- left/right: incline target down/up by the reported incline increment
- `q`: disconnect and flush the log

Speed and incline controls are rejected unless the treadmill reports the
standard FTMS range characteristics. All writes use FTMS Control Point `2AD9`
with write-with-response and are logged alongside raw notifications.

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
