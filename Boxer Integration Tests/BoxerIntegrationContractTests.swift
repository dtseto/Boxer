import Foundation
import XCTest

final class BoxerIntegrationContractTests: XCTestCase {
    struct CoverageRow {
        let subsystem: String
        let markers: [String]
    }

    private static let documentedRows: [CoverageRow] = [
        CoverageRow(subsystem: "Core bridge, SDL/event/mouse/video capture remaps", markers: ["coalface-remaps"]),
        CoverageRow(subsystem: "Emulator run loop and shutdown lifecycle", markers: ["runloop-termination", "runloop-event-cancellation", "runloop-context", "shutdown-drive-clear"]),
        CoverageRow(subsystem: "Build/Xcode compatibility", markers: ["xcode-lazyflags-include", "keyboard-enum-c-compat"]),
        CoverageRow(subsystem: "Configuration: MT-32, MIDI, and parallel printer", markers: ["boxer-mt32-config-include", "mt32-device-value", "mt32-help-unconditional", "mt32-midiconfig-help", "mt32-config-section", "dosbox-parport-init", "parallel-config-section"]),
        CoverageRow(subsystem: "MIDI routing and sysex policy", markers: ["midi-routing"]),
        CoverageRow(subsystem: "Audio mixer volume bridge", markers: ["mixer-volume-bridge"]),
        CoverageRow(subsystem: "Video rendering, display options, capture files", markers: ["render-reset-strategy", "display-mode-controls", "display-refresh-rate", "capture-file-routing", "core-mode-title-refresh"]),
        CoverageRow(subsystem: "Keyboard input, paste, lock keys, and layout", markers: ["keyboard-buffer-capacity", "console-read-cancel", "console-paste-availability", "bios-key-paste-pop", "bios-key-paste-peek", "caps-lock-state", "num-lock-state", "scroll-lock-state", "int16-cancel", "keyboard-layout-switching-api", "keyboard-cpi-buffer-storage", "keyboard-layout-state-methods", "keyboard-layout-bridge", "macos-preferred-keyboard-layout", "us-layout-remap-fix"]),
        CoverageRow(subsystem: "Joystick and controller ownership", markers: ["gameport-timing-export", "gameport-timing-state", "mapper-free-autofire", "gameport-poll-activation", "gameport-timing-config", "preserve-controller-ownership", "dos-visible-joystick-state", "joystick-handler-install-end"]),
        CoverageRow(subsystem: "Gamebox drive paths, file policy, and mounted media", markers: ["drive-system-path", "initialize-drive-system-path", "retrieve-drive-system-path", "fat-drive-system-path", "iso-drive-system-path", "local-drive-system-path", "drive-cache-filter-bridge", "hide-host-metadata", "file-create-write-policy", "file-open-write-policy", "file-open-write-policy-end", "file-delete-write-policy", "local-dir-create-policy", "local-file-created", "local-file-removed", "local-open-file-removed", "imgmount-drive-mounted", "mount-drive-mounted", "drive-unmounted", "invalid-fat-image-fails-construction", "invalid-fat-bootsector-fails-construction", "suppress-cdrom-image-error-text", "file-unavailable-notification", "local-file-unavailable-notification", "local-file-unavailable", "unavailable-file-read", "unavailable-file-write", "unavailable-file-seek", "unavailable-file-timestamp"]),
        CoverageRow(subsystem: "Shell lifecycle, command injection, and launch tracking", markers: ["current-shell-export", "active-shell-global", "shell-run-lifecycle", "shell-misc-bridge", "shell-input-injection", "shell-command-filter", "batch-lifecycle-bridge", "batch-file-ended", "program-launch-lifecycle"]),
        CoverageRow(subsystem: "Shell command UX compatibility", markers: ["hide-intro-command", "shell-command-ux", "delete-help-if-no-args", "delete-unix-path-tolerance", "rename-help-if-no-args", "mkdir-help-if-no-args", "mkdir-unix-path-tolerance", "rmdir-help-if-no-args", "rmdir-unix-path-tolerance", "dir-unix-path-trailing-slash", "dir-unix-path-tolerance", "copy-help-if-no-args", "copy-unix-path-tolerance", "if-help-if-no-args", "type-help-if-no-args", "call-help-if-no-args", "subst-help-if-no-args", "loadhigh-help-if-no-args", "loadhigh-unix-path-tolerance"]),
        CoverageRow(subsystem: "Printer and parallel-port routing", markers: ["printer-redirection", "parport-skip-occupied-lpt", "bios-parport-include", "int17-printer-emulation", "bios-parport-detection-disabled", "bios-equipment-parport-count", "bios-refresh-parport-count", "int21-printer-output"]),
        CoverageRow(subsystem: "Localization", markers: ["localization-routing", "upstream-localization-disabled"]),
    ]

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var dosboxRoot: URL {
        projectRoot.appendingPathComponent("DOSBox-Staging")
    }

