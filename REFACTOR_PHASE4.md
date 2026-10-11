# Phase 4: Legacy `BXCoalface.h` surface reduction

Phase 3 established typed registration boundaries for the DOSBox-to-Boxer
callbacks and verified the public registration header is opaque. Phase 4 will
reduce the remaining compatibility surface without changing runtime behavior.

## Objective

Separate host-facing declarations, DOSBox-only compatibility declarations, and
legacy macro remaps so new DOSBox code depends on typed adapters rather than
including `BXCoalface.h` directly.

## Baseline

- Boxer branch: `branch-test-800-lib`
- Phase 3 closure commit: `923f3727`
- DOSBox bridge revision: `73f2af6fd`
- Regression baseline: 69 tests passing
- Required validation: normal build, build-for-testing, full test plan, and
  launch/exit smoke validation

## Implementation sequence

### Step 1: Freeze the compatibility inventory

- Enumerate every declaration and macro still consumed from `BXCoalface.h`.
- Classify each use as host-only, DOSBox-only, legacy harness, or migration
  candidate.
- Add contract coverage for the inventory before changing includes.

Current frozen counts are 21 legacy macro remaps, 72 `boxer_*` declarations,
and six actual direct consumers: `BXCoalface.mm`, `BXEmulatedKeyboard.mm`,
`BXKeyBuffer.mm`, `BXEmulatedPrinter.mm`, `dosbox.h`, and `shell_batch.cpp`.
`printer_redir.cpp` retains a documented compatibility comment and uses the
typed printer adapter at its callsites.

### Step 2: Introduce a host declaration boundary

- Create a host-facing declaration header containing only callback entry points
  that Boxer implements or intentionally exposes.
- Keep DOSBox implementation types and legacy signatures out of that header.
- Add the header to the Xcode target through Xcode’s project integration; do
  not edit the project file directly while Xcode is open.
- Preserve `BXCoalface.h` as a compatibility shim during the transition.

Step 2 has begun with the project-integrated `BXHostBridge.h`, which contains
only keyboard buffer and keyboard-layout declarations. `BXEmulatedKeyboard.mm` now uses that header,
while `BXKeyBuffer.mm` and `BXEmulatedPrinter.mm` no longer import
`BXCoalface.h` directly. The project-aware Xcode integration added the header;
the mixed pre-existing project-file diff remains uncommitted.

The DOSBox umbrella boundary now also owns the legacy `E_Exit` remap. Typed
fatal-message formatting is intentionally deferred until the host and DOSBox
include contexts are separated; attempting it globally leaks the DOSBox
callsite macro into Boxer Objective-C++ translation units.

The include-context split is now in place: `dosbox.h` exposes the legacy
compatibility header to DOSBox C++ translation units, but suppresses it for
Objective-C++ host translation units. `BXCoalface.mm` now calls the typed
fatal host entry point directly, keeping DOSBox-only remaps out of the host
while preserving the standalone runtime harness.

Diagnostics now use the same boundary: `GFX_ShowMsg` and `E_Exit` remain
literal DOSBox call expressions, but their remaps and formatting live in
`BXDOSBoxDiagnosticsCompatibility.h`. The typed adapter formats messages once
and dispatches them through `BXDOSBoxDiagnosticsBridgeCallbacks`; standalone
harnesses retain weak legacy fallbacks.

Keyboard-layout preference lookup now travels through the input callback table;
the DOSBox source retains the literal `boxer_preferredKeyboardLayout()` call
through a DOSBox-only compatibility macro, while Boxer supplies the typed
`preferredKeyboardLayout` callback.

Joystick ownership now has its own opaque callback table and DOSBox-only
compatibility macro. Filesystem call sites were already using the typed
filesystem table; the remaining unused local-file, directory-enumeration, and
mount wrappers have been removed from the Coalface compatibility shim while
the active emulator filesystem methods remain available internally.

### Step 3: Migrate Boxer host consumers

- Move `BXEmulatedKeyboard.mm`, `BXKeyBuffer.mm`, and
  `BXEmulatedPrinter.mm` to the host declaration or typed registration APIs.
- Keep `BXCoalface.mm` as the single host implementation/registration point.
- Preserve any Objective-C++ type declarations required by the current ABI.

### Step 4: Reduce DOSBox umbrella-header coupling

- Replace direct `BXCoalface.h` inclusion in `dosbox.h` and the shell/printer
  compatibility paths with domain-specific adapters where possible.
- Retain literal legacy expressions required by standalone harness contract
  tests until equivalent typed coverage exists.
- Do not remove a legacy symbol solely because it is unused in the production
  build; first verify the standalone harness and extracted-source tests.

### Step 5: Remove obsolete remaps incrementally

- Remove only one remap family at a time after its typed adapter is active.
- Candidate order: capture/logging, keyboard-layout state, joystick ownership,
  then remaining filesystem operations.
- After each family, run the focused contract/runtime tests and both build
  modes.

### Step 6: Phase 4 acceptance

- No new production DOSBox source includes `BXCoalface.h` directly.
- Remaining compatibility includes are documented and limited to approved
  harness or transition paths.
- Public bridge headers contain no DOSBox implementation types.
- Full runtime baseline remains green, including launch and DOS exit shutdown.
- Boxer and DOSBox changes are committed separately, with unrelated Xcode,
  vendor, and untracked files left untouched.

## Safety rules

- Do not edit `Boxer.xcodeproj/project.pbxproj` directly while Xcode is open.
- Do not modify standalone vendor dependencies in Phase 4.
- Do not combine compatibility cleanup with behavioral changes.
- Treat a harness failure as a boundary regression, not as permission to weaken
  the harness contract.
