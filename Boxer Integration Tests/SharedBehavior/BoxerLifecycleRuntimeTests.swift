import Foundation
import XCTest

@_silgen_name("BoxerRunProductionLifecycleHarness")
private func BoxerRunProductionLifecycleHarness() -> Int32

final class BoxerLifecycleRuntimeTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var dosboxRoot: URL { projectRoot.appendingPathComponent("DOSBox-Staging") }

    // Preserves BOXER markers: runloop-termination, runloop-event-cancellation,
    // runloop-context.
    //
    // Regression history:
    // - c27a3c91: cleanup after exceptional DOSBox termination
    // - dcaa4c60: background exception routing
    //
    // Production path:
    //   DOSBOX_SetLoop -> real DOSBOX_RunMachine -> Boxer context callbacks.
    //
    // Fakes:
    //   The CPU loop body and Boxer context sink. DOSBox's loop ownership and
    //   callback pairing are production code from src/dosbox.cpp.
    //
    // Versions:
    //   Shared lifecycle expectation through version adapters; instantiated
    //   here with DOSBox079Adapter.
    //
    // Mutation guards:
    //   Removing either context callback or either cancellation checkpoint
    //   must fail.
    func testProductionExceptionalCleanupAndReinitialization() {
        XCTAssertEqual(
            BoxerRunProductionLifecycleHarness(),
            0,
            "Real BXEmulator/DOSBox initialization did not cleanly shut down and reinitialize"
        )
    }

    func testRuntimeRunLoopContextAndSecondSessionBehavior() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let sourceURL = adapter.productionSources(for: .lifecycle)[0]
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let normal = try compileAndRun(source: source, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("lifecycle runtime harness passed"), normal.output)

        for (needle, label) in [
            ("boxer_runLoopWillStartWithContextInfo(&contextInfo);", "remove-will"),
            ("boxer_runLoopDidFinishWithContextInfo(contextInfo);", "remove-did")
        ] {
            guard let range = source.range(of: needle) else {
                XCTFail("Could not create lifecycle mutation \(label)")
                continue
            }
            let mutated = source.replacingCharacters(
                in: range,
                with: "/* mutation: \(label) */"
            )
            let result = try compileAndRun(source: mutated, label: label)
            XCTAssertNotEqual(result.status, 0, "Lifecycle mutation \(label) unexpectedly passed")
        }

        for (needle, replacement, label) in [
            (
                "if (!boxer_runLoopShouldContinue()) return 1;\n\n\t\tif (PIC_RunQueue())",
                "if (false) return 1;\n\n\t\tif (PIC_RunQueue())",
                "remove-entry-cancellation"
            ),
            (
                "if (!boxer_runLoopShouldContinue()) return 1;\n\t\t\tif (ticksRemain > 0)",
                "if (false) return 1;\n\t\t\tif (ticksRemain > 0)",
                "remove-event-cancellation"
            )
        ] {
            guard let range = source.range(of: needle) else {
                XCTFail("Could not create lifecycle mutation \(label)")
                continue
            }
            let mutated = source.replacingCharacters(in: range, with: replacement)
            let result = try compileAndRun(source: mutated, label: label)
            XCTAssertNotEqual(result.status, 0, "Lifecycle mutation \(label) unexpectedly passed")
        }
    }

    private func compileAndRun(source: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerLifecycleHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let productionSource = directory.appendingPathComponent("dosbox-production.cpp")
        let harnessSource = directory.appendingPathComponent("lifecycle-harness.cpp")
        let binary = directory.appendingPathComponent("lifecycle-harness")
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
                "-I", dosboxRoot.appendingPathComponent("src/libs").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", dosboxRoot.appendingPathComponent("subprojects/iir1-1.9.3").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path, "-Wl,-dead_strip", "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func harness(sourcePath: String) -> String {
        """
        #include <cstdarg>
        #include <cstdint>
        #include <cstdlib>
        #include <iostream>
        #include <vector>

        #include "dosbox.h"

        static std::vector<int> events;
        static int next_context = 0;
        static int loop_calls = 0;
        static int continuation_mode = 0;
        static int continuation_calls = 0;
        static int pic_calls = 0;
        static int event_calls = 0;

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        void boxer_runLoopWillStartWithContextInfo(void **context)
        {
            *context = reinterpret_cast<void *>(static_cast<intptr_t>(++next_context));
            events.push_back(next_context * 10 + 1);
        }

        void boxer_runLoopDidFinishWithContextInfo(void *context)
        {
            const auto value = static_cast<int>(reinterpret_cast<intptr_t>(context));
            events.push_back(value * 10 + 2);
        }

        bool boxer_runLoopShouldContinue()
        {
            ++continuation_calls;
            if (continuation_mode == 1)
                return false;
            if (continuation_mode == 2)
                return continuation_calls < 2;
            return true;
        }

        bool PIC_RunQueue() { ++pic_calls; return false; }
        bool GFX_Events() { ++event_calls; return true; }

        #include "\(sourcePath)"

        int32_t CPU_CycleMax = 0;
        int32_t CPU_CyclePercUsed = 0;
        int32_t CPU_CycleLimit = 0;
        int64_t CPU_IODelayRemoved = 0;
        bool CPU_CycleAutoAdjust = false;
        bool CPU_SkipCycleAutoAdjust = false;
        CPU_Decoder *cpudecoder = nullptr;
        CallBack_Handler CallBack_Handlers[CB_MAX] = {};
        const std::chrono::steady_clock::time_point system_start_time = std::chrono::steady_clock::now();
        void TIMER_AddTick() {}

        static Bitu controlled_loop()
        {
            ++loop_calls;
            return 1;
        }

        static int run_session()
        {
            events.clear();
            loop_calls = 0;
            shutdown_requested = false;
            DOSBOX_SetLoop(controlled_loop);
            DOSBOX_RunMachine();

            if (loop_calls != 1 || events.size() != 2)
                return 10;
            if (events[1] != events[0] + 1)
                return 11;
            return 0;
        }

        static int run_cancellation_checks()
        {
            continuation_mode = 1;
            continuation_calls = pic_calls = event_calls = 0;
            if (Normal_Loop() != 1 || continuation_calls != 1 || pic_calls != 0 || event_calls != 0)
                return 50;

            continuation_mode = 2;
            continuation_calls = pic_calls = event_calls = 0;
            if (Normal_Loop() != 1 || continuation_calls != 2 || pic_calls != 1 || event_calls != 1)
                return 51;
            continuation_mode = 0;
            return 0;
        }

        static int run_shutdown_and_reuse_check()
        {
            events.clear();
            loop_calls = 0;
            shutdown_requested = true;
            DOSBOX_SetLoop(controlled_loop);
            DOSBOX_RunMachine();
            if (loop_calls != 0 || !events.empty())
                return 52;
            return run_session();
        }

        int main()
        {
            if (const auto result = run_cancellation_checks())
                return result;
            if (const auto result = run_shutdown_and_reuse_check())
                return result;
            if (const auto result = run_session())
                return result;
            if (const auto result = run_session())
                return result + 20;
            if (next_context != 3)
                return 40;

            std::cout << "lifecycle runtime harness passed\\n";
            return 0;
        }
        """
    }
}
