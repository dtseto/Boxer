# DOSBox-Staging 0.81.2 Boxer integration handoff

## Purpose

Finish and validate the hybrid DOSBox-Staging 0.81.2 integration on the current Boxer adapter branch. The DOSBox merge must retain the current typed Boxer bridge adapters; do not replace the DOSBox submodule pointer with `boxer-compat-0.81`.

## Repository and starting points

- Boxer branch: `branch-test-810-lib`
- Boxer starting baseline: `7a0eef1c539135b5f3e26d17658823a6c28dfbcd`
- DOSBox branch: `boxer-compat-localtest810lib`
- DOSBox starting baseline: `ec08467618dffcde9ee4aae9dabf64254a9f4f29`
- Upstream release: `v0.81.2` at `10de14255b48900d631985d7ffaf33ad7a9f707b`
- Migration reference: `boxer-compat-0.81` at `741fa9b88204ef4dc683e1ca14023fada1bce4d5`

The DOSBox submodule currently has merge commit:

```text
2241da2c34 ec08467618 10de14255b
Merge tag 'v0.81.2' into boxer-compat-localtest810lib
```

The merge is a real two-parent merge. Do not rewrite it with a squash or an ours merge.

No additional DOSBox merge commit is required. Follow-up work must use a compatibility/source-inventory message, not another `Merge DOSBox Staging v0.81.2 with Boxer adapter preservation` message.

## Files that must remain untouched

Do not overwrite, reset, or stage unrelated changes in:

- `Boxer.xcodeproj/project.pbxproj`
- `Vendor/DDHidLib`
- `Vendor/MT32Emu`
- `Vendor/OpenEmuShaders`
- untracked `codex`
- untracked `codex-code-mode-host`

Do not edit `project.pbxproj` directly while Xcode is open. Before authorization,
the protected-path phase must not perform Xcode source-membership migration; the
full Boxer build may therefore remain blocked by stale source membership until a
separate project-migration phase is approved.

The project-membership migration was subsequently authorized and completed through
Xcode's project object model. Preserve the resulting project diff as user work; do
not recreate it with raw text substitutions or revert it during a later DOSBox merge.

If the user authorizes that separate phase, project membership may be changed through Xcode’s project-management actions. That phase must:

1. move the old `src/hardware/mouse` group to `src/hardware/input`;
2. add the missing 0.81.2 source units listed below;
3. remove duplicate Compile Sources entries;
4. remove the temporary forwarding units under `src/hardware/mouse/`;
5. inspect the resulting `project.pbxproj` diff for unintended changes; and
6. treat that project-file change as an explicitly authorized exception to the protected-path rule.

Without that authorization, do not modify the project file and do not claim a complete Boxer build. After authorization, verify the project structure and source inventory before changing DOSBox compatibility code.

## Current working-tree state

The DOSBox merge itself is committed at `2241da2c34`. DOSBox compatibility/source-inventory follow-up edits are currently uncommitted. Boxer adapter follow-up edits are also uncommitted. Inspect both repositories before changing anything:

```bash
git -C DOSBox-Staging status --short --branch
git status --short --branch
```

Preserve the existing dirty paths listed above.

## What the merge preserved

The DOSBox tree contains the current typed bridge registration and adapter headers, including:

- `include/BXDOSBoxBridgeRegistration.h`
- `include/BXDOSBoxCoalfaceCompatibility.h`
- `include/BXDOSBoxDiagnosticsCompatibility.h`
- `include/BXDOSBoxEventCompatibility.h`
- `include/BXDOSBoxFilesystemCompatibility.h`
- `include/BXDOSBoxLegacyCompatibility.h`
- `include/BXDOSBoxLegacyDeclarations.h`
- `include/BXDOSBoxRenderingCompatibility.h`
- `include/BXDOSBoxRunLoopCompatibility.h`
- `include/BXDOSBoxShellCompatibility.h`

The DOSBox source must not include `BXCoalface.h` directly. Legacy compatibility belongs behind DOSBox-side adapter headers. Keep the current printer, keyboard, shell, filesystem, joystick, audio/MIDI, rendering, event, lifecycle, and shutdown bridges.

## Historical Xcode build blocker

After source compilation was repaired, the normal Xcode build reached the link step and failed with undefined symbols for 0.81.2 source units that are not present in the preserved Xcode project source inventory. Examples include:

- `ShaderManager::*`
- `CommandLine::*`
- `CAPTURE_*`
- `AUTOEXEC_*`
- `DOS_Locale_*`
- `VIRTUALBOX_*` and `VOODOO_*`
- newer `GFX_*` entry points
- `FileReader::*`
- `MIXER::AddMessages`, `TREE::AddMessages`, and `SETVER::*`

