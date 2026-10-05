# Phase 2: DOSBox bridge inventory and boundary

## Scope

This phase separates the Boxer host bridge from DOSBox implementation details
incrementally. The standalone Boxer dependency is intentionally out of scope.
The existing runtime harness remains the regression baseline.

## Inventory

| Area | Boxer entry points | DOSBox consumers | DOSBox-only details to retain behind the boundary |
| --- | --- | --- | --- |
| Rendering and run loop | `BXCoalface.mm`, `BXVideoHandler.mm` | `dosbox.cpp`, `gui/render.cpp`, `include/dosbox.h` | `Bitu`, `GFX_*`, `MouseHint`, `GFX_CallBack_t` |
| Shell and commands | `BXCoalface.mm`, `BXEmulator+BXShell.mm` | `shell/*.cpp` | `DOS_Shell *`, DOS command buffers, shell lifecycle |
| Filesystem and drives | `BXCoalface.mm`, `BXEmulator+BXDOSFileSystem.mm` | `dos/*.cpp`, `drive_local.cpp`, `drive_cache.cpp` | `DOS_Drive *`, `DOS_File *`, `Drives[]`, `Files[]` |
| Keyboard and input | `BXCoalface.mm`, `BXEmulatedKeyboard.mm`, `BXKeyBuffer.mm` | keyboard, BIOS keyboard, console, layout code | `Bitu`, `KBD_KEYS`, DOS keyboard-layout state |
| Printer | `BXCoalface.mm`, `BXEmulatedPrinter.mm` | `hardware/parport/printer_redir.cpp` | DOS LPT register widths and port conventions |
| Audio and MIDI | `BXCoalfaceAudio.mm`, `BXEmulator+BXAudio.mm` | `hardware/mixer.cpp`, `midi/midi.cpp` | DOSBox mixer channels and MIDI handler configuration |
| Diagnostics | `BXCoalface.mm`, `BXEmulatorPrivate.h` | message and error paths | DOSBox formatting and `E_Exit` semantics |

The current `BXCoalface.h` combines all of these areas and also defines the
DOSBox macro remaps. It is therefore retained as a compatibility header while
the categories are migrated; it is not a suitable long-term public API.

## First boundary

Audio and MIDI are the first isolated surface. `BXDOSBoxBridgeRegistration.h`
contains only fixed-width C-compatible callback types and registration/accessor
functions. DOSBox's mixer and MIDI implementation now consume that callback
table as the production DOSBox audio/MIDI boundary. DOSBox uses the table
for mixer volume, MIDI messages, SysEx, and MIDI configuration. A weak-symbol
fallback preserves the legacy harness link contract when a lightweight harness
provides only the callback family it exercises. The remaining bridge categories
still use `BXCoalface.h` and will migrate independently.

The printer boundary is also migrated. `printer_redir.cpp` consumes the
registered printer callbacks through compatibility macros that retain the
legacy symbol expressions required by the standalone printer harness.

The keyboard/input boundary is now partially migrated. Console input,
BIOS paste and lock-state callbacks consume the registered input table, while
DOSBox-owned keyboard buffer and layout state APIs remain legacy symbols for
the runtime harness. The legacy call expressions are intentionally preserved
so the keyboard regression harness continues to exercise the same contracts.

## Validation contract

After each boundary change:

1. Build the Boxer scheme and its DOSBox Staging dependency.
2. Run the existing runtime harness tests.
3. Launch a representative DOS session, type `exit`, and check for normal
   DOSBox shutdown with no KVO exception or `FAULT` block.

The latest manual baseline already confirms keyboard layout loading and clean
session shutdown after the Phase 1 KVO fix.
