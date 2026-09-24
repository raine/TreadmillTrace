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

## Apollo resume diagnostic

Use this focused diagnostic to test restoring the saved speed after an Apollo
Stop-based Pause:

```sh
.build/release/TreadmillTrace apollo-resume-probe
```

The probe establishes a saved target one native increment above minimum speed,
stops the belt, and waits for the physical `END` message to clear. It then sends
Start, waits for nonzero speed telemetry, and restores the saved target. If the
first post-movement speed command has no effect, it sends the same safe target
once more after a delay.

The belt stays at the reported minimum or one native increment above it. Stand
off the belt and keep the physical stop control within reach. The generated
JSONL records command responses, movement timing, display observations, and both
restoration attempts.

## TT6F release diagnostic

Use this focused probe to verify WalkingMate's generic FTMS behavior on a
Techo-Train TT6F before releasing an app update:

```sh
.build/release/TreadmillTrace tt6f-probe --output ~/Desktop/tt6f.jsonl
```

This mode deliberately does not subscribe to FITSHOW `FFF1`. It records idle
FTMS telemetry, requests control once, then measures telemetry again with
WalkingMate's two-second Request Control heartbeat. It sends Start followed by a
standard km/h target at the treadmill's reported minimum speed while keeping the
heartbeat active. If that sequence does not move the belt, it safely stops and
tries the minimum-speed target before Start without heartbeats. A moving belt is
also tested with WalkingMate's exact 3.0 km/h default when the treadmill supports
it. The probe records physical movement, the displayed speed and unit, and FTMS
telemetry before sending Stop. Stand off the belt and keep the physical stop
control within reach. Any command failure or interruption triggers an FTMS Stop
attempt.

Send the generated JSONL file with the issue report. A successful run confirms
whether the proposed WalkingMate path can both start the belt and retain
tracking without distributing a WalkingMate build.

## KingSmith X21 diagnostic

Use this probe for a KingSmith X21 (`KS-NACH-X21C`) that connects but reports no
data:

```sh
.build/release/TreadmillTrace x21-probe --output ~/Desktop/x21.jsonl
```

The probe requires the X21 service `00021234` with characteristics `0002FED7`
and `0002FED8`, and stops on any other layout. It performs the X21 handshake
with one candidate encoding table and requests idle status. It stops on an
invalid response, a timeout, or a disconnect.

After the handshake succeeds, the probe guides a passive capture. You start the
belt at its lowest speed, raise the speed by one step, and stop the belt, all
from the treadmill panel or remote. During these phases TreadmillTrace sends only
status queries. Type `q` at any prompt to finish early. The log is kept.

The probe then offers optional control validation. This part moves the belt.
It uses only the lowest speed and the next speed that the treadmill reported
during the passive capture. The lowest speed must be 2.0 km/h or less, and the
next speed must be at most 0.5 km/h higher. Before any command, the treadmill
must report that it is stopped, and you must type `RUN X21 CONTROL PROBE`.
Stand off the belt and keep the physical stop control within reach.

The probe sends manual mode, Start, the low speed, the next speed, and Stop, in
that order, and checks the reported status after every command. Start comes
before the speed target because that is the reported start sequence for this
protocol, and setting a speed before Start is not established for the X21. The
treadmill therefore chooses its own start speed. If it reports a speed above
the planned maximum, the probe sends Stop. The next speed is sent only after
you confirm that the belt moves at the low speed.

The probe sends Stop on a missing or stale status, an unexpected state, a
speed above the plan, a failure, or an interruption. It then asks you to
confirm that the belt has physically stopped, and sends Stop again until you
do. Until then, it reports that the belt may still be moving. Pause and incline
are not tested. Press return at the offer to skip control validation and keep
the passive results.

Send the generated JSONL file with the issue report. It records raw and decoded
traffic with timing, and summarizes the passive and control results
separately.

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