    func testBoxerPatchesMarkerInventoryMatchesSource() throws {
        // Protects every BOXER marker documented in BOXER_PATCHES.md.
        XCTAssertEqual(Self.documentedRows.count, 14)
        XCTAssertEqual(documentedMarkerSet().count, 111)
        XCTAssertEqual(documentedMarkerSet(), try sourceMarkerSet())
    }

    func testCoreBridgeContracts() throws {
        // Protects BOXER marker: coalface-remaps
        try expectBlock("include/dosbox.h", marker: "coalface-remaps", contains: "#include \"BXCoalface.h\"")
        for remap in ["#define GFX_Events boxer_processEvents",
                      "#define GFX_StartUpdate boxer_startFrame",
                      "#define GFX_EndUpdate boxer_finishFrame",
                      "#define Mouse_AutoLock boxer_setMouseActive",
                      "#define MIDI_Available boxer_MIDIAvailable",
                      "#define OpenCaptureFile boxer_openCaptureFile",
                      "#define E_Exit"] {
            try expect(projectRoot.appendingPathComponent("Boxer/BXCoalface.h"), contains: remap)
        }
    }

    func testRunLoopAndShutdownContracts() throws {
        // Protects BOXER markers: runloop-termination, runloop-event-cancellation, runloop-context, shutdown-drive-clear
        try expect("src/dosbox.cpp", contains: "if (!boxer_runLoopShouldContinue()) return 1;")
        try expectBlock("src/dosbox.cpp", marker: "runloop-context", contains: "boxer_runLoopWillStartWithContextInfo(&contextInfo);")
        try expectBlock("src/dosbox.cpp", marker: "runloop-context", contains: "boxer_runLoopDidFinishWithContextInfo(contextInfo);")
        try expect("src/dos/dos.cpp", contains: "for (Bit16u i = 0; i < DOS_DRIVES; i++)")
        try expect("src/dos/dos.cpp", contains: "Drives[i] = 0;")
    }

    func testBuildCompatibilityContracts() throws {
        // Protects BOXER markers: xcode-lazyflags-include, keyboard-enum-c-compat
        try expect("src/hardware/iohandler.cpp", contains: "#include \"../cpu/lazyflags.h\"")
        try expect("include/keyboard.h", contains: "typedef enum KBD_KEYS KBD_KEYS;")
    }

    func testConfigurationContracts() throws {
        // Protects BOXER markers: boxer-mt32-config-include, mt32-device-value, mt32-help-unconditional, mt32-midiconfig-help, mt32-config-section, dosbox-parport-init, parallel-config-section
        try expect("src/dosbox.cpp", contains: "#include \"BXMIDIConfig.hpp\"")
        try expect("src/dosbox.cpp", contains: "#include \"parport.h\"")
        try expect("src/dosbox.cpp", contains: "\"mt32\",")
        try expect("src/dosbox.cpp", contains: "'mt32', to use the built-in Roland MT-32 synthesizer.")
        try expect("src/dosbox.cpp", contains: "mididevice = fluidsynth or mt32")
        try expect("src/dosbox.cpp", contains: "BXMIDIMT32_AddConfigSection(control);")
        try expect("src/dosbox.cpp", contains: "parallel1")
        try expect("src/dosbox.cpp", contains: "parallel2")
        try expect("src/dosbox.cpp", contains: "parallel3")
    }

    func testMIDIRoutingContracts() throws {
        // Protects BOXER marker: midi-routing
        try expectBlock("src/midi/midi.cpp", marker: "midi-routing", contains: "#include \"BXCoalfaceAudio.h\"")
        try expectBlock("src/midi/midi.cpp", marker: "midi-routing", contains: "boxer_sendMIDIMessage(midi.rt_buf);")
        try expectBlock("src/midi/midi.cpp", marker: "midi-routing", contains: "boxer_sendMIDIMessage(midi.cmd_buf);")
        try expectBlock("src/midi/midi.cpp", marker: "midi-routing", contains: "boxer_sendMIDISysex(midi.sysex.buf, midi.sysex.used);")
        try expectBlock("src/midi/midi.cpp", marker: "midi-routing", contains: "DOSBox MIDI backends are intentionally disabled")
        try expect("src/midi/midi.cpp", contains: "boxer_suggestMIDIHandler(dev, fullconf.c_str());")
    }