This was a project-inventory problem, not a remaining Git conflict. DOSBox-Staging 0.81.2 moved or added source files, while the older `project.pbxproj` enumerated the pre-0.81.2 DOSBox layout. The authorized migration below resolved this source-inventory blocker.

## Separate authorized Xcode project migration

Only after explicit authorization to modify the protected project file, use Xcode project tools to update the Boxer target’s DOSBox source membership. At minimum, audit these upstream additions and moves:

- `src/capture/` and all capture implementation files
- `src/dos/dos_locale.cpp`
- `src/dos/program_mixer.cpp`, `program_move.cpp`, `program_setver.cpp`, `program_subst.cpp`, `program_tree.cpp`
- `src/hardware/input/` and its keyboard/mouse implementation files
- `src/hardware/virtualbox.cpp`
- `src/hardware/vmware.cpp`
- `src/hardware/voodoo.cpp`
- `src/gui/shader_manager.cpp`
- `src/shell/autoexec.cpp`, `command_line.cpp`, `command_line_stubs.cpp`, `file_reader.cpp`
- `src/ints/bios_pci.cpp`
- any other `.cpp` added by the 0.81.2 `meson.build` source lists and required by Boxer

Remove obsolete duplicate source membership when a file moved; do not compile both old and new implementations. The temporary forwarding units under `src/hardware/mouse/` are an interim compatibility experiment and must be removed after Xcode points at `src/hardware/input/` directly. Do not remove them during the protected-path phase if doing so would break the unchanged project configuration.

Also audit header search paths. DOSBox source includes should resolve these directories without ad-hoc duplicate copies:

- `src/libs/enet/include`
- `src/libs/decoders`
- `src/libs/nuked`
- `src/libs/mverb`
- `src/libs/tal-chorus`
- `src/libs/manymouse`

Do not solve missing source membership by adding a monolithic `.cpp` that includes other `.cpp` files.

## Safe DOSBox work already completed

The following safe DOSBox-side corrections have been made or verified and should be reviewed, not duplicated:

- direct `BXCoalface.h` references were removed from DOSBox source/include files;
- the DOSBox-side event bridge call site was added;
- filesystem bridge call sites were added for drive-cache/local-drive code;
- the printer bridge adapter was added;
- the unnecessary direct Coalface include from `shell_batch.cpp` was removed;
- the typed adapter boundary was preserved;
- `xcodebuild -project Boxer.xcodeproj -list` passed;
- the standalone `DOSBoxStaging` target build passed;
- the exact DOSBox source/include `BXCoalface.h` search returned no matches; and
- the added-line security scan found no secret, shell-injection, eval/exec, or unsafe-deserialization matches.

These results do not establish a successful full Boxer build.

## Adapter follow-up to review

Review the uncommitted compatibility edits before committing. In particular:

- `include/dosbox.h` must use guarded `BXDOSBoxCoalfaceCompatibility.h`, not direct `BXCoalface.h`.
- `include/render.h` and `include/mouse.h` contain legacy Boxer compatibility boundaries; confirm they do not alter upstream behavior outside Boxer integration.
- `include/mixer.h` / `src/hardware/mixer.cpp` expose the required audio lifecycle adapter.
- `src/dos/dos_keyboard_layout.cpp`, `src/dos/dev_con.h`, and `src/ints/bios_keyboard.cpp` must define the input call-site adapter before including its compatibility header.
- `BXEmulator+BXAudio.mm` must use `MixerState::Muted` and the supported mixer API.
- `BXEmulator+BXShell.mm` must use `DOS_Shell::hasNoBatchFiles()` rather than the removed `bf` member.
- `BXEmulator+BXDOSFileSystem.mm` must use the 0.81.2 `std::array` `Drives` declaration and `RealToPhysical`.
- `BXVideoHandler.mm`, `BXEmulatedMouse.mm`, `BXCoalface.mm`, and printer code must retain the opaque bridge boundary and compile as Objective-C++.

Do not reintroduce direct Objective-C or `BXCoalface.h` dependencies into DOSBox source.

## Validation sequence

After project membership and adapter review:

1. Normal `BuildProject`.
2. `BuildProject` with `buildForTesting: true`.
3. `RunAllTests` for the complete active test plan.
4. Run printer, keyboard, shell, filesystem, joystick, audio/MIDI, rendering, event, lifecycle, and shutdown harnesses.
5. Validate the Phase 5 printer/legacy declaration boundary.
6. Validate the opaque bridge registration header.
7. Confirm no `BXCoalface.h` references in DOSBox source:

   ```bash
   grep -RIn 'BXCoalface\.h' DOSBox-Staging/src DOSBox-Staging/include
   ```

