import Foundation
import XCTest

final class BoxerPrinterRuntimeTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var dosboxRoot: URL { projectRoot.appendingPathComponent("DOSBox-Staging") }

    // Protected BOXER marker: printer-redirection.
    // Behavioral invariant: the real redirected-printer backend routes one
    // output byte to Boxer exactly once, emits the required strobe sequence,
    // clears acknowledgement through one status read, and forwards data,
    // status, and control registers without retaining state across instances.
    // Historical migration references: fd6e3fb60, 4e359684f, 92281b3ee.
    // Real entry points: CPrinterRedir constructor, Putchar, Read_PR,
    // Read_COM, Read_SR, Write_PR, Write_CON, Write_IOSEL, and destructor.
    // Real production source: src/hardware/parport/printer_redir.cpp.
    // Fake dependencies: CParallel base methods and Boxer printer bridge
    // functions recording port, value, width, and ordered calls. A harness-only
    // type-token shim reconciles the production .cpp's signed event parameter
    // with the v0.79.1 header's unsigned declaration.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Required mutation failures: bypassing the Boxer data write or routing
    // the byte twice must fail this same expectation.
    func testRuntimePrinterRedirectionAndRegisterRouting() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let sourceURL = adapter.productionSources(for: .printer)[1]
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let normal = try compileAndRun(source: source, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("printer redirection runtime harness passed"), normal.output)

        let bypass = try replacingFirst(
            "boxer_PRINTER_writedata(0,val,1);",
            with: "/* mutation: Boxer printer data route bypassed */",
            in: source
        )
        let bypassResult = try compileAndRun(source: bypass, label: "bypass")
        XCTAssertEqual(bypassResult.status, 12, "Bypass mutation did not fail behaviorally: \(bypassResult.output)")

        let duplicate = try replacingFirst(
            "boxer_PRINTER_writedata(0,val,1);",
            with: "boxer_PRINTER_writedata(0,val,1); boxer_PRINTER_writedata(0,val,1);",
            in: source
        )
        let duplicateResult = try compileAndRun(source: duplicate, label: "duplicate")
        XCTAssertEqual(duplicateResult.status, 12, "Duplicate-routing mutation did not fail behaviorally: \(duplicateResult.output)")
    }

    // Protected BOXER markers: bios-parport-include,
    // int17-printer-emulation, bios-equipment-parport-count.
    // Behavioral invariant: BIOS INT 17h function 0 sends one character to
    // the selected real parallel-port object, reads status exactly once after
    // successful output, and performs neither operation for an absent port.
    // Historical references: fd6e3fb60, 4e359684f, 92281b3ee.
    // Real entry points/sources: INT17_Handler from src/ints/bios.cpp and
    // CParallel::getPrinterStatus from src/hardware/parport/parport.cpp.
    // Fake dependencies: CPU registers, logging, the parallel-port object
    // table, IO handle teardown, and a recording CParallel implementation.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Mutation that must fail: duplicating the real INT 17h Putchar call.
    func testRuntimeINT17PrinterOutputAndStatus() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let biosSource = try String(
            contentsOf: adapter.productionSources(for: .printer)[2],
            encoding: .utf8
        )
        let parportSource = try String(
            contentsOf: adapter.productionSources(for: .printer)[0],
            encoding: .utf8
        )
        let handler = try productionFunction(
            beginningWith: "static Bitu INT17_Handler(void)",
            in: biosSource
        )
        let status = try productionFunction(
            beginningWith: "uint8_t CParallel::getPrinterStatus()",
            in: parportSource
        )

        let normal = try compileAndRunINT17(handler: handler, status: status, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("INT 17h printer runtime harness passed"), normal.output)

        let duplicate = try replacingFirst(
            "parallelPortObjects[reg_dx]->Putchar(reg_al)",
            with: "(parallelPortObjects[reg_dx]->Putchar(reg_al) && parallelPortObjects[reg_dx]->Putchar(reg_al))",
            in: handler
        )
        let duplicateResult = try compileAndRunINT17(
            handler: duplicate,
            status: status,
            label: "duplicate"
        )
        XCTAssertEqual(
            duplicateResult.status,
            12,
            "Duplicate INT 17h routing did not fail behaviorally: \(duplicateResult.output)"
        )
    }

    // Protected BOXER marker: int21-printer-output.
    // Behavioral invariant: DOS INT 21h function 05 sends its byte once to the
    // first available parallel port, skips earlier absent ports, and produces
    // no output when no port exists. Historical references: fd6e3fb60,
    // 4e359684f, 92281b3ee. Real entry point/source: the DOS_21Handler function
    // 05 dispatch clause extracted verbatim from src/dos/dos.cpp at test time.
    // Fake dependencies: DOS/CPU
    // state, emulated memory, IO teardown, and recording parallel-port objects.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Mutations that must fail: bypassing or duplicating Putchar.
    func testRuntimeDOSPrinterOutputSelectsOnePort() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .printer)[3],
            encoding: .utf8
        )
        let handler = try productionFragment(
            beginningWith: "case 0x05:\t\t/* Write Character to PRINTER */",
            endingBefore: "case 0x06:\t\t/* Direct Console Output / Input */",
            in: source
        )
        let normal = try compileAndRunDOSPrinter(handler: handler, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("DOS printer runtime harness passed"), normal.output)

        let bypass = try replacingFirst(
            "parallelPortObjects[i]->Putchar(reg_dl);",
            with: "/* mutation: DOS printer output bypassed */",
            in: handler
        )
        let bypassResult = try compileAndRunDOSPrinter(handler: bypass, label: "bypass")
        XCTAssertEqual(bypassResult.status, 11, "DOS bypass mutation did not fail behaviorally: \(bypassResult.output)")

        let duplicate = try replacingFirst(
            "parallelPortObjects[i]->Putchar(reg_dl);",
            with: "parallelPortObjects[i]->Putchar(reg_dl); parallelPortObjects[i]->Putchar(reg_dl);",
            in: handler
        )
        let duplicateResult = try compileAndRunDOSPrinter(handler: duplicate, label: "duplicate")
        XCTAssertEqual(duplicateResult.status, 11, "DOS duplicate mutation did not fail behaviorally: \(duplicateResult.output)")
    }

    // Protected BOXER markers: bios-equipment-parport-count,
    // bios-refresh-parport-count. Behavioral invariant: registering and
    // removing real BIOS LPT entries updates their base addresses, timeout
    // bytes, and the equipment-word port count without disturbing unrelated
    // equipment bits. Historical references: fd6e3fb60, 4e359684f,
    // 92281b3ee. Real entry point/source: BIOS_SetLPTPort from
    // src/ints/bios.cpp. Fake dependency: isolated emulated BIOS memory.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Mutation that must fail: removing the equipment-count update.
    func testRuntimeBIOSParallelPortRegistrationCount() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .printer)[2],
            encoding: .utf8
        )
        let function = try productionFunction(
            beginningWith: "void BIOS_SetLPTPort(Bitu port, uint16_t baseaddr)",
            in: source
        )
        let normal = try compileAndRunBIOSRegistration(function: function, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("BIOS LPT registration runtime harness passed"), normal.output)

        let mutation = try replacingFirst(
            "equipmentword |= (portcount << 14);",
            with: "/* mutation: BIOS parallel-port count removed */",
            in: function
        )
        let mutationResult = try compileAndRunBIOSRegistration(
            function: mutation,
            label: "removed-count"
        )
        XCTAssertEqual(
            mutationResult.status,
            11,
            "Removed BIOS equipment-count mutation did not fail behaviorally: \(mutationResult.output)"
        )
    }

    // Protected BOXER marker: parport-skip-occupied-lpt.
    // Behavioral invariant: the real PARPORTS lifecycle never replaces a BIOS
    // LPT slot already owned by another device, destroys every backend it did
    // create, clears the global table, and begins a second initialization with
    // no retained objects. Historical references: 3eb5394a, 072b6c764,
    // 4e359684f, 92281b3ee. Real entry points/source: PARPORTS constructor and
    // destructor, PARALLEL_Init, PARALLEL_Destroy, and parallelPortObjects from
    // src/hardware/parport/parport.cpp. Fake dependencies: configured printer
    // backends, command parsing, Section registration, BIOS memory, and the
    // inert CParallel base. Supported adapter/version: DOSBox079Adapter,
    // v0.79.1 only. Mutations: bypassing occupied-port suppression or omitting
    // global-table clearing must fail.
    func testRuntimeParallelPortOccupiedSuppressionAndSecondSession() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .printer)[0],
            encoding: .utf8
        )
        let lifecycle = try parallelLifecycleSource(from: source)

        let normal = try compileAndRunParallelLifecycle(source: lifecycle, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("parallel lifecycle runtime harness passed"), normal.output)

        let bypass = try replacingFirst(
            "if (mem_readw(biosAddress) != 0)",
            with: "if (false)",
            in: lifecycle
        )
        let bypassResult = try compileAndRunParallelLifecycle(source: bypass, label: "occupied-bypass")
        XCTAssertEqual(bypassResult.status, 10, "Occupied-port bypass did not fail behaviorally: \(bypassResult.output)")

        let retained = try replacingLast(
            "parallelPortObjects[i] = 0;",
            with: "/* mutation: global parallel-port slot retained */",
            in: lifecycle
        )
        let retainedResult = try compileAndRunParallelLifecycle(source: retained, label: "retained-slot")
        XCTAssertEqual(retainedResult.status, 14, "Retained-slot mutation did not fail behaviorally: \(retainedResult.output)")
    }

    // Protected BOXER markers: parport-skip-occupied-lpt,
    // bios-equipment-parport-count. Behavioral invariant: the real CParallel
    // lifecycle installs exactly one byte-wide read and write handler for each
    // of its three registers, registers one BIOS LPT base and one DOS device,
    // and reverses BIOS/device ownership during teardown across two cycles.
    // Historical references: 3eb5394a, 072b6c764, 4e359684f, 92281b3ee.
    // Real entry points/source: CParallel constructor/destructor from
    // src/hardware/parport/parport.cpp. Fake dependencies: IO handler objects,
    // BIOS registration, DOS device registry, and an inert device_LPT body.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Mutation that must fail: removing one production read-handler install.
    func testRuntimeParallelHandlerInstallationAndTeardown() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .printer)[0],
            encoding: .utf8
        )
        let constructor = try productionFunction(
            beginningWith: "CParallel::CParallel(CommandLine* cmd, Bitu portnr, uint8_t initirq)",
            in: source
        )
        let destructor = try productionFunction(
            beginningWith: "CParallel::~CParallel(void)",
            in: source
        )
        let lifecycle = "\(constructor)\n\n\(destructor)"

        let normal = try compileAndRunParallelHandlers(source: lifecycle, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("parallel handler runtime harness passed"), normal.output)

        let mutation = try replacingFirst(
            "ReadHandler[i].Install (i + base, PARALLEL_Read, io_width_t::byte);",
            with: "/* mutation: parallel read-handler install removed */",
            in: lifecycle
        )
        let mutationResult = try compileAndRunParallelHandlers(
            source: mutation,
            label: "removed-read-handler"
        )
        XCTAssertEqual(
            mutationResult.status,
            10,
            "Removed parallel read-handler mutation did not fail behaviorally: \(mutationResult.output)"
        )
    }

    private func replacingFirst(_ needle: String, with replacement: String, in source: String) throws -> String {
        guard let range = source.range(of: needle) else {
            throw BoxerRuntimeHarnessError.launchFailed("Could not create printer mutation: \(needle)")
        }
        return source.replacingCharacters(in: range, with: replacement)
    }

    private func replacingLast(_ needle: String, with replacement: String, in source: String) throws -> String {
        guard let range = source.range(of: needle, options: .backwards) else {
            throw BoxerRuntimeHarnessError.launchFailed("Could not create printer mutation: \(needle)")
        }
        return source.replacingCharacters(in: range, with: replacement)
    }

    private func productionFunction(beginningWith signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else {
            throw BoxerRuntimeHarnessError.launchFailed("Could not find production function: \(signature)")
        }
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let end = source.index(after: cursor)
                    return String(source[signatureRange.lowerBound..<end])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        throw BoxerRuntimeHarnessError.launchFailed("Unbalanced production function: \(signature)")
    }

    private func productionFragment(
        beginningWith start: String,
        endingBefore end: String,
        in source: String
    ) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw BoxerRuntimeHarnessError.launchFailed("Could not find production fragment: \(start)")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func parallelLifecycleSource(from source: String) throws -> String {
        let type = try productionFunction(beginningWith: "class PARPORTS:public Module_base", in: source)
        let destroy = try productionFunction(beginningWith: "void PARALLEL_Destroy (Section * sec)", in: source)
        let initialize = try productionFunction(beginningWith: "void PARALLEL_Init (Section * sec)", in: source)
        return "\(type);\n\nstatic PARPORTS *testParallelPortsBaseclass;\n\n\(destroy)\n\n\(initialize)"
    }

    private func compileAndRunINT17(
        handler: String,
        status: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerINT17Harness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harnessSource = directory.appendingPathComponent("int17-harness.cpp")
        let binary = directory.appendingPathComponent("int17-harness")
        try int17Harness(handler: handler, status: status)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-ffunction-sections", "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path, "-Wl,-dead_strip", "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunDOSPrinter(
        handler: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerDOSPrinterHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harnessSource = directory.appendingPathComponent("dos-printer-harness.cpp")
        let binary = directory.appendingPathComponent("dos-printer-harness")
        try dosPrinterHarness(handler: handler)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-ffunction-sections", "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path, "-Wl,-dead_strip", "-Wl,-undefined,dynamic_lookup",
                "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunBIOSRegistration(
        function: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerBIOSLPTHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harnessSource = directory.appendingPathComponent("bios-lpt-harness.cpp")
        let binary = directory.appendingPathComponent("bios-lpt-harness")
        try biosRegistrationHarness(function: function)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path, "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunParallelLifecycle(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerParallelLifecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let productionSource = directory.appendingPathComponent("parallel-lifecycle-production.cpp")
        let harnessSource = directory.appendingPathComponent("parallel-lifecycle-harness.cpp")
        let binary = directory.appendingPathComponent("parallel-lifecycle-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try parallelLifecycleHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-DC_PRINTER=1",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path, "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunParallelHandlers(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerParallelHandlers-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let productionSource = directory.appendingPathComponent("parallel-handlers-production.cpp")
        let harnessSource = directory.appendingPathComponent("parallel-handlers-harness.cpp")
        let binary = directory.appendingPathComponent("parallel-handlers-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try parallelHandlerHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path, "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRun(source: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerPrinterHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let productionSource = directory.appendingPathComponent("printer-redir-production.cpp")
        let harnessSource = directory.appendingPathComponent("printer-redir-harness.cpp")
        let binary = directory.appendingPathComponent("printer-redir-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try harness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)

        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++", "-std=c++17", "-DC_PRINTER=1",
                "-ffunction-sections", "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", dosboxRoot.appendingPathComponent("src/hardware/parport").path,
                "-I", dosboxRoot.appendingPathComponent("submodules/loguru").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path,
                "-Wl,-dead_strip", "-o", binary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func harness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <iostream>
        #include <string>
        #include <vector>

        #include "dosbox.h"
        #include "parport.h"

        static std::vector<std::string> events;
        static bool initialized = true;

        IO_ReadHandleObject::~IO_ReadHandleObject() = default;
        IO_WriteHandleObject::~IO_WriteHandleObject() = default;
        CParallel::CParallel(CommandLine *, Bitu portnr, uint8_t initirq)
                : port_nr(portnr), base(0), irq(initirq), mydosdevice(nullptr) {}
        CParallel::~CParallel() = default;
        void CParallel::setEvent(uint16_t, float) {}
        void CParallel::removeEvent(uint16_t) {}
        void CParallel::handleEvent(uint16_t) {}
        void CParallel::Write_reserved(uint8_t, uint8_t) {}
        bool CParallel::Putchar_default(uint8_t) { return false; }
        uint8_t CParallel::getPrinterStatus() { return 0; }
        void CParallel::initialize() {}

        bool boxer_PRINTER_isInited(Bitu port) {
            events.push_back("init:" + std::to_string(port));
            return initialized;
        }
        Bitu boxer_PRINTER_readdata(Bitu port, Bitu width) {
            events.push_back("read-data:" + std::to_string(port) + ":" + std::to_string(width));
            return 0x31;
        }
        Bitu boxer_PRINTER_readcontrol(Bitu port, Bitu width) {
            events.push_back("read-control:" + std::to_string(port) + ":" + std::to_string(width));
            return 0x42;
        }
        Bitu boxer_PRINTER_readstatus(Bitu port, Bitu width) {
            events.push_back("read-status:" + std::to_string(port) + ":" + std::to_string(width));
            return 0x53;
        }
        void boxer_PRINTER_writedata(Bitu port, Bitu value, Bitu width) {
            events.push_back("write-data:" + std::to_string(port) + ":" +
                             std::to_string(value) + ":" + std::to_string(width));
        }
        void boxer_PRINTER_writecontrol(Bitu port, Bitu value, Bitu width) {
            events.push_back("write-control:" + std::to_string(port) + ":" +
                             std::to_string(value) + ":" + std::to_string(width));
        }

        #define int16_t uint16_t
        #include "\(sourcePath)"
        #undef int16_t

        static int run_cycle() {
            events.clear();
            initialized = true;
            CPrinterRedir printer(2, 7, nullptr);
            if (!printer.InstallationSuccessful ||
                events != std::vector<std::string>({"init:2"}))
                return 10;

            events.clear();
            if (!printer.Putchar(65))
                return 11;
            const std::vector<std::string> expected = {
                "write-control:0:212:1", "write-data:0:65:1",
                "write-control:0:213:1", "write-control:0:212:1",
                "read-status:0:1"
            };
            if (events != expected)
                return 12;

            events.clear();
            if (printer.Read_PR() != 0x31 || printer.Read_COM() != 0x42 ||
                printer.Read_SR() != 0x53)
                return 13;
            printer.Write_PR(0x64);
            printer.Write_CON(0x75);
            printer.Write_IOSEL(0x86);
            const std::vector<std::string> register_events = {
                "read-data:0:1", "read-control:0:1", "read-status:0:1",
                "write-data:0:100:1", "write-control:0:117:1"
            };
            if (events != register_events)
                return 14;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "printer redirection runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func int17Harness(handler: String, status: String) -> String {
        """
        #include <cstdint>
        #include <iostream>
        #include "dosbox.h"
        #include "callback.h"
        #include "parport.h"
        #include "regs.h"

        CPU_Regs cpu_regs = {};
        Segments Segs = {};
        uint32_t cpu_direction = 1;
        CParallel *parallelPortObjects[3] = {};

        IO_ReadHandleObject::~IO_ReadHandleObject() = default;
        IO_WriteHandleObject::~IO_WriteHandleObject() = default;
        CParallel::CParallel(CommandLine *, Bitu portnr, uint8_t initirq)
                : port_nr(portnr), base(0), irq(initirq), mydosdevice(nullptr) {}
        CParallel::~CParallel() = default;
        void CParallel::setEvent(uint16_t, float) {}
        void CParallel::removeEvent(uint16_t) {}
        void CParallel::handleEvent(uint16_t) {}
        void CParallel::Write_reserved(uint8_t, uint8_t) {}
        bool CParallel::Putchar_default(uint8_t) { return false; }
        void CParallel::initialize() {}

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        \(status)
        \(handler)

        class RecordingParallel final : public CParallel {
        public:
            RecordingParallel() : CParallel(nullptr, 0, 7) {}
            int writes = 0;
            int status_reads = 0;
            uint8_t last_byte = 0;
            bool Putchar(uint8_t value) override {
                ++writes;
                last_byte = value;
                return true;
            }
            Bitu Read_PR() override { return 0; }
            Bitu Read_COM() override { return 0; }
            Bitu Read_SR() override {
                ++status_reads;
                return 0x58;
            }
            void Write_PR(Bitu) override {}
            void Write_CON(Bitu) override {}
            void Write_IOSEL(Bitu) override {}
            void handleUpperEvent(uint16_t) override {}
        };

        static int run_cycle() {
            RecordingParallel printer;
            parallelPortObjects[0] = &printer;
            reg_ah = 0;
            reg_dx = 0;
            reg_al = 0x41;
            if (INT17_Handler() != CBRET_NONE)
                return 10;
            if (printer.last_byte != 0x41)
                return 11;
            if (printer.writes != 1 || printer.status_reads != 1)
                return 12;
            if (reg_ah != 0x10)
                return 13;

            parallelPortObjects[0] = nullptr;
            reg_ah = 0;
            reg_al = 0x42;
            if (INT17_Handler() != CBRET_NONE || printer.writes != 1 ||
                printer.status_reads != 1)
                return 14;
            parallelPortObjects[0] = nullptr;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "INT 17h printer runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func dosPrinterHarness(handler: String) -> String {
        """
        #include <cstdint>
        #include <cstring>
        #include <iostream>
        #include "dos_inc.h"
        #include "bios.h"
        #include "callback.h"
        #include "drives.h"
        #include "mem.h"
        #include "parport.h"
        #include "regs.h"
        #include "serialport.h"

        uint8_t MemBase[1024 * 1024] = {};
        CPU_Regs cpu_regs = {};
        Segments Segs = {};
        uint32_t cpu_direction = 1;
        DOS_Block dos = {};
        DOS_InfoBlock dos_infoblock = {};
        DOS_Drive *Drives[DOS_DRIVES] = {};
        CParallel *parallelPortObjects[3] = {};

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

        IO_ReadHandleObject::~IO_ReadHandleObject() = default;
        IO_WriteHandleObject::~IO_WriteHandleObject() = default;
        CParallel::CParallel(CommandLine *, Bitu portnr, uint8_t initirq)
                : port_nr(portnr), base(0), irq(initirq), mydosdevice(nullptr) {}
        CParallel::~CParallel() = default;
        void CParallel::setEvent(uint16_t, float) {}
        void CParallel::removeEvent(uint16_t) {}
        void CParallel::handleEvent(uint16_t) {}
        void CParallel::Write_reserved(uint8_t, uint8_t) {}
        bool CParallel::Putchar_default(uint8_t) { return false; }
        uint8_t CParallel::getPrinterStatus() { return 0; }
        void CParallel::initialize() {}

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        static Bitu DOS_21Handler(void) {
            switch (reg_ah) {
            \(handler)
            default: break;
            }
            return CBRET_NONE;
        }

        class RecordingParallel final : public CParallel {
        public:
            RecordingParallel(Bitu port) : CParallel(nullptr, port, 7) {}
            int writes = 0;
            uint8_t last_byte = 0;
            bool Putchar(uint8_t value) override {
                ++writes;
                last_byte = value;
                return true;
            }
            Bitu Read_PR() override { return 0; }
            Bitu Read_COM() override { return 0; }
            Bitu Read_SR() override { return 0; }
            void Write_PR(Bitu) override {}
            void Write_CON(Bitu) override {}
            void Write_IOSEL(Bitu) override {}
            void handleUpperEvent(uint16_t) override {}
        };

        static int run_cycle() {
            std::memset(MemBase, 0, sizeof(MemBase));
            cpu_regs = {};
            Segs = {};
            RecordingParallel first(0);
            RecordingParallel second(1);
            parallelPortObjects[0] = nullptr;
            parallelPortObjects[1] = &second;
            parallelPortObjects[2] = &first;
            reg_ah = 0x05;
            reg_dl = 0x51;
            if (DOS_21Handler() != CBRET_NONE)
                return 10;
            if (second.writes != 1 || second.last_byte != 0x51 || first.writes != 0)
                return 11;

            parallelPortObjects[0] = nullptr;
            parallelPortObjects[1] = nullptr;
            parallelPortObjects[2] = nullptr;
            reg_ah = 0x05;
            reg_dl = 0x52;
            if (DOS_21Handler() != CBRET_NONE || second.writes != 1 || first.writes != 0)
                return 12;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "DOS printer runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func biosRegistrationHarness(function: String) -> String {
        """
        #include <cstdint>
        #include <cstring>
        #include <iostream>
        #include "dosbox.h"
        #include "bios.h"
        #include "mem.h"

        uint8_t MemBase[1024 * 1024] = {};
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

        \(function)

        static int run_cycle() {
            std::memset(MemBase, 0, sizeof(MemBase));
            mem_writew(BIOS_CONFIGURATION, 0x1234);

            BIOS_SetLPTPort(0, 0x378);
            if (mem_readw(BIOS_ADDRESS_LPT1) != 0x378 ||
                mem_readb(BIOS_LPT1_TIMEOUT) != 10)
                return 10;
            if ((mem_readw(BIOS_CONFIGURATION) & 0xc000) != 0x4000 ||
                (mem_readw(BIOS_CONFIGURATION) & 0x3fff) != 0x1234)
                return 11;

            BIOS_SetLPTPort(1, 0x278);
            if (mem_readw(BIOS_ADDRESS_LPT2) != 0x278 ||
                mem_readb(BIOS_LPT2_TIMEOUT) != 10 ||
                (mem_readw(BIOS_CONFIGURATION) & 0xc000) != 0x8000)
                return 12;

            BIOS_SetLPTPort(0, 0);
            if (mem_readw(BIOS_ADDRESS_LPT1) != 0 ||
                (mem_readw(BIOS_CONFIGURATION) & 0xc000) != 0x4000)
                return 13;
            BIOS_SetLPTPort(1, 0);
            if (mem_readw(BIOS_ADDRESS_LPT2) != 0 ||
                (mem_readw(BIOS_CONFIGURATION) & 0xc000) != 0)
                return 14;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "BIOS LPT registration runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func parallelLifecycleHarness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <cstdlib>
        #include <iostream>
        #include <string>
        #include <vector>
        #include "dosbox.h"
        #include "bios.h"
        #include "mem.h"
        #include "parport.h"
        #include "setup.h"

        uint8_t MemBase[1024 * 1024] = {};
        static std::vector<int> created_ports;
        static std::vector<int> destroyed_ports;
        static SectionFunction registered_destroy = nullptr;
        CParallel *parallelPortObjects[3] = {};

        uint8_t mem_readb(PhysPt address) { return MemBase[address]; }
        uint16_t mem_readw(PhysPt address) {
            return static_cast<uint16_t>(MemBase[address] | (MemBase[address + 1] << 8));
        }
        uint32_t mem_readd(PhysPt address) { return mem_readw(address); }
        void mem_writeb(PhysPt address, uint8_t value) { MemBase[address] = value; }
        void mem_writew(PhysPt address, uint16_t value) {
            MemBase[address] = static_cast<uint8_t>(value);
            MemBase[address + 1] = static_cast<uint8_t>(value >> 8);
        }
        void mem_writed(PhysPt address, uint32_t value) {
            mem_writew(address, static_cast<uint16_t>(value));
        }

        IO_ReadHandleObject::~IO_ReadHandleObject() = default;
        IO_WriteHandleObject::~IO_WriteHandleObject() = default;
        CParallel::CParallel(CommandLine *, Bitu portnr, uint8_t initirq)
                : port_nr(portnr), base(0), irq(initirq), mydosdevice(nullptr) {}
        CParallel::~CParallel() = default;
        void CParallel::setEvent(uint16_t, float) {}
        void CParallel::removeEvent(uint16_t) {}
        void CParallel::handleEvent(uint16_t) {}
        void CParallel::Write_reserved(uint8_t, uint8_t) {}
        bool CParallel::Putchar_default(uint8_t) { return false; }
        uint8_t CParallel::getPrinterStatus() { return 0; }
        void CParallel::initialize() {}

        class CPrinterRedir final : public CParallel {
        public:
            CPrinterRedir(Bitu port, uint8_t irq, CommandLine *cmd)
                    : CParallel(cmd, port, irq), InstallationSuccessful(true) {
                created_ports.push_back(static_cast<int>(port));
            }
            ~CPrinterRedir() override { destroyed_ports.push_back(static_cast<int>(port_nr)); }
            bool InstallationSuccessful;
            Bitu Read_PR() override { return 0; }
            Bitu Read_COM() override { return 0; }
            Bitu Read_SR() override { return 0; }
            void Write_PR(Bitu) override {}
            void Write_CON(Bitu) override {}
            void Write_IOSEL(Bitu) override {}
            bool Putchar(uint8_t) override { return true; }
            void handleUpperEvent(uint16_t) override {}
        };

        class CFileLPT final : public CParallel {
        public:
            CFileLPT(Bitu port, uint8_t irq, CommandLine *cmd)
                    : CParallel(cmd, port, irq), InstallationSuccessful(false) {}
            bool InstallationSuccessful;
            Bitu Read_PR() override { return 0; }
            Bitu Read_COM() override { return 0; }
            Bitu Read_SR() override { return 0; }
            void Write_PR(Bitu) override {}
            void Write_CON(Bitu) override {}
            void Write_IOSEL(Bitu) override {}
            bool Putchar(uint8_t) override { return false; }
            void handleUpperEvent(uint16_t) override {}
        };

        CommandLine::CommandLine(const char *, const char *) {}
        bool CommandLine::FindCommand(unsigned int, std::string &value) {
            value = "printer";
            return true;
        }
        void Section::AddDestroyFunction(SectionFunction function, bool) {
            registered_destroy = function;
        }
        Section_prop::~Section_prop() {}
        const char *Section_prop::Get_string(const std::string &) const { return "printer"; }
        std::string Section_prop::GetPropValue(const std::string &) const { return {}; }
        bool Section_prop::HandleInputline(const std::string &) { return false; }
        void Section_prop::PrintData(FILE *) const {}

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        #include "\(sourcePath)"

        static int verify_slots(bool expect_live) {
            if (parallelPortObjects[0] != nullptr)
                return 11;
            if (expect_live && (!parallelPortObjects[1] || !parallelPortObjects[2]))
                return 12;
            if (!expect_live && (parallelPortObjects[1] || parallelPortObjects[2]))
                return 14;
            return 0;
        }

        int main() {
            mem_writew(BIOS_ADDRESS_LPT1, 0x3bc);
            Section_prop section("parallel");
            PARALLEL_Init(&section);
            if (!registered_destroy || created_ports != std::vector<int>({1, 2}))
                return 10;
            if (const auto result = verify_slots(true))
                return result;

            PARALLEL_Init(&section);
            if (destroyed_ports != std::vector<int>({1, 2}) ||
                created_ports != std::vector<int>({1, 2, 1, 2}))
                return 13;
            if (const auto result = verify_slots(true))
                return result;

            registered_destroy(&section);
            if (destroyed_ports != std::vector<int>({1, 2, 1, 2}))
                return 15;
            if (const auto result = verify_slots(false))
                return result;
            std::cout << "parallel lifecycle runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func parallelHandlerHarness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <iostream>
        #include <vector>
        #include "dosbox.h"
        #include "parport.h"

        struct InstallEvent {
            bool read;
            io_port_t port;
            io_width_t width;
        };
        static std::vector<InstallEvent> installs;
        static std::vector<uint16_t> bios_bases;
        static int devices_added = 0;
        static int devices_removed = 0;
        static int read_destructors = 0;
        static int write_destructors = 0;

        static io_val_t PARALLEL_Read(io_port_t, io_width_t) { return 0xff; }
        static void PARALLEL_Write(io_port_t, io_val_t, io_width_t) {}

        void IO_ReadHandleObject::Install(io_port_t port, io_read_f, io_width_t width, io_port_t) {
            installs.push_back({true, port, width});
        }
        void IO_WriteHandleObject::Install(io_port_t port, io_write_f, io_width_t width, io_port_t) {
            installs.push_back({false, port, width});
        }
        void IO_ReadHandleObject::Uninstall() {}
        void IO_WriteHandleObject::Uninstall() {}
        IO_ReadHandleObject::~IO_ReadHandleObject() { ++read_destructors; }
        IO_WriteHandleObject::~IO_WriteHandleObject() { ++write_destructors; }

        bool DOS_Device::Read(uint8_t *, uint16_t *) { return false; }
        bool DOS_Device::Write(uint8_t *, uint16_t *) { return false; }
        bool DOS_Device::Seek(uint32_t *, uint32_t) { return false; }
        bool DOS_Device::Close() { return false; }
        uint16_t DOS_Device::GetInformation() { return 0; }
        bool DOS_Device::ReadFromControlChannel(PhysPt, uint16_t, uint16_t *) { return false; }
        bool DOS_Device::WriteToControlChannel(PhysPt, uint16_t, uint16_t *) { return false; }
        uint8_t DOS_Device::GetStatus(bool) { return 0; }
        device_LPT::device_LPT(uint8_t number, CParallel *port) {
            num = number;
            pportclass = port;
        }
        device_LPT::~device_LPT() = default;
        bool device_LPT::Read(uint8_t *, uint16_t *size) { *size = 0; return true; }
        bool device_LPT::Write(uint8_t *, uint16_t *) { return true; }
        bool device_LPT::Seek(uint32_t *position, uint32_t) { *position = 0; return true; }
        bool device_LPT::Close() { return false; }
        uint16_t device_LPT::GetInformation() { return 0x80a0; }
        void BIOS_SetLPTPort(Bitu, uint16_t base) { bios_bases.push_back(base); }
        void DOS_AddDevice(DOS_Device *) { ++devices_added; }
        void DOS_DelDevice(DOS_Device *) { ++devices_removed; }

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        #include "\(sourcePath)"

        class RecordingParallel final : public CParallel {
        public:
            RecordingParallel(Bitu port, uint8_t irq) : CParallel(nullptr, port, irq) {}
            Bitu Read_PR() override { return 0; }
            Bitu Read_COM() override { return 0; }
            Bitu Read_SR() override { return 0; }
            void Write_PR(Bitu) override {}
            void Write_CON(Bitu) override {}
            void Write_IOSEL(Bitu) override {}
            bool Putchar(uint8_t) override { return true; }
            void handleUpperEvent(uint16_t) override {}
        };

        static int run_cycle(Bitu port) {
            const auto installs_before = installs.size();
            const auto added_before = devices_added;
            const auto removed_before = devices_removed;
            {
                RecordingParallel printer(port, 7);
                if (installs.size() != installs_before + 6)
                    return 10;
                for (size_t index = 0; index < 6; ++index) {
                    const auto &event = installs[installs_before + index];
                    const auto expected_offset = static_cast<io_port_t>(index / 2);
                    if (event.port != parallel_baseaddr[port] + expected_offset ||
                        event.width != io_width_t::byte || event.read != ((index % 2) == 1))
                        return 11;
                }
                if (devices_added != added_before + 1 ||
                    bios_bases.back() != parallel_baseaddr[port])
                    return 12;
            }
            if (devices_removed != removed_before + 1 || bios_bases.back() != 0)
                return 13;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle(0))
                return result;
            if (const auto result = run_cycle(1))
                return result + 20;
            if (read_destructors != 6 || write_destructors != 6)
                return 40;
            std::cout << "parallel handler runtime harness passed\\n";
            return 0;
        }
        """
    }
}