    func testMixerVolumeBridgeContracts() throws {
        // Protects BOXER marker: mixer-volume-bridge
        try expectBlock("src/hardware/mixer.cpp", marker: "mixer-volume-bridge", contains: "#import \"BXCoalfaceAudio.h\"")
        try expectBlock("src/hardware/mixer.cpp", marker: "mixer-volume-bridge", contains: "boxer_masterVolume(BXLeftChannel)")
        try expectBlock("src/hardware/mixer.cpp", marker: "mixer-volume-bridge", contains: "boxer_masterVolume(BXRightChannel)")
        try expectBlock("src/hardware/mixer.cpp", marker: "mixer-volume-bridge", contains: "void boxer_updateVolumes()")
        try expectBlock("src/hardware/mixer.cpp", marker: "mixer-volume-bridge", contains: "it.second->UpdateVolume();")
        try expect("src/hardware/mixer.cpp", contains: "ShowVolume(\"MASTER\", boxer_masterVolume(BXLeftChannel), boxer_masterVolume(BXRightChannel));")
    }

    func testVideoRenderingContracts() throws {
        // Protects BOXER markers: render-reset-strategy, display-mode-controls, display-refresh-rate, capture-file-routing, core-mode-title-refresh
        try expectBlock("src/gui/render.cpp", marker: "render-reset-strategy", contains: "boxer_applyRenderingStrategy();")
        try expectBlock("src/hardware/vga_other.cpp", marker: "display-mode-controls", contains: "boxer_setHerculesTintMode")
        try expectBlock("src/hardware/vga_other.cpp", marker: "display-mode-controls", contains: "boxer_setCGACompositeHueOffset")
        try expectBlock("src/hardware/vga_other.cpp", marker: "display-mode-controls", contains: "boxer_setCGAComponentMode")
        try expectBlock("src/hardware/vga_other.cpp", marker: "display-refresh-rate", contains: "int boxer_GetDisplayRefreshRate(void)")
        try expectBlock("src/hardware/hardware.cpp", marker: "capture-file-routing", contains: "#if 0")
        try expect("src/dos/dos_execute.cpp", contains: "GFX_SetTitle(-1,-1,false);")
    }

    func testKeyboardContracts() throws {
        // Protects BOXER markers: keyboard-buffer-capacity, console-read-cancel, console-paste-availability, bios-key-paste-pop, bios-key-paste-peek, caps-lock-state, num-lock-state, scroll-lock-state, int16-cancel, keyboard-layout-switching-api, keyboard-cpi-buffer-storage, keyboard-layout-state-methods, keyboard-layout-bridge, macos-preferred-keyboard-layout, us-layout-remap-fix
        try expect("src/hardware/keyboard.cpp", contains: "Bitu boxer_keyboardBufferRemaining()")
        try expect("src/dos/dev_con.h", contains: "boxer_continueListeningForKeyEvents()")
        try expect("src/dos/dev_con.h", contains: "boxer_numKeyCodesInPasteBuffer()")
        try expect("src/ints/bios_keyboard.cpp", contains: "boxer_getNextKeyCodeInPasteBuffer(&code, true)")
        try expect("src/ints/bios_keyboard.cpp", contains: "boxer_getNextKeyCodeInPasteBuffer(&code, false)")
        try expect("src/ints/bios_keyboard.cpp", contains: "boxer_setCapsLockActive")
        try expect("src/ints/bios_keyboard.cpp", contains: "boxer_setNumLockActive")
        try expect("src/ints/bios_keyboard.cpp", contains: "boxer_setScrollLockActive")
        try expectBlock("src/dos/dos_keyboard_layout.cpp", marker: "keyboard-layout-bridge", contains: "boxer_keyboardLayoutName()")
        try expectBlock("src/dos/dos_keyboard_layout.cpp", marker: "keyboard-layout-bridge", contains: "boxer_setKeyboardLayoutActive")
        try expect("src/dos/dos_keyboard_layout.cpp", contains: "boxer_preferredKeyboardLayout()")
    }

