import Foundation
import XCTest

final class BoxerShellRuntimeTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var dosboxRoot: URL { projectRoot.appendingPathComponent("DOSBox-Staging") }

    // Production entry point: the exact DOS_Shell::Run implementation from
    // DOSBox-Staging/src/shell/shell.cpp.
    // Fakes: command-line parsing results, batch/input bodies, display output,
    // and Boxer callback sinks. Shell branch/order/loop ownership is production.
    func testProductionShellRunCallbackOrderingAndReuse() throws {
        let source = try String(
            contentsOf: dosboxRoot.appendingPathComponent("src/shell/shell.cpp"),
            encoding: .utf8
        )
        let runMethod = try sourceRegion(
            source,
            beginningWith: "void DOS_Shell::Run()",
            endingBefore: "void DOS_Shell::SyntaxError()"
        )

        let normal = try compileAndRun(runMethod: runMethod, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("shell runtime harness passed"), normal.output)

        for (needle, label) in [
            ("boxer_shellWillStart(this);", "remove-shell-start"),
            ("boxer_executeNextPendingCommandForShell(this);", "remove-pending-command"),
            ("boxer_didReturnToShell(this);", "remove-prompt-return"),
            ("boxer_shellDidFinish(this);", "remove-shell-finish"),
            ("boxer_shellWillStartAutoexec(this);", "remove-autoexec-start")
        ] {
            guard let range = runMethod.range(of: needle) else {
                XCTFail("Could not create shell mutation \(label)")
                continue
            }
            let mutated = runMethod.replacingCharacters(in: range, with: "/* mutation: \(label) */")
            let result = try compileAndRun(runMethod: mutated, label: label)
            XCTAssertNotEqual(result.status, 0, "Shell mutation \(label) unexpectedly passed")
        }

        let rerun = try compileAndRun(runMethod: runMethod, label: "normal-rerun")
        XCTAssertEqual(rerun.status, 0, rerun.output)
    }

    // Production entry point: the exact BatchFile::~BatchFile implementation
    // from src/shell/shell_batch.cpp. Fakes are only the owning shell and the
    // Boxer callback recorder.
    func testProductionBatchCompletionRestoresParentBeforeCallback() throws {
        let source = try String(contentsOf: dosboxRoot.appendingPathComponent("src/shell/shell_batch.cpp"), encoding: .utf8)
        let destructor = try sourceRegion(source, beginningWith: "BatchFile::~BatchFile()", endingBefore: "// TODO: Refactor")
        let normal = try compileBatchAndRun(destructor: destructor, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)

        guard let callback = destructor.range(of: "boxer_shellDidEndBatchFile(shell, filename.c_str());") else {
            return XCTFail("Could not create batch completion mutation")
        }
        let mutated = destructor.replacingCharacters(in: callback, with: "/* mutation: remove batch completion */")
        let mutation = try compileBatchAndRun(destructor: mutated, label: "remove-callback")
        XCTAssertNotEqual(mutation.status, 0, "Batch completion mutation unexpectedly passed")

        let rerun = try compileBatchAndRun(destructor: destructor, label: "normal-rerun")
        XCTAssertEqual(rerun.status, 0, rerun.output)
    }

    // Production entry point: the exact DOS_Shell::Execute implementation from
    // DOSBox-Staging/src/shell/shell_misc.cpp. Fakes: DOS path lookup and
    // canonicalization, batch construction, DOS process structures/registers,
    // interrupt dispatch, output, and Boxer callback sinks. Extension routing,
    // canonical-path selection, and callback/dispatch ordering are production.
    func testProductionExecutableCallbackOrderingAndRouting() throws {
        let source = try String(contentsOf: dosboxRoot.appendingPathComponent("src/shell/shell_misc.cpp"), encoding: .utf8)
        let execute = try sourceRegion(source, beginningWith: "bool DOS_Shell::Execute(char * name,char * args)", endingBefore: "static char which_ret")

        try assertExecutableHarnessPasses(execute, label: "normal")

        let start = "boxer_shellWillExecuteFileAtDOSPath(this, canonical_path, args);"
        let finish = "boxer_shellDidExecuteFileAtDOSPath(this, canonical_path);"
        for (needle, replacement, label) in [
            (start, "/* mutation: remove executable start */", "remove-start"),
            (finish, "/* mutation: remove executable finish */", "remove-finish"),
            (start, "\(start) \(start)", "duplicate-start"),
            (finish, "\(finish) \(finish)", "duplicate-finish"),
            (start, finish, "reverse-start"),
            (finish, start, "reverse-finish")
        ] {
            guard let range = execute.range(of: needle) else {
                XCTFail("Could not create executable mutation \(label)")
                continue
            }
            let mutated = execute.replacingCharacters(in: range, with: replacement)
            let result = try compileExecutableAndRun(execute: mutated, label: label)
            XCTAssertNotEqual(result.status, 0, "Executable mutation \(label) unexpectedly passed")
            try assertExecutableHarnessPasses(execute, label: "normal-after-\(label)")
        }
    }

    // Production entry point: the exact DOS_Shell::InputCommand implementation
    // from DOSBox-Staging/src/shell/shell_misc.cpp. Fakes: keyboard reads and
    // writes, completion/history filesystem services, DOS configuration, cursor
    // output, and Boxer callback sinks. The input loop and mutation retention,
    // immediate-execution, cancellation, and callback ordering are production.
    func testProductionCommandInputOrderingAndMutation() throws {
        let source = try String(contentsOf: dosboxRoot.appendingPathComponent("src/shell/shell_misc.cpp"), encoding: .utf8)
        let input = try sourceRegion(source, beginningWith: "void DOS_Shell::InputCommand(char * line)", endingBefore: "// BOXER-END: shell-input-injection")

        try assertInputHarnessPasses(input, label: "normal")
        for (needle, replacement, label) in [
            ("boxer_shellWillReadCommandInputFromHandle(this, input_handle);", "/* mutation: remove read-start */", "remove-read-start"),
            ("boxer_shellDidReadCommandInputFromHandle(this, input_handle);", "/* mutation: remove read-finish */", "remove-read-finish"),
            ("if (boxer_handleShellCommandInput(this, line, &str_index,", "if (false && boxer_handleShellCommandInput(this, line, &str_index,", "bypass-input-handler")
        ] {
            guard let range = input.range(of: needle) else {
                XCTFail("Could not create input mutation \(label)")
                continue
            }
            let mutated = input.replacingCharacters(in: range, with: replacement)
            let result = try compileInputAndRun(input: mutated, label: label)
            XCTAssertNotEqual(result.status, 0, "Input mutation \(label) unexpectedly passed")
            try assertInputHarnessPasses(input, label: "normal-after-\(label)")
        }
    }

    private func assertExecutableHarnessPasses(_ execute: String, label: String) throws {
        let result = try compileExecutableAndRun(execute: execute, label: label)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("executable runtime harness passed"), result.output)
    }

    private func assertInputHarnessPasses(_ input: String, label: String) throws {
        let result = try compileInputAndRun(input: input, label: label)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("input runtime harness passed"), result.output)
    }

    private func compileExecutableAndRun(execute: String, label: String) throws -> BoxerRuntimeProcessResult {
        try compileShellMiscHarness(source: executableHarness(execute: execute), prefix: "BoxerExecuteHarness", label: label)
    }

    private func compileInputAndRun(input: String, label: String) throws -> BoxerRuntimeProcessResult {
        try compileShellMiscHarness(source: inputHarness(input: input), prefix: "BoxerInputHarness", label: label)
    }

    private func compileShellMiscHarness(source: String, prefix: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("harness.cpp")
        let binaryURL = directory.appendingPathComponent("harness")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(executable: "/usr/bin/xcrun", arguments: ["clang++", "-std=c++17", sourceURL.path, "-o", binaryURL.path])
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binaryURL.path, arguments: [])
    }

    private func executableHarness(execute: String) -> String {
        """
        #include <algorithm>
        #include <cassert>
        #include <cctype>
        #include <cstdint>
        #include <cstdio>
        #include <cstring>
        #include <iostream>
        #include <memory>
        #include <string>
        #include <strings.h>
        #include <vector>
        #define CMD_MAXLINE 256
        #define DOS_PATHLENGTH 260
        #define IF 0
        using Bitu = unsigned int; using RealPt = uint32_t;
        static uint16_t reg_sp = 0x1000, reg_ax, reg_dx, reg_bx; static int ss, ds, es;
        static std::vector<std::string> events; static std::string start_path, finish_path;
        static void terminate_str_at(char *s, size_t i) { s[i] = 0; }
        static void reset_str(char *s) { s[0] = 0; }
        static size_t safe_strlen(const char *s) { return std::strlen(s); }
        static void safe_strcpy(char *d, const char *s) { std::strcpy(d, s ? s : ""); }
        template <typename... Args> static void safe_sprintf(char *d, const char *format, Args... args) { std::snprintf(d, DOS_PATHLENGTH + 4, format, args...); }
        template <typename T, typename U> static T check_cast(U value) { return static_cast<T>(value); }
        static int drive_index(char c) { return std::toupper(c) - 'A'; }
        static bool DOS_SetDrive(int) { return true; }
        static const char *MSG_Get(const char *) { return ""; }
        static uint32_t SegPhys(int) { return 0; }
        static RealPt RealMakeSeg(int, uint16_t offset) { return offset; }
        static RealPt RealMake(uint16_t segment, uint16_t offset) { return (segment << 16) | offset; }
        static uint32_t Real2Phys(RealPt value) { return value; }
        static uint16_t RealOff(RealPt value) { return value & 0xffff; }
        static int SegValue(int value) { return value; }
        static void SegSet16(int &, int) {}
        static void MEM_BlockWrite(uint32_t, const void *, Bitu) {}
        static void FCB_Parsename(uint16_t, int, int, const char *, uint8_t *add) { *add = 0; }
        static void SETFLAGBIT(int, bool) {}
        struct CommandTail { uint8_t count = 0; char buffer[127] = {}; };
        struct DOS_ParamBlock { struct { RealPt fcb1, fcb2, cmdtail; } exec{}; explicit DOS_ParamBlock(uint32_t) {} void Clear() {} void SaveData() {} };
        struct FakeDOS { uint16_t psp() const { return 0x50; } } dos;
        struct DOS_Shell;
        struct BatchFile { BatchFile(DOS_Shell *, const char *, const char *, const char *) { events.push_back("batch-dispatch"); } };
        static std::string full_arguments;
        struct DOS_Shell {
            bool echo = true, call = false; std::shared_ptr<BatchFile> bf;
            const char *Which(const char *name) const { return name; }
            void WriteOut(const char *, ...) {}
            bool Execute(char *, char *);
        };
        static void DOS_Canonicalize(const char *source, char *destination) { std::snprintf(destination, DOS_PATHLENGTH + 4, "C:\\\\CANON\\\\%s", source); }
        static void boxer_shellWillBeginBatchFile(DOS_Shell *, const char *path, const char *) { events.push_back(std::string("batch-start:") + path); }
        static void boxer_shellWillExecuteFileAtDOSPath(DOS_Shell *, const char *path, const char *) { start_path = path; events.push_back("start"); }
        static void boxer_shellDidExecuteFileAtDOSPath(DOS_Shell *, const char *path) { finish_path = path; events.push_back("finish"); }
        static void CALLBACK_RunRealInt(int) { events.push_back("dispatch"); }
        \(execute)
        static int executable_cycle(DOS_Shell &shell, const char *filename) {
            char name[64]; std::strcpy(name, filename); char args[] = " /X"; events.clear(); start_path.clear(); finish_path.clear();
            if (!shell.Execute(name, args)) return 10;
            if (events != std::vector<std::string>({"start", "dispatch", "finish"})) return 11;
            if (start_path != finish_path || start_path != std::string("C:\\\\CANON\\\\") + filename) return 12;
            return 0;
        }
        int main() {
            DOS_Shell shell;
            if (int result = executable_cycle(shell, "GAME.EXE")) return result;
            if (int result = executable_cycle(shell, "TOOL.COM")) return result + 10;
            char batch[] = "AUTOEXEC.BAT", args[] = ""; events.clear();
            if (!shell.Execute(batch, args) || events != std::vector<std::string>({"batch-start:C:\\\\CANON\\\\AUTOEXEC.BAT", "batch-dispatch"})) return 30;
            char unsupported[] = "README.TXT"; events.clear();
            if (shell.Execute(unsupported, args) || !events.empty()) return 31;
            if (int result = executable_cycle(shell, "GAME.EXE")) return result + 40;
            std::cout << "executable runtime harness passed\\n"; return 0;
        }
        """
    }

    private func inputHarness(input: String) -> String {
        """
        #include <algorithm>
        #include <cassert>
        #include <cstdint>
        #include <cstring>
        #include <iostream>
        #include <iterator>
        #include <list>
        #include <string>
        #include <strings.h>
        #include <vector>
        #define CMD_MAXLINE 256
        #define DOS_PATHLENGTH 260
        #define DOS_NAMELENGTH_ASCII 64
        #define DOS_ATTR_VOLUME 8
        #define DOS_ATTR_DIRECTORY 16
        #define STDOUT 1
        struct NullLog { void operator()(const char *, ...) const {} };
        #define LOG(a,b) NullLog{}
        #define LOG_MISC 0
        #define LOG_ERROR 0
        using Bitu = unsigned int; using RealPt = uint32_t;
        static bool shutdown_requested = false; static int scenario = 0, read_index = 0; static std::vector<int> events;
        static void reset_str(char *s) { s[0] = 0; }
        static void terminate_str_at(char *s, size_t i) { s[i] = 0; }
        static void safe_strcpy(char *d, const char *s) { std::strcpy(d, s); }
        static void safe_strncpy(char *d, const char *s, size_t n) { std::strncpy(d, s, n); d[n] = 0; }
        struct Section_prop { bool Get_bool(const char *) const { return false; } };
        struct Control { Section_prop section; void *GetSection(const char *) { return &section; } } control_value, *control = &control_value;
        struct FakeDOS { bool echo = true; struct { RealPt tempdta = 0; } tables; RealPt value = 0; RealPt dta() const { return value; } void dta(RealPt next) { value = next; } uint16_t psp() const { return 0; } } dos;
        struct DOS_DTA { explicit DOS_DTA(RealPt) {} void GetResult(char *name, uint32_t &size, uint16_t &date, uint16_t &time, uint8_t &attributes) { name[0] = 0; size = date = time = attributes = 0; } };
        static bool DOS_FindFirst(const char *, int) { return false; } static bool DOS_FindNext() { return false; }
        static bool is_executable_filename(const char *) { return false; }
        static bool DOS_ReadFile(uint16_t, uint8_t *c, uint16_t *n) { static const uint8_t normal[] = {'a', 13}; *c = scenario == 1 ? 13 : normal[std::min(read_index++, 1)]; *n = 1; return true; }
        static bool DOS_WriteFile(uint16_t, uint8_t *, uint16_t *) { return true; }
        static void DOS_CloseFile(uint16_t) {} static void DOS_OpenFile(const char *, int, uint16_t *) {}
        struct DOS_Shell {
            std::list<std::string> l_history, l_completion; uint16_t completion_index = 0, input_handle = 0;
            void InputCommand(char *); void ProcessCmdLineEnvVarStitution(char *) {}
        };
        static void outc(char) {} static void move_cursor_back_one() {}
        static bool boxer_continueListeningForKeyEvents() { return true; }
        static void boxer_shellWillReadCommandInputFromHandle(DOS_Shell *, uint16_t) { events.push_back(1); }
        static void boxer_shellDidReadCommandInputFromHandle(DOS_Shell *, uint16_t) { events.push_back(2); }
        static bool boxer_shellShouldContinue(DOS_Shell *) { return scenario != 2; }
        static bool boxer_handleShellCommandInput(DOS_Shell *, char *line, size_t *cursor, bool *immediate) {
            events.push_back(3);
            if (scenario == 1) { std::strcpy(line, "HELLO"); *cursor = 2; *immediate = true; return true; }
            if (scenario == 3 && read_index == 1) { std::strcpy(line, "HELLO"); *cursor = 2; return true; }
            return false;
        }
        \(input)
        static int run_case(DOS_Shell &shell, int selected, const char *expected, std::vector<int> expected_events) {
            scenario = selected; read_index = 0; shutdown_requested = false; events.clear(); char line[CMD_MAXLINE + 1] = "unchanged";
            shell.InputCommand(line);
            if (std::string(line) != expected) return 10 + selected;
            if (events != expected_events) return 20 + selected;
            return 0;
        }
        int main() {
            DOS_Shell shell;
            if (int result = run_case(shell, 0, "a", {1,2,3,1,2,3})) return result;
            if (int result = run_case(shell, 1, "HELLO", {1,2,3})) return result;
            if (int result = run_case(shell, 2, "", {1,2})) return result;
            if (int result = run_case(shell, 3, "HEaLLO", {1,2,3,1,2,3})) return result;
            if (int result = run_case(shell, 0, "a", {1,2,3,1,2,3})) return result + 30;
            std::cout << "input runtime harness passed\\n"; return 0;
        }
        """
    }

    private func compileBatchAndRun(destructor: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoxerBatchHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("batch.cpp")
        let binaryURL = directory.appendingPathComponent("batch")
        let harness = """
        #include <cassert>
        #include <iostream>
        #include <memory>
        #include <string>
        struct BatchFile;
        struct DOS_Shell { std::shared_ptr<BatchFile> bf; bool echo = false; };
        static int callbacks = 0;
        static bool restored_before_callback = false;
        struct BatchFile {
            std::unique_ptr<int> cmd;
            DOS_Shell *shell = nullptr;
            std::shared_ptr<BatchFile> prev;
            bool echo = false;
            std::string filename;
            ~BatchFile();
        };
        static void boxer_shellDidEndBatchFile(DOS_Shell *shell, const char *) {
            ++callbacks;
            restored_before_callback = !shell->bf && shell->echo;
        }
        \(destructor)
        static int cycle() {
            DOS_Shell shell;
            auto batch = std::make_shared<BatchFile>();
            batch->shell = &shell; batch->echo = true; batch->filename = "AUTOEXEC.BAT";
            shell.bf = batch;
            batch.reset();
            shell.bf.reset();
            return restored_before_callback ? 0 : 10;
        }
        int main() {
            if (cycle()) return 10;
            restored_before_callback = false;
            if (cycle()) return 11;
            if (callbacks != 2) return 12;
            std::cout << "batch runtime harness passed\\n";
            return 0;
        }
        """
        try harness.write(to: sourceURL, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(executable: "/usr/bin/xcrun", arguments: ["clang++", "-std=c++17", sourceURL.path, "-o", binaryURL.path])
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binaryURL.path, arguments: [])
    }

    private func sourceRegion(_ source: String, beginningWith start: String, endingBefore end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.lowerBound..<source.endIndex) else {
            throw NSError(
                domain: "BoxerShellRuntimeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate DOS_Shell::Run"]
            )
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func compileAndRun(runMethod: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerShellHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("shell-harness.cpp")
        let binaryURL = directory.appendingPathComponent("shell-harness")
        try harness(runMethod: runMethod).write(to: sourceURL, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["clang++", "-std=c++17", sourceURL.path, "-o", binaryURL.path]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binaryURL.path, arguments: [])
    }

    private func harness(runMethod: String) -> String {
        """
        #include <cstdarg>
        #include <cstdio>
        #include <cstring>
        #include <iostream>
        #include <memory>
        #include <string>
        #include <vector>

        #define C_DEBUG 0
        #define CMD_MAXLINE 256
        #define MCH_CGA 1
        #define MCH_HERC 2
        #define PRIMARY_MOD_NAME "DOSBox"
        #define PRIMARY_MOD_PAD "      "
        #define MMOD1_NAME "VGA"
        #define MMOD2_NAME "Hercules"

        enum class Verbosity { Quiet, InstantLaunch, Low, High };
        struct FakeConfig { Verbosity verbosity = Verbosity::Low; Verbosity GetStartupVerbosity() const { return verbosity; } };
        struct FakeCommandLine {
            int mode = 0;
            bool FindExist(const char *, bool) { return mode == 1; }
            bool FindStringRemainBegin(const char *, std::string &line) { if (mode != 2) return false; line = "command"; return true; }
            bool FindString(const char *, std::string &line, bool) { if (mode != 3) return false; line = "autoexec"; return true; }
        };
        struct FakeBatch { bool ReadLine(char *) { return false; } };
        struct DOS_Shell;

        static std::vector<int> events;
        static int scenario = 0;
        static bool pending = false;
        static int continuation_calls = 0;
        static bool shutdown_requested = false;
        static DOS_Shell *currentShell = nullptr;
        static FakeConfig config;
        static FakeConfig *control = &config;
        static int machine = 0;
        static bool mono_cga = false;

        struct DOS_Shell {
            FakeCommandLine command;
            FakeCommandLine *cmd = &command;
            std::shared_ptr<FakeBatch> bf;
            bool echo = false;
            bool exit_cmd_called = false;
            void WriteOut(const char *, ...) {}
            void WriteOut_NoParsing(const char *) {}
            void ShowPrompt() {}
            void ParseLine(char *) { events.push_back(7); }
            void RunInternal() { events.push_back(8); }
            void InputCommand(char *) { events.push_back(4); if (scenario != 2) exit_cmd_called = true; }
            void Run();
        };

        static const char *MSG_Get(const char *) { return ""; }
        static const char *DOSBOX_GetDetailedVersion() { return ""; }
        static void safe_strcpy(char *destination, const char *source) { std::strcpy(destination, source); }
        static void boxer_shellWillStart(DOS_Shell *) { events.push_back(1); }
        static void boxer_shellDidFinish(DOS_Shell *) { events.push_back(6); }
        static void boxer_shellWillStartAutoexec(DOS_Shell *) { events.push_back(2); }
        static bool boxer_shellShouldDisplayStartupMessages(DOS_Shell *) { return false; }
        static bool boxer_hasPendingCommandsForShell(DOS_Shell *) { return pending; }
        static void boxer_executeNextPendingCommandForShell(DOS_Shell *shell) { events.push_back(3); pending = false; shell->exit_cmd_called = true; }
        static void boxer_didReturnToShell(DOS_Shell *) { events.push_back(5); }
        static bool boxer_shellShouldContinue(DOS_Shell *) { return scenario != 2 && ++continuation_calls < 4; }

        \(runMethod)

        static int run_case(int selected, int command_mode, std::vector<int> expected)
        {
            scenario = selected;
            pending = selected == 1;
            continuation_calls = 0;
            shutdown_requested = false;
            events.clear();
            DOS_Shell parent;
            DOS_Shell shell;
            shell.command.mode = command_mode;
            currentShell = &parent;
            shell.Run();
            if (currentShell != &parent) return 20 + selected;
            if (events != expected) {
                std::cerr << "scenario " << selected << ":";
                for (const auto event : events) std::cerr << " " << event;
                std::cerr << "\\n";
                return 30 + selected;
            }
            return 0;
        }

        int main()
        {
            if (int result = run_case(0, 0, {1, 5, 4, 7, 6})) return result;
            if (int result = run_case(1, 0, {1, 3, 6})) return result;
            if (int result = run_case(2, 0, {1, 5, 4, 6})) return result;
            if (int result = run_case(3, 2, {1, 7, 8, 6})) return result;
            if (int result = run_case(4, 3, {1, 2, 7, 5, 4, 7, 6})) return result;
            if (int result = run_case(0, 0, {1, 5, 4, 7, 6})) return result + 50;
            std::cout << "shell runtime harness passed\\n";
            return 0;
        }
        """
    }
}
