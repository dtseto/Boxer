import Foundation
import XCTest

final class BoxerKeyboardRuntimeTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var dosboxRoot: URL { projectRoot.appendingPathComponent("DOSBox-Staging") }

    // Protected BOXER markers: bios-key-paste-pop, bios-key-paste-peek,
    // int16-cancel, caps-lock-state, num-lock-state, scroll-lock-state.
    // Behavioral invariant: peeking never consumes a pasted key, popping
    // consumes exactly one key in FIFO order, an empty paste buffer falls back
    // to the BIOS ring buffer, cancellation stops INT 16h immediately, and
    // each lock-key release reports the resulting state exactly once.
    // Historical migration references: fd6e3fb60, 4e359684f, 92281b3ee.
    // Real entry points: BIOS_AddKeyToBuffer and the production get_key,
    // check_key, and INT16_Handler paths invoked from this translation unit.
    // Real production source: src/ints/bios_keyboard.cpp.
    // Fake dependencies: Boxer paste/cancellation/lock sinks, emulated memory,
    // CPU registers, callback flags, and unused BIOS host services.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Required mutation failures: reversing the paste pop flag, removing the
    // INT 16h cancellation guard, or removing a lock callback must fail this
    // same expectation.
    func testRuntimeBIOSPastePeekPopFallbackAndCancellation() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let sourceURL = adapter.productionSources(for: .keyboard)[1]
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let normal = try compileAndRun(source: source, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("keyboard BIOS runtime harness passed"), normal.output)

        let reversedPop = try replacingFirst(
            "boxer_getNextKeyCodeInPasteBuffer(&code, true)",
            with: "boxer_getNextKeyCodeInPasteBuffer(&code, false)",
            in: source
        )
        let reversedResult = try compileAndRun(source: reversedPop, label: "reversed-pop")
        XCTAssertNotEqual(reversedResult.status, 0, "Reversed peek/pop mutation unexpectedly passed")

        let removedCancellation = try replacingFirst(
            "if (!boxer_continueListeningForKeyEvents())",
            with: "if (false)",
            in: source
        )
        let cancellationResult = try compileAndRun(
            source: removedCancellation,
            label: "removed-cancellation"
        )
        XCTAssertNotEqual(
            cancellationResult.status,
            0,
            "Removed INT 16h cancellation mutation unexpectedly passed"
        )

        let removedLockCallback = try replacingFirst(
            "boxer_setCapsLockActive(flags1 & 0x40);",
            with: "/* mutation: Caps Lock callback removed */",
            in: source
        )
        let lockResult = try compileAndRun(source: removedLockCallback, label: "removed-lock-callback")
        XCTAssertNotEqual(lockResult.status, 0, "Removed lock callback mutation unexpectedly passed")
    }

    // Protected BOXER marker: keyboard-buffer-capacity.
    // Behavioral invariant: reported capacity decreases exactly once per
    // accepted scancode, clamps at zero without overwriting queued data, and
    // returns to its initial value after the real production reset path.
    // Historical migration references: fd6e3fb60, 4e359684f, 92281b3ee.
    // Real entry points/source: boxer_keyboardBufferRemaining,
    // KEYBOARD_ClrBuffer, and the production enqueue path in
    // src/hardware/keyboard.cpp. Fake dependencies: PIC event scheduling and
    // logging. Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Mutation that must fail: an off-by-one capacity implementation.
    func testRuntimeKeyboardBufferCapacityAndResetBoundary() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let sourceURL = adapter.productionSources(for: .keyboard)[0]
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let normal = try compileAndRunKeyboardBuffer(source: source, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("keyboard buffer runtime harness passed"), normal.output)

        let mutation = try replacingFirst(
            "KEYBUFSIZE - keyb.used",
            with: "KEYBUFSIZE - keyb.used + 1",
            in: source
        )
        let mutationResult = try compileAndRunKeyboardBuffer(source: mutation, label: "off-by-one")
        XCTAssertNotEqual(mutationResult.status, 0, "Capacity off-by-one mutation unexpectedly passed")
    }

    // Protected BOXER marker: console-read-cancel.
    // Behavioral invariant: a cancelled blocking CON read returns false after
    // one INT 16h poll, restores AX, and leaves the caller's buffer and length
    // untouched. Historical references: fd6e3fb60, 4e359684f, 92281b3ee.
    // Real entry point/source: device_CON::Read in src/dos/dev_con.h.
    // Fake dependencies: INT 10 mode setup, INT 16 dispatch, Boxer
    // cancellation, CPU registers, and DOS globals. Supported adapter/version:
    // DOSBox079Adapter, v0.79.1 only. Mutation: removing the cancellation
    // branch must fail by allowing the controlled second poll to escape.
    func testRuntimeConsoleBlockingReadCancellation() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let sourceURL = adapter.productionSources(for: .keyboard)[2]
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let normal = try compileAndRunConsole(source: source, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("console cancellation runtime harness passed"), normal.output)

        let mutation = try replacingFirst(
            "if (!boxer_continueListeningForKeyEvents())",
            with: "if (false)",
            in: source
        )
        let result = try compileAndRunConsole(source: mutation, label: "removed-cancellation")
        XCTAssertEqual(
            result.status,
            61,
            "Removed console cancellation mutation did not reach the controlled second poll: \(result.output)"
        )
    }

    // Protected BOXER markers: keyboard-layout-switching-api,
    // keyboard-layout-state-methods, keyboard-layout-bridge,
    // macos-preferred-keyboard-layout.
    // Behavioral invariant: Boxer observes the real loaded layout name, can
    // toggle a non-US layout without changing identity,
    // cannot activate remapping for a US layout, and begins a second cycle with
    // no retained layout. Historical references: fd6e3fb60, 4e359684f,
    // 92281b3ee. Real entry points/source: DOS_KeyboardLayout_Init,
    // DOS_KeyboardLayout_ShutDown, boxer_keyboardLayoutName,
    // boxer_keyboardLayoutLoaded, boxer_keyboardLayoutSupported,
    // boxer_keyboardLayoutActive, and boxer_setKeyboardLayoutActive in
    // src/dos/dos_keyboard_layout.cpp. Fake dependencies: DOS globals and
    // logging; the fixture populates production KeyboardLayout state directly.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only. Mutations:
    // removing preferred-layout routing or SwitchForeignLayout must fail.
    func testRuntimeKeyboardLayoutBridgeStateAndSwitching() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let sourceURL = adapter.productionSources(for: .keyboard)[3]
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let normal = try compileAndRunLayout(source: source, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("keyboard layout runtime harness passed"), normal.output)

        let removedPreferredLayout = try replacingFirst(
            "if (const char *preferred_layout = boxer_preferredKeyboardLayout())",
            with: "if (const char *preferred_layout = nullptr)",
            in: source
        )
        let preferredResult = try compileAndRunLayout(
            source: removedPreferredLayout,
            label: "removed-preferred-layout"
        )
        XCTAssertEqual(
            preferredResult.status,
            9,
            "Removed preferred-layout routing did not fail behaviorally: \(preferredResult.output)"
        )

        let mutation = try replacingFirst(
            "if (boxer_keyboardLayoutActive() != active)\n\t\t\tloaded_layout->SwitchForeignLayout();",
            with: "if (boxer_keyboardLayoutActive() != active)\n\t\t\t/* mutation: layout switch removed */;",
            in: source
        )
        let result = try compileAndRunLayout(source: mutation, label: "removed-switch")
        XCTAssertEqual(result.status, 13, "Removed layout-switch mutation did not fail behaviorally: \(result.output)")
    }

    private func replacingFirst(_ needle: String, with replacement: String, in source: String) throws -> String {
        guard let range = source.range(of: needle) else {
            throw BoxerRuntimeHarnessError.launchFailed("Could not create keyboard mutation: \(needle)")
        }
        return source.replacingCharacters(in: range, with: replacement)
    }

    private func compileAndRun(source: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerKeyboardHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let productionSource = directory.appendingPathComponent("bios-keyboard-production.cpp")
        let harnessSource = directory.appendingPathComponent("bios-keyboard-harness.cpp")
        let binary = directory.appendingPathComponent("bios-keyboard-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try harness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)

        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-ffunction-sections", "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", dosboxRoot.appendingPathComponent("src/ints").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path,
                "-Wl,-dead_strip", "-Wl,-undefined,dynamic_lookup", "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunKeyboardBuffer(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerKeyboardBufferHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let productionSource = directory.appendingPathComponent("keyboard-production.cpp")
        let harnessSource = directory.appendingPathComponent("keyboard-buffer-harness.cpp")
        let binary = directory.appendingPathComponent("keyboard-buffer-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try keyboardBufferHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)

        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-ffunction-sections", "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", dosboxRoot.appendingPathComponent("subprojects/iir1-1.9.3").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path,
                "-Wl,-dead_strip", "-Wl,-undefined,dynamic_lookup", "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunConsole(source: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerConsoleHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let productionSource = directory.appendingPathComponent("dev-con-production.h")
        let harnessSource = directory.appendingPathComponent("console-harness.cpp")
        let binary = directory.appendingPathComponent("console-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try consoleHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)

        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-ffunction-sections", "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", dosboxRoot.appendingPathComponent("src/dos").path,
                "-I", dosboxRoot.appendingPathComponent("src/ints").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path,
                "-Wl,-dead_strip", "-Wl,-undefined,dynamic_lookup", "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunLayout(source: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerKeyboardLayoutHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let productionSource = directory.appendingPathComponent("keyboard-layout-production.cpp")
        let harnessSource = directory.appendingPathComponent("keyboard-layout-harness.cpp")
        let binary = directory.appendingPathComponent("keyboard-layout-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try layoutHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)

        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-ffunction-sections", "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", dosboxRoot.appendingPathComponent("src/dos").path,
                "-I", dosboxRoot.appendingPathComponent("src/ints").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", dosboxRoot.appendingPathComponent("src/libs/ghc").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path,
                "-Wl,-dead_strip", "-Wl,-undefined,dynamic_lookup", "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func layoutHarness(sourcePath: String) -> String {
        """
        #include "dos_keyboard_layout.h"
        #include <map>
        #include <memory>
        #include <string_view>
        #include "int10.h"
        #include "bios.h"
        #include "bios_disk.h"
        #include "callback.h"
        #include "dos_inc.h"
        #include "drives.h"
        #include "mapper.h"
        #include "math_utils.h"
        #include "regs.h"
        #include "setup.h"
        #include "string_utils.h"
        #include <cstring>
        #include <iostream>

        #define private public
        #include "\(sourcePath)"
        #undef private

        static int preferred_layout_calls = 0;
        static SectionFunction registered_destroy = nullptr;
        const char *boxer_preferredKeyboardLayout() {
            ++preferred_layout_calls;
            return "de";
        }
        bool DOS_MakeName(const char *const, char *const, uint8_t *) { return false; }
        std_fs::path GetResourcePath(const std_fs::path &, const std_fs::path &) { return {}; }
        const std::string &SETUP_GetLanguage() {
            static const std::string language = "en";
            return language;
        }
        void DOS_SetCountry(uint16_t) {}
        void Section::AddDestroyFunction(SectionFunction function, bool) {
            registered_destroy = function;
        }
        Section_prop::~Section_prop() {}
        const char *Section_prop::Get_string(const std::string &) const { return "auto"; }
        int Section_prop::Get_int(const std::string &) const { return 0; }
        std::string Section_prop::GetPropValue(const std::string &) const { return {}; }
        bool Section_prop::HandleInputline(const std::string &) { return false; }
        void Section_prop::PrintData(FILE *) const {}

        void DOS_Drive::SetDir(const char *) {}
        bool localDrive::FileOpen(DOS_File **, char *, uint32_t) { return false; }
        FILE *localDrive::GetSystemFilePtr(const char *const, const char *const) { return nullptr; }
        bool localDrive::GetSystemFilename(char *, const char *const) { return false; }
        bool localDrive::FileCreate(DOS_File **, char *, uint16_t) { return false; }
        bool localDrive::FileUnlink(char *) { return false; }
        bool localDrive::RemoveDir(char *) { return false; }
        bool localDrive::MakeDir(char *) { return false; }
        bool localDrive::TestDir(char *) { return false; }
        bool localDrive::FindFirst(char *, DOS_DTA &, bool) { return false; }
        bool localDrive::FindNext(DOS_DTA &) { return false; }
        bool localDrive::GetFileAttr(char *, uint16_t *) { return false; }
        bool localDrive::SetFileAttr(const char *, const uint16_t) { return false; }
        bool localDrive::Rename(char *, char *) { return false; }
        bool localDrive::AllocationInfo(uint16_t *, uint8_t *, uint16_t *, uint16_t *) { return false; }
        bool localDrive::FileExists(const char *) { return false; }
        bool localDrive::FileStat(const char *, FileStat_Block *const) { return false; }
        uint8_t localDrive::GetMediaByte() { return 0; }
        bool localDrive::isRemote() { return false; }
        bool localDrive::isRemovable() { return false; }
        Bits localDrive::UnMount() { return 0; }

        DOS_Block dos = {};
        DOS_Drive *Drives[DOS_DRIVES] = {};
        std::vector<VideoModeBlock>::const_iterator CurMode = {};
        uint8_t MemBase[1024 * 1024] = {};
        CPU_Regs cpu_regs = {};
        Segments Segs = {};
        uint32_t cpu_direction = 1;
        Int10Data int10 = {};
        MachineType machine = MCH_VGA;

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        static int run_cycle() {
            loaded_layout.reset();
            if (boxer_keyboardLayoutLoaded() || boxer_keyboardLayoutName() ||
                boxer_keyboardLayoutActive())
                return 10;

            preferred_layout_calls = 0;
            registered_destroy = nullptr;
            Section_prop section("dos");
            DOS_KeyboardLayout_Init(&section);
            if (preferred_layout_calls != 1)
                return 9;
            if (!registered_destroy || !KeyboardLayout)
                return 8;
            registered_destroy(&section);
            if (KeyboardLayout || boxer_keyboardLayoutLoaded())
                return 7;

            loaded_layout = std::make_unique<class KeyboardLayout>();
            std::strcpy(loaded_layout->current_keyboard_file_name, "de");
            dos.loaded_codepage = 437;

            if (!boxer_keyboardLayoutLoaded() ||
                !boxer_keyboardLayoutName() ||
                std::strcmp(boxer_keyboardLayoutName(), "de") != 0)
                return 11;
            boxer_setKeyboardLayoutActive(true);
            if (!boxer_keyboardLayoutActive())
                return 13;
            boxer_setKeyboardLayoutActive(false);
            if (boxer_keyboardLayoutActive())
                return 14;

            std::strcpy(loaded_layout->current_keyboard_file_name, "US");
            boxer_setKeyboardLayoutActive(true);
            if (boxer_keyboardLayoutActive())
                return 15;
            loaded_layout.reset();
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "keyboard layout runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func consoleHarness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <cstdlib>
        #include <cstring>
        #include <iostream>

        #include "dosbox.h"
        #include "bios.h"
        #include "callback.h"
        #include "dos_inc.h"
        #include "regs.h"

        CPU_Regs cpu_regs = {};
        Segments Segs = {};
        uint32_t cpu_direction = 1;
        MachineType machine = MCH_VGA;
        DOS_Block dos = {};
        static int interrupt_polls = 0;

        void INT10_SetCurMode() {}
        void CALLBACK_RunRealInt(uint8_t interrupt_number) {
            if (interrupt_number != 0x16)
                std::exit(60);
            if (++interrupt_polls > 1)
                std::exit(61);
            reg_ax = 0x1e61;
        }
        bool boxer_continueListeningForKeyEvents() { return false; }

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        #include "\(sourcePath)"

        static int run_cycle() {
            interrupt_polls = 0;
            reg_ax = 0xbeef;
            uint8_t data[4] = {0xaa, 0xbb, 0xcc, 0xdd};
            uint16_t size = 4;
            auto *storage = std::calloc(1, sizeof(device_CON));
            if (!storage)
                return 10;
            auto *console = reinterpret_cast<device_CON *>(storage);
            const auto result = console->device_CON::Read(data, &size);
            std::free(storage);
            if (result || interrupt_polls != 1)
                return 11;
            if (reg_ax != 0xbeef || size != 4)
                return 12;
            if (std::memcmp(data, "\\xaa\\xbb\\xcc\\xdd", 4) != 0)
                return 13;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "console cancellation runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func keyboardBufferHarness(sourcePath: String) -> String {
        """
        #include <cstdarg>
        #include <cstdint>
        #include <iostream>

        #include "dosbox.h"
        #include "pic.h"

        int32_t CPU_CycleLeft = 0;
        int32_t CPU_CycleMax = 1000;
        int32_t CPU_Cycles = 0;
        uint32_t PIC_Ticks = 0;
        MachineType machine = MCH_VGA;
        static int add_events = 0;
        static int remove_events = 0;

        void PIC_AddEvent(PIC_EventHandler, double, uint32_t) { ++add_events; }
        void PIC_RemoveEvents(PIC_EventHandler) { ++remove_events; }

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        #include "\(sourcePath)"

        static int run_cycle() {
            KEYBOARD_ClrBuffer();
            const auto capacity = boxer_keyboardBufferRemaining();
            if (capacity == 0)
                return 10;
            for (Bitu index = 0; index < capacity; ++index) {
                if (boxer_keyboardBufferRemaining() != capacity - index)
                    return 11;
                KEYBOARD_AddBuffer(static_cast<uint8_t>(index));
            }
            if (boxer_keyboardBufferRemaining() != 0)
                return 12;
            const auto events_at_capacity = add_events;
            KEYBOARD_AddBuffer(0xff);
            if (boxer_keyboardBufferRemaining() != 0 || add_events != events_at_capacity)
                return 13;
            KEYBOARD_ClrBuffer();
            if (boxer_keyboardBufferRemaining() != capacity)
                return 14;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            if (remove_events != 4)
                return 50;
            std::cout << "keyboard buffer runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func harness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <cstring>
        #include <iostream>
        #include <vector>

        #include "dosbox.h"
        #include "callback.h"
        #include "mem.h"
        #include "regs.h"

        uint8_t MemBase[1024 * 1024] = {};
        CPU_Regs cpu_regs = {};
        Segments Segs = {};
        uint32_t cpu_direction = 1;
        uint32_t cpu_cr0 = 0;
        MachineType machine = MCH_VGA;
        bool startup_state_numlock = false;
        bool startup_state_capslock = false;

        static std::vector<uint16_t> paste;
        static std::vector<bool> removal_requests;
        static bool continue_listening = true;
        static std::vector<bool> caps_events;
        static std::vector<bool> num_events;
        static std::vector<bool> scroll_events;

        uint8_t mem_readb(PhysPt address) { return MemBase[address]; }
        uint16_t mem_readw(PhysPt address) {
            return static_cast<uint16_t>(MemBase[address] | (MemBase[address + 1] << 8));
        }
        uint32_t mem_readd(PhysPt address) {
            return mem_readw(address) | (static_cast<uint32_t>(mem_readw(address + 2)) << 16);
        }
        void mem_writeb(PhysPt address, uint8_t value) { MemBase[address] = value; }
        void mem_writew(PhysPt address, uint16_t value) {
            MemBase[address] = static_cast<uint8_t>(value);
            MemBase[address + 1] = static_cast<uint8_t>(value >> 8);
        }
        void mem_writed(PhysPt address, uint32_t value) {
            mem_writew(address, static_cast<uint16_t>(value));
            mem_writew(address + 2, static_cast<uint16_t>(value >> 16));
        }

        bool boxer_getNextKeyCodeInPasteBuffer(uint16_t *code, bool remove) {
            removal_requests.push_back(remove);
            if (paste.empty())
                return false;
            *code = paste.front();
            if (remove)
                paste.erase(paste.begin());
            return true;
        }
        bool boxer_continueListeningForKeyEvents() { return continue_listening; }
        void boxer_setCapsLockActive(bool active) { caps_events.push_back(active); }
        void boxer_setNumLockActive(bool active) { num_events.push_back(active); }
        void boxer_setScrollLockActive(bool active) { scroll_events.push_back(active); }
        bool DOS_LayoutKey(const uint8_t, const uint8_t, const uint8_t, const uint8_t) {
            return false;
        }

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        #include "\(sourcePath)"

        static void reset_bios_buffer() {
            std::memset(MemBase, 0, sizeof(MemBase));
            mem_writew(BIOS_KEYBOARD_BUFFER_START, 0x1e);
            mem_writew(BIOS_KEYBOARD_BUFFER_END, 0x3e);
            mem_writew(BIOS_KEYBOARD_BUFFER_HEAD, 0x1e);
            mem_writew(BIOS_KEYBOARD_BUFFER_TAIL, 0x1e);
            paste.clear();
            removal_requests.clear();
            continue_listening = true;
            caps_events.clear();
            num_events.clear();
            scroll_events.clear();
            cpu_regs = {};
            cpu_regs.flags = 0;
        }

        static int run_cycle() {
            reset_bios_buffer();
            paste = {0x1e61, 0x3062};
            uint16_t code = 0;

            if (!check_key(code) || code != 0x1e61 || paste.size() != 2)
                return 10;
            if (!get_key(code))
                return 11;
            if (code != 0x1e61)
                return 12;
            if (paste.size() != 1)
                return 13;
            if (!get_key(code) || code != 0x3062 || !paste.empty())
                return 14;
            if (removal_requests != std::vector<bool>({false, true, true}))
                return 15;

            if (!BIOS_AddKeyToBuffer(0x2e63))
                return 16;
            if (!get_key(code) || code != 0x2e63)
                return 17;
            if (get_key(code))
                return 18;

            continue_listening = false;
            reg_ah = 0x00;
            if (INT16_Handler() != CBRET_STOP)
                return 19;

            for (const auto scancode : {0x3a, 0xba, 0x3a, 0xba,
                                        0x45, 0xc5, 0x45, 0xc5,
                                        0x46, 0xc6, 0x46, 0xc6}) {
                reg_al = static_cast<uint8_t>(scancode);
                if (IRQ1_Handler() != CBRET_NONE)
                    return 20;
            }
            if (caps_events != std::vector<bool>({true, false}))
                return 21;
            if (num_events != std::vector<bool>({true, false}))
                return 22;
            if (scroll_events != std::vector<bool>({true, false}))
                return 23;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "keyboard BIOS runtime harness passed\\n";
            return 0;
        }
        """
    }
}