    func testJoystickOwnershipContracts() throws {
        // Protects BOXER markers: gameport-timing-export, gameport-timing-state, mapper-free-autofire, gameport-poll-activation, gameport-timing-config, preserve-controller-ownership, dos-visible-joystick-state, joystick-handler-install-end
        try expect("include/joystick.h", contains: "extern bool gameport_timed;")
        try expect("src/hardware/joystick.cpp", contains: "bool gameport_timed")
        try expect("src/hardware/joystick.cpp", contains: "mapper-free-autofire")
        try expectBlock("src/hardware/joystick.cpp", marker: "gameport-poll-activation", contains: "boxer_setJoystickActive(true);")
        try expect("src/hardware/joystick.cpp", contains: "stick[0].is_visible_to_dos = is_visible;")
        try expect("src/hardware/joystick.cpp", contains: "stick[1].is_visible_to_dos = is_visible;")
        try expect("src/hardware/joystick.cpp", contains: "ReadHandler.Install(0x201, read_p201_switchable")
        try expect("src/hardware/joystick.cpp", contains: "WriteHandler.Install(0x201, write_p201_switchable")
    }

    func testGameboxDriveAndMediaContracts() throws {
        // Protects BOXER markers: drive-system-path, initialize-drive-system-path, retrieve-drive-system-path, fat-drive-system-path, iso-drive-system-path, local-drive-system-path, drive-cache-filter-bridge, hide-host-metadata, file-create-write-policy, file-open-write-policy, file-open-write-policy-end, file-delete-write-policy, local-dir-create-policy, local-file-created, local-file-removed, local-open-file-removed, imgmount-drive-mounted, mount-drive-mounted, drive-unmounted, invalid-fat-image-fails-construction, invalid-fat-bootsector-fails-construction, suppress-cdrom-image-error-text, file-unavailable-notification, local-file-unavailable-notification, local-file-unavailable, unavailable-file-read, unavailable-file-write, unavailable-file-seek, unavailable-file-timestamp
        try expectBlock("include/dos_system.h", marker: "drive-system-path", contains: "systempath")
        try expect("src/dos/drives.cpp", contains: "DOS_Drive::DOS_Drive()")
        try expect("src/dos/drives.cpp", contains: "char * DOS_Drive::getSystemPath(void)")
        try expect("src/dos/drive_cache.cpp", contains: "boxer_shouldShowFileWithName(name)")
        try expect("src/dos/drive_local.cpp", contains: "boxer_shouldAllowWriteAccessToPath")
        try expect("src/dos/drive_local.cpp", contains: "boxer_didCreateLocalFile")
        try expect("src/dos/drive_local.cpp", contains: "boxer_didRemoveLocalFile")
        try expectBlock("src/dos/drive_local.cpp", marker: "local-dir-create-policy", contains: "boxer_createLocalDir")
        try expect("src/dos/program_mount.cpp", contains: "boxer_driveDidMount")
        try expect("src/dos/program_imgmount.cpp", contains: "boxer_driveDidMount")
        try expect("src/dos/program_mount_common.cpp", contains: "boxer_driveDidUnmount")
        try expect("src/dos/drive_fat.cpp", contains: "created_successfully = false;")
        try expectBlock("src/dos/drive_local.cpp", marker: "local-file-unavailable", contains: "void localFile::willBecomeUnavailable()")
    }

    func testShellLifecycleContracts() throws {
        // Protects BOXER markers: current-shell-export, active-shell-global, shell-run-lifecycle, shell-misc-bridge, shell-input-injection, shell-command-filter, batch-lifecycle-bridge, batch-file-ended, program-launch-lifecycle
        try expect("include/shell.h", contains: "extern DOS_Shell * currentShell;")
        try expect("src/shell/shell.cpp", contains: "DOS_Shell *currentShell")
        try expectBlock("src/shell/shell.cpp", marker: "shell-run-lifecycle", contains: "boxer_shellWillStart(this);")
        try expectBlock("src/shell/shell.cpp", marker: "shell-run-lifecycle", contains: "boxer_executeNextPendingCommandForShell(this);")
        try expectBlock("src/shell/shell.cpp", marker: "shell-run-lifecycle", contains: "boxer_didReturnToShell(this);")
        try expectBlock("src/shell/shell.cpp", marker: "shell-run-lifecycle", contains: "boxer_shellDidFinish(this);")
        try expectBlock("src/shell/shell_misc.cpp", marker: "shell-input-injection", contains: "boxer_handleShellCommandInput")
        try expect("src/shell/shell_cmds.cpp", contains: "boxer_shellShouldRunCommand")
        try expect("src/shell/shell_batch.cpp", contains: "boxer_shellDidEndBatchFile")
        try expectBlock("src/shell/shell_misc.cpp", marker: "program-launch-lifecycle", contains: "boxer_shellWillExecuteFileAtDOSPath")
        try expectBlock("src/shell/shell_misc.cpp", marker: "program-launch-lifecycle", contains: "boxer_shellDidExecuteFileAtDOSPath")
    }

