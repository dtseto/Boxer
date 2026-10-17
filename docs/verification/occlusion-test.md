# Boxer video-isolation verification

Build a Debug app with the instrumentation flag from the repository root:

```sh
xcodebuild -project Boxer.xcodeproj -scheme Boxer -configuration Debug \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) BOXER_VERIFICATION_INSTRUMENTATION=1' build
```

Set exact paths before each run:

```sh
export BOXER_APP="$PWD/build/Debug/Boxer.app"
export GAME="$HOME/Games/Duke Nukem 3D.boxer"
```

If DerivedData is used, replace `BOXER_APP` with the absolute app path. The exact launcher is `"$BOXER_APP/Contents/MacOS/Boxer" "$GAME"`. Every run uses a new `BOXER_VERIFICATION_CSV`; the reporter writes `<basename>-summary.json` beside it. Optional metadata variables are `BOXER_VERIFICATION_STAGING_COMMIT`, `BOXER_VERIFICATION_BLOCKSIZE`, `BOXER_VERIFICATION_MAX_INFLIGHT`, `BOXER_VERIFICATION_CPU_CYCLES`, `BOXER_VERIFICATION_CPU_CYCLES_PROTECTED`, `BOXER_VERIFICATION_CORE`, `BOXER_VERIFICATION_CPUTYPE`, and `BOXER_VERIFICATION_OUTPUT`.

HALC extraction:

```sh
tools/extract-halc.sh '2026-10-16 12:00:00' '2026-10-16 12:01:00'
```

The direct equivalent is `log show --style syslog --predicate 'process == "Boxer"' --start '<START>' --end '<END>' | grep -c 'HALC_ProxyIOContext.*skipping cycle'`.

## Test A — visible versus occluded

Use Duke Nukem 3D with MIDI enabled, or Doom with General MIDI enabled, in an attract/demo loop. Use a five-second warm-up followed by 60 seconds, with the same startup actions in both runs.

Visible:

```sh
BOXER_VERIFICATION_CSV="$PWD/verification/duke-visible.csv" \
BOXER_VERIFICATION_OUTPUT="duke-midi" \
"$BOXER_APP/Contents/MacOS/Boxer" "$GAME"
```

Keep fully visible and focused, then quit cleanly. Restart, immediately move the window behind another app or to another Space, and leave the demo running:

```sh
BOXER_VERIFICATION_CSV="$PWD/verification/duke-occluded.csv" \
BOXER_VERIFICATION_OUTPUT="duke-midi" \
"$BOXER_APP/Contents/MacOS/Boxer" "$GAME"
```

Expected summaries are `verification/duke-visible-summary.json` and `verification/duke-occluded-summary.json`. Compare with:

```sh
tools/compare-verification.py verification/duke-visible-summary.json verification/duke-occluded-summary.json --test A
```

Pass requires finish-frame rate within ±5% after warm-up, HALC rate within ±1 message/s, occluded finish p99 and max no more than 2× visible, no crash, and zero final presenting slots. A larger occluded `next_drawable` is expected. The tool prints finish-rate delta, finish-p99 delta, HALC delta, and final presenting-slot delta first.

## Test B — blocksize A/B

Run the same visible workload twice, changing the actual mixer setting and recording it in the environment:

```sh
BOXER_VERIFICATION_BLOCKSIZE=1000 BOXER_VERIFICATION_CSV="$PWD/verification/blocksize-1000.csv" "$BOXER_APP/Contents/MacOS/Boxer" "$GAME"
BOXER_VERIFICATION_BLOCKSIZE=2000 BOXER_VERIFICATION_CSV="$PWD/verification/blocksize-2000.csv" "$BOXER_APP/Contents/MacOS/Boxer" "$GAME"
tools/compare-verification.py verification/blocksize-1000-summary.json verification/blocksize-2000-summary.json --test B
```

If 1000 has zero HALC messages and comparable finish p99, return to 1000 for latency; otherwise retain 2000 and record why.

## Test C — MIDI

Use Monkey Island 2 or Doom with General MIDI. Repeat Test A using `midi-visible.csv` and `midi-occluded.csv`, then compare with `--test C`. HALC only in MIDI-active runs identifies the MIDI bridge as the next target.

## Test D — mode transitions

Use a title cycling loading, text, graphics, cutscene, and back. Run 60 seconds:

```sh
BOXER_VERIFICATION_CSV="$PWD/verification/modes.csv" "$BOXER_APP/Contents/MacOS/Boxer" "$GAME"
```

Require no crash, no stuck slot, texture creation not scaling with finish-frame count, and presenting returning to zero after each transition. With adequate initial capacity, pool allocation should occur at most once.

## Test E — resize

Resize at 15, 30, and 45 seconds during a visible 60-second run:

```sh
BOXER_VERIFICATION_CSV="$PWD/verification/resize.csv" "$BOXER_APP/Contents/MacOS/Boxer" "$GAME"
```

Require no crash, no stuck slot, and no one-frame-behind image after each resize.

## Test F — stop/start

Stop and restart emulation five times within 120 seconds:

```sh
BOXER_VERIFICATION_CSV="$PWD/verification/stop-start.csv" "$BOXER_APP/Contents/MacOS/Boxer" "$GAME"
```

Require no crash, all slot counts returning to zero after each stop, and no HALC messages during teardown.

The harness never instruments CoreAudio's IO callback or DOSBox Staging. Use Instruments' Core Audio trace for callback duration; periodic `log show` polling is reporter-thread-only.