8. Launch Boxer and DOSBox with `RunProject`.
9. Verify clean DOS exit and shutdown.
10. Use `GetConsoleOutput` for launch and shutdown logs.

Treat known macOS autosave, SQLite DetachedSignatures, graphics-factory, and audio-device warnings as informational unless a new fatal error, exception, KVO failure, or crash appears.

## Verified 0.81.2 follow-up fixes

The following runtime fixes are part of the validated hybrid integration and must be
preserved in future merges:

- `DOSBOX_RunMachine` routes through the registered run-loop adapter.
- Rendering, event, and shell call sites route through their DOSBox-side compatibility headers.
- The Boxer run-loop shutdown condition requires both `!shutdown_requested` and
  `boxer_runLoopShouldContinue()`.
- `DOS_Shell::RunBatchFile` canonicalizes the path before sending the batch-end callback.
- Replacing a batch file without `CALL` sends the matching end callback before the old
  batch frame is removed.
- Boxer records a batch process only after DOSBox successfully opens the file.
- Boxer launcher dispatch recognizes `.BAT`, `.COM`, and `.EXE` by extension as a
  fallback when macOS reports a generic UTI. This is required because direct DOS
  command-line execution can work even when launcher UTI classification fails.

These batch fixes are important: a `.BAT` can work when typed at the DOS prompt while
silently being treated as a directory by the host launcher, or while leaving Boxer's
active-process stack out of sync during nested batch execution.

## Current validation status

The authorized project migration and compatibility fixes now allow the normal Boxer
build to succeed. The most recent verified result is:

- normal Xcode build: passed;
- DOSBox-Staging target build: passed;
- project parsing with `xcodebuild -project Boxer.xcodeproj -list`: passed;
- duplicate Compile Sources audit after migration: passed;
- direct DOSBox source/include `BXCoalface.h` scan: no matches; and
- manual launcher verification: `.BAT` auto-load and launcher selection now work after
  extension-based dispatch was added.

The complete test-plan and all requested harnesses still need to be rerun after the
latest runtime changes. Treat the known macOS autosave, SQLite DetachedSignatures,
graphics-factory, and audio-device warnings as informational unless a new fatal error,
exception, KVO failure, or crash appears.

Do not commit until the final test and shutdown sequence is complete. The DOSBox merge
itself is already committed at `2241da2c34`; follow-up compatibility work needs a new,
focused message.

## Commit order after the blocker is cleared

After final validation:

1. Stage and commit DOSBox compatibility/source-inventory changes only, using a focused message such as:

   ```text
   Complete DOSBox 0.81.2 Boxer compatibility source inventory
   ```

2. Commit Boxer source/tests/documentation changes separately.
3. Update and commit the Boxer DOSBox submodule pointer separately if it is not included with the intended Boxer integration commit.
4. Verify none of the protected dirty paths entered any commit.

Before each commit, run:

```bash
git diff --check
git diff --name-only --diff-filter=U
git ls-files -u
grep -RIn '^<<<<<<< \|^>>>>>>> ' DOSBox-Staging/src DOSBox-Staging/include
```

The last three checks must report no unresolved conflicts or conflict markers.

## Recommended repeatable procedure for 0.82 and 0.83

1. Record Boxer and DOSBox `HEAD`, branch names, tag commit, submodule status, and all dirty paths.
2. Enable rerere in the DOSBox repository:

   ```bash
   git config rerere.enabled true
   ```

3. Merge the upstream tag normally:

   ```bash
   git merge --no-ff -Xpatience -Xrenormalize v0.82.0
   ```

4. Use the previous release’s Boxer-compatible branch only as a migration reference, never as a replacement for the current adapter branch.
5. Resolve upstream-only changes first.
6. Resolve adapter points individually, preserving typed bridge registration and DOSBox-side compatibility headers.
7. Use `git diff --name-only --diff-filter=U`, `git ls-files -u`, and conflict-marker scans before staging.
8. Update Xcode source membership for moved/added upstream files through Xcode tools, without hand-editing the project file while Xcode is open.
9. Build normally and for testing before committing.
10. Run the complete active test plan and lifecycle harnesses.
11. Commit DOSBox, then Boxer source/tests/documentation, then the submodule pointer.
12. Repeat the same procedure for 0.83, changing only the upstream tag and release-specific source migration list.

For each release, record the exact conflict decisions in the DOSBox merge commit message or an adjacent migration note.