    func testShellCommandUXContracts() throws {
        // Protects BOXER markers: hide-intro-command, shell-command-ux, delete-help-if-no-args, delete-unix-path-tolerance, rename-help-if-no-args, mkdir-help-if-no-args, mkdir-unix-path-tolerance, rmdir-help-if-no-args, rmdir-unix-path-tolerance, dir-unix-path-trailing-slash, dir-unix-path-tolerance, copy-help-if-no-args, copy-unix-path-tolerance, if-help-if-no-args, type-help-if-no-args, call-help-if-no-args, subst-help-if-no-args, loadhigh-help-if-no-args, loadhigh-unix-path-tolerance
        try expect("src/dos/dos_programs.cpp", contains: "hide-intro-command")
        try expectBlock("src/shell/shell_cmds.cpp", marker: "shell-command-ux", contains: "#define HELP_IF_NO_ARGS(command)")
        for marker in ["delete-help-if-no-args", "delete-unix-path-tolerance", "rename-help-if-no-args",
                       "mkdir-help-if-no-args", "mkdir-unix-path-tolerance", "rmdir-help-if-no-args",
                       "rmdir-unix-path-tolerance", "dir-unix-path-trailing-slash", "dir-unix-path-tolerance",
                       "copy-help-if-no-args", "copy-unix-path-tolerance", "if-help-if-no-args",
                       "type-help-if-no-args", "call-help-if-no-args", "subst-help-if-no-args",
                       "loadhigh-help-if-no-args", "loadhigh-unix-path-tolerance"] {
            try expect("src/shell/shell_cmds.cpp", contains: marker)
        }
    }

    func testPrinterRoutingContracts() throws {
        // Protects BOXER markers: printer-redirection, parport-skip-occupied-lpt, bios-parport-include, int17-printer-emulation, bios-parport-detection-disabled, bios-equipment-parport-count, bios-refresh-parport-count, int21-printer-output
        try expectBlock("src/hardware/parport/printer_redir.cpp", marker: "printer-redirection", contains: "#import \"BXCoalface.h\"")
        try expectBlock("src/hardware/parport/printer_redir.cpp", marker: "printer-redirection", contains: "boxer_PRINTER_isInited")
        try expectBlock("src/hardware/parport/printer_redir.cpp", marker: "printer-redirection", contains: "boxer_PRINTER_writedata")
        try expect("src/hardware/parport/parport.cpp", contains: "parport-skip-occupied-lpt")
        try expect("src/ints/bios.cpp", contains: "parallelPortObjects[reg_dx]->Putchar(reg_al)")
        try expect("src/ints/bios.cpp", contains: "parallelPortObjects[reg_dx]->getPrinterStatus()")
        try expect("src/dos/dos.cpp", contains: "parallelPortObjects[i]->Putchar(reg_dl);")
    }

    func testLocalizationContracts() throws {
        // Protects BOXER markers: localization-routing, upstream-localization-disabled
        try expect("src/misc/messages.cpp", contains: "#include \"dosbox.h\"")
        try expectBlock("src/misc/messages.cpp", marker: "localization-routing", contains: "return boxer_localizedStringForKey(msg);")
        try expect("src/misc/messages.cpp", contains: "upstream-localization-disabled")
        try expect("src/misc/messages.cpp", contains: "const char *MSG_Get(char const *requested_name)")
    }

    func testRuntimeMixerVolumeBridgeBehavior() throws {
        // Protects BOXER marker: mixer-volume-bridge
        throw XCTSkip("Runtime mixer test requires a test target linked to DOSBox mixer.cpp with fake boxer_masterVolume hooks. Required behavior: active channel volume follows Boxer L/R master volume, recomputes existing channels, mutes/unmutes, and leaves no duplicate state after shutdown/reinitialize.")
    }

