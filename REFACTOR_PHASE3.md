# Phase 3: Bridge hardening and legacy compatibility reduction

## Step 1: Public API and legacy symbol inventory

Date: October 9, 2026  
Baseline: Boxer `branch-test-800-lib` at `757e2d24`; DOSBox-Staging
submodule at `5b9d4d9cf`.

This inventory is intentionally read-only. It records the current boundary
before any Phase 3 API or compatibility changes are made.

## Current public registration surface

`DOSBox-Staging/include/BXDOSBoxBridgeRegistration.h` currently defines seven
callback tables:

| Domain | Public callback state | Current adapter |
| --- | --- | --- |
| Audio/MIDI | Audio channel, MIDI availability, MIDI bytes/SysEx, volume, MIDI configuration | Registration functions plus audio compatibility fallback in the registration header |
| Printer | Opaque-width port reads and writes | Registration functions plus printer call-site adapter |
| Keyboard/input | Paste-buffer reads, cancellation, lock-key state | Registration functions plus input call-site adapter |
| Shell | Opaque `uintptr_t` shell handles and command/lifecycle callbacks | `BXDOSBoxShellCompatibility.h` |
| Filesystem/drives | Paths, opaque drive handles, file notifications, mount state | `BXDOSBoxFilesystemCompatibility.h` |
| Run loop | Continuation and opaque context lifecycle | `BXDOSBoxRunLoopCompatibility.h` |
| Rendering | Frame lifecycle, output mode, palette, shader, strategy | `BXDOSBoxRenderingCompatibility.h` |

The public tables use fixed-width C-compatible values and do not expose
`DOS_Shell *` or `DOS_Drive *`. The DOSBox compatibility headers still know
about those types and translate them to opaque `uintptr_t` values.

## Existing `BXCoalface.h` consumers

The combined compatibility header is still imported by:

- `Boxer/BXCoalface.mm`
- `Boxer/BXEmulatedKeyboard.mm`
- `Boxer/BXKeyBuffer.mm`
- `Boxer/Printing/BXEmulatedPrinter.mm`
- `DOSBox-Staging/include/dosbox.h`
- `DOSBox-Staging/src/shell/shell_batch.cpp`

`BXCoalface.h` currently combines three responsibilities:

1. Boxer host callback declarations.
2. DOSBox implementation-type declarations and legacy signatures.
3. Global macro remaps for rendering, events, mouse, MIDI, capture, logging,
   and fatal errors.

It remains a compatibility header, not a suitable long-term public bridge
header.

## Legacy symbol classification

### Already represented by registration tables

These legacy families have a public table and DOSBox adapter, but their old
symbols remain for harness compatibility:

- Audio and MIDI callbacks
- Printer register callbacks
- Paste and lock-key input callbacks
- Shell lifecycle, command, batch, and launch callbacks
- Filesystem write policy, file notifications, drive mount/unmount, and cache filtering
- Run-loop continuation and context lifecycle
- Frame acquisition, frame completion, output mode, palette, shader, and render strategy

### Still unregistered or only partially migrated

These are the next candidates for typed bridge contracts:

- Diagnostics and errors: `boxer_log`, `boxer_die`, localized message lookup,
  and `E_Exit` translation
- Event/run-loop UI: `boxer_processEvents`, `boxer_MaybeProcessEvents`, title
  refresh, mouse hints, capture, visibility, raw input, desktop checks, and
  mouse centering
- Rendering preferences: Hercules tint, CGA hue/component mode, and display
  refresh rate
- Filesystem operations: open/remove/move files, remove/create directories,
  path statistics, existence checks, directory enumeration, and mount-path
  authorization
- Keyboard layout state: loaded/name/supported/active state and layout changes
- Keyboard buffer capacity: `boxer_keyboardBufferRemaining`
- Host input ownership: joystick active state and mouse movement
- Remaining printer declarations in `BXCoalface.h`, even though printer
  production call sites now use the registered table

### DOSBox-only or implementation-specific symbols

These should not become public bridge callbacks without a demonstrated host
requirement:

- `Bitu`
- `GFX_CallBack_t`
- `MouseHint`
- `DOS_Shell *`
- `DOS_Drive *`
- DOSBox-specific keyboard-layout state objects
- DOSBox-specific file and directory handles

They belong in DOSBox compatibility adapters or inside DOSBox itself.

## Public-header findings

The registration header is mostly opaque, but it still contains compatibility
concerns that Step 2 must address:

- It includes `<string>` solely for the legacy MIDI fallback.
- It declares weak legacy Boxer symbols in the non-production path.
- The audio registration declaration is available outside the production
  accessor guard while the other registration/accessor declarations are
  conditionally exposed.
- The fallback callbacks are assembled in the public registration header for
  several domains, rather than exclusively in domain-specific compatibility
  headers.
- Callback structs have no explicit documented registration lifetime,
  replacement, or clear/unregister policy.

These are findings, not changes. Moving the fallback declarations and
normalizing registration visibility belongs to the next Phase 3 step after
this inventory is reviewed.

## Step 1 acceptance baseline

- The current Phase 2 callback tables and adapters are identified.
- All direct `BXCoalface.h` consumers are identified.
- Remaining legacy symbols are classified as migrated, partially migrated,
  unregistered, or DOSBox-only.
- Diagnostics/error handling is confirmed as the first new bridge candidate.
- No Xcode project, vendor submodule, release artifact, or generated build
  output was changed by this inventory.

## Next step

Step 2 split the compatibility declarations out of the public registration
header and documented the registration lifecycle policy. The next boundary is
the typed diagnostics/error callback table, beginning with localization and
preserving the existing variadic logging and fatal-error behavior through the
adapter.