    func testRuntimeJoystickOwnershipBehavior() throws {
        // Protects BOXER markers: preserve-controller-ownership, gameport-poll-activation, dos-visible-joystick-state, joystick-handler-install-end
        throw XCTSkip("Runtime joystick test requires a test target linked to DOSBox joystick.cpp with fake boxer_setJoystickActive and IO handler inspection. Required behavior: one 0x201 path, first poll activates Boxer exactly once, repeated polls do not duplicate ownership, shutdown/reinitialize remains single-path.")
    }

    func testRuntimeMIDIRoutingBehavior() throws {
        // Protects BOXER marker: midi-routing
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerMIDIRuntimeHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let harnessSource = tempDirectory.appendingPathComponent("midi_harness.cpp")
        let harnessBinary = tempDirectory.appendingPathComponent("midi_harness")
        try midiHarnessSource().write(to: harnessSource, atomically: true, encoding: .utf8)

        let compileResult = try runProcess(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++",
                "-std=c++17",
                "-ffunction-sections",
                "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", dosboxRoot.appendingPathComponent("src/midi").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", dosboxRoot.appendingPathComponent("src/libs/ghc").path,
                harnessSource.path,
                "-Wl,-dead_strip",
                "-Wl,-undefined,dynamic_lookup",
                "-o", harnessBinary.path
            ]
        )
        XCTAssertEqual(compileResult.status, 0, compileResult.output)

        let runResult = try runProcess(executable: harnessBinary.path, arguments: [])
        XCTAssertEqual(runResult.status, 0, runResult.output)
        XCTAssertTrue(runResult.output.contains("midi runtime harness passed"), runResult.output)
    }

    func testRuntimeLifecycleBehavior() throws {
        // Protects BOXER markers: runloop-termination, runloop-event-cancellation, runloop-context, shutdown-drive-clear
        throw XCTSkip("Runtime lifecycle test requires a test target linked to DOSBox run-loop and DOS shutdown symbols with fake Boxer cancellation/context hooks. Required behavior: cancellation terminates, context callbacks balance, drives/callbacks clean up, and reinitialization does not duplicate state.")
    }

    func testRuntimeGameboxFilesystemBehavior() throws {
        // Protects BOXER markers: file-create-write-policy, file-open-write-policy, file-delete-write-policy, local-file-created, local-file-removed, mount-drive-mounted, drive-unmounted
        throw XCTSkip("Runtime filesystem test requires a DOSBox filesystem harness with fake Boxer file-policy callbacks and temporary drives. Required behavior: protected metadata is denied, allowed files create/delete, mount/unmount notifications fire, invalid images fail without half-mounted state.")
    }

    func testRuntimeKeyboardPasteAndCancellationBehavior() throws {
        // Protects BOXER markers: bios-key-paste-pop, bios-key-paste-peek, console-read-cancel, int16-cancel
        throw XCTSkip("Runtime keyboard test requires fake Boxer paste/cancellation hooks linked to BIOS keyboard and console code. Required behavior: pasted keys preserve order, peek/pop boundaries hold, full buffers stay coherent, and cancellation breaks blocking reads.")
    }

    func testRuntimeShellCallbackOrderingBehavior() throws {
        // Protects BOXER markers: shell-run-lifecycle, shell-input-injection, shell-command-filter, batch-lifecycle-bridge, program-launch-lifecycle
        throw XCTSkip("Runtime shell test requires fake Boxer shell callbacks linked to DOS_Shell. Required behavior: shell, injected command, batch, program launch/termination, prompt return, and shell finish callbacks occur once in order.")
    }

    func testRuntimePrinterRoutingBehavior() throws {
        // Protects BOXER markers: printer-redirection, int17-printer-emulation, int21-printer-output
        throw XCTSkip("Runtime printer test requires fake Boxer printer sinks linked to parport/printer code. Required behavior: DOS/LPT output reaches Boxer exactly once and status/equipment count remain coherent.")
    }

    private func documentedMarkerSet() -> Set<String> {
        Set(Self.documentedRows.flatMap(\.markers))
    }

    private func midiHarnessSource() -> String {
        """
        #include <chrono>
        #include <cstdint>
        #include <initializer_list>
        #include <iostream>
        #include <string>
        #include <vector>

        #include "types.h"
        extern uint8_t MIDI_evt_len[256];

        struct CapturedMessage {
            std::vector<uint8_t> bytes;
        };

        static std::vector<CapturedMessage> channel_messages;
        static std::vector<CapturedMessage> sysex_messages;

        Bitu CaptureState = 0;
        const std::chrono::steady_clock::time_point system_start_time = std::chrono::steady_clock::now();

        void CAPTURE_AddMidi(bool, Bitu, Bit8u *) {}

        void boxer_sendMIDIMessage(Bit8u *msg)
        {
            const auto len = MIDI_evt_len[msg[0]] ? MIDI_evt_len[msg[0]] : 1;
            channel_messages.push_back({std::vector<uint8_t>(msg, msg + len)});
        }

        void boxer_sendMIDISysex(Bit8u *msg, Bitu len)
        {
            sysex_messages.push_back({std::vector<uint8_t>(msg, msg + len)});
        }

        void boxer_suggestMIDIHandler(std::string const &, const char *) {}
        bool boxer_MIDIAvailable(void) { return true; }

        #include "\(dosboxRoot.appendingPathComponent("src/midi/midi.cpp").path)"

        static bool expect(const std::vector<uint8_t> &actual, std::initializer_list<uint8_t> expected)
        {
            return actual == std::vector<uint8_t>(expected);
        }

        int main()
        {
            channel_messages.clear();
            sysex_messages.clear();
            midi = {};

            MIDI_RawOutByte(0x90);
            MIDI_RawOutByte(0x40);
            MIDI_RawOutByte(0x7f);
            if (channel_messages.size() != 1 || !expect(channel_messages[0].bytes, {0x90, 0x40, 0x7f})) {
                std::cerr << "channel message delivery failed\\n";
                return 1;
            }

            MIDI_RawOutByte(0xf8);
            if (channel_messages.size() != 2 || !expect(channel_messages[1].bytes, {0xf8})) {
                std::cerr << "realtime message delivery failed\\n";
                return 2;
            }

            MIDI_RawOutByte(0xf0);
            MIDI_RawOutByte(0x7d);
            MIDI_RawOutByte(0x01);
            MIDI_RawOutByte(0x02);
            MIDI_RawOutByte(0xf7);
            if (sysex_messages.size() != 1 || !expect(sysex_messages[0].bytes, {0xf0, 0x7d, 0x01, 0x02, 0xf7})) {
                std::cerr << "sysex delivery failed\\n";
                return 3;
            }

            if (channel_messages.size() != 2) {
                std::cerr << "unexpected duplicate channel delivery\\n";
                return 4;
            }

            std::cout << "midi runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func runProcess(executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func sourceMarkerSet() throws -> Set<String> {
        let markerRegex = try NSRegularExpression(pattern: #"BOXER-(?:BEGIN|END|HOOK):\s*([a-z0-9-]+)"#)
        var markers = Set<String>()
        for root in [dosboxRoot.appendingPathComponent("include"), dosboxRoot.appendingPathComponent("src")] {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                XCTFail("Could not enumerate \(root.path)")
                continue
            }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
                    continue
                }
                let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
                for match in markerRegex.matches(in: contents, range: range) {
                    if let markerRange = Range(match.range(at: 1), in: contents) {
                        markers.insert(String(contents[markerRange]))
                    }
                }
            }
        }
        return markers
    }

    private func expect(_ relativePath: String, contains needle: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try expect(dosboxRoot.appendingPathComponent(relativePath), contains: needle, file: file, line: line)
    }

    private func expect(_ url: URL, contains needle: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains(needle), "\(url.path) missing: \(needle)", file: file, line: line)
    }

    private func expectBlock(_ relativePath: String, marker: String, contains needle: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = dosboxRoot.appendingPathComponent(relativePath)
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let begin = contents.range(of: "BOXER-BEGIN: \(marker)") else {
            XCTFail("\(url.path) missing begin marker \(marker)", file: file, line: line)
            return
        }
        guard let end = contents.range(of: "BOXER-END: \(marker)", range: begin.upperBound..<contents.endIndex) else {
            XCTFail("\(url.path) missing end marker \(marker)", file: file, line: line)
            return
        }
        let block = contents[begin.lowerBound..<end.upperBound]
        XCTAssertTrue(block.contains(needle), "\(url.path) marker \(marker) missing: \(needle)", file: file, line: line)
    }
}
