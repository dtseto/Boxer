import Foundation
import XCTest

final class BoxerJoystickRuntimeTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var dosboxRoot: URL {
        projectRoot.appendingPathComponent("DOSBox-Staging")
    }

    // Preserves BOXER markers: gameport-poll-activation,
    // preserve-controller-ownership, dos-visible-joystick-state,
    // gameport-timing-config, joystick-handler-install-end.
    //
    // Regression history:
    // - 3eb5394a / 072b6c764: duplicate port 0x201 registration
    // - 5152357a7: safe destroy and reinitialization
    //
    // Production path:
    //   real JOYSTICK_Init -> real switchable 0x201 handlers ->
    //   boxer_setJoystickActive -> real JOYSTICK_Destroy
    //
    // Fakes:
    //   Boxer activation sink, configuration provider, PIC timing, and the
    //   I/O registry boundary. Registration fakes retain and invoke the real
    //   production handlers.
    //
    // Versions:
    //   Shared expectation for Boxer-integrated v0.79.1, v0.80.0, and v0.80.1
    //   through version adapters. This file currently instantiates DOSBox079.
    //
    // Mutation guard:
    //   Removing the activation callback or duplicating either Install call
    //   must make the same shared expectation fail.
    func testRuntimeJoystickOwnershipBehavior() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .joystick)[0],
            encoding: .utf8
        )

        let normal = try compileAndRun(source: source, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("joystick runtime harness passed"), normal.output)

        let callbackMutation = source.replacingOccurrences(
            of: "boxer_setJoystickActive(true);",
            with: "/* mutation: activation callback removed */",
            options: [],
            range: source.range(of: "boxer_setJoystickActive(true);")
        )
        XCTAssertNotEqual(callbackMutation, source)
        let callbackResult = try compileAndRun(source: callbackMutation, label: "removed-callback")
        XCTAssertNotEqual(callbackResult.status, 0, "Removing activation unexpectedly passed")

        guard let installRange = source.range(
            of: "ReadHandler.Install(0x201, read_p201_switchable, io_width_t::byte);"
        ) else {
            XCTFail("Could not create duplicate-registration mutation")
            return
        }
        let installLine = String(source[installRange])
        let duplicateMutation = source.replacingCharacters(
            in: installRange,
            with: installLine + "\n            " + installLine
        )
        let duplicateResult = try compileAndRun(source: duplicateMutation, label: "duplicate-install")
        XCTAssertNotEqual(duplicateResult.status, 0, "Duplicate 0x201 registration unexpectedly passed")
    }

    private func compileAndRun(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerJoystickHarness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let productionSource = directory.appendingPathComponent("joystick-production.cpp")
        let harnessSource = directory.appendingPathComponent("joystick-harness.cpp")
        let harnessBinary = directory.appendingPathComponent("joystick-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try harness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)

        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "clang++",
                "-std=c++17",
                "-ffunction-sections",
                "-fdata-sections",
                "-I", dosboxRoot.path,
                "-I", dosboxRoot.appendingPathComponent("include").path,
                "-I", dosboxRoot.appendingPathComponent("src").path,
                "-I", projectRoot.appendingPathComponent("Boxer").path,
                "-I", projectRoot.appendingPathComponent("Frameworks/SDL2.framework/Headers").path,
                harnessSource.path,
                "-Wl,-dead_strip",
                "-o", harnessBinary.path
            ]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }

        return try BoxerRuntimeProcessRunner.run(executable: harnessBinary.path, arguments: [])
    }

    private func harness(sourcePath: String) -> String {
        """
        #include <cstdarg>
        #include <cstdint>
        #include <cstdio>
        #include <cstdlib>
        #include <functional>
        #include <iostream>
        #include <memory>
        #include <string>

        #include "dosbox.h"
        #include "control.h"
        #include "inout.h"
        #include "mapper.h"
        #include "pic.h"
        #include "setup.h"

        static Section_prop *active_section = nullptr;
        static io_read_f registered_read = {};
        static io_write_f registered_write = {};
        static int read_installs = 0;
        static int write_installs = 0;
        static int read_uninstalls = 0;
        static int write_uninstalls = 0;
        static int activation_transitions = 0;
        static bool host_owns_joystick = false;
        static bool configured_timed = true;
        static std::string configured_type = "auto";

        config_ptr_t control = {};
        uint32_t PIC_Ticks = 0;
        uint32_t PIC_IRQCheck = 0;
        int32_t CPU_Cycles = 0;
        int32_t CPU_CycleLeft = 0;
        int32_t CPU_CycleMax = 1000;

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        void MAPPER_AddHandler(
            MAPPER_Handler *,
            SDL_Scancode,
            uint32_t,
            const char *,
            const char *
        ) {}

        void boxer_setJoystickActive(bool active)
        {
            if (active && !host_owns_joystick)
                ++activation_transitions;
            host_owns_joystick = active;
        }

        Config::~Config() {}
        Section *Config::GetSection(const std::string &) const { return active_section; }
        Section_prop::~Section_prop() {}
        std::string Section_line::GetPropValue(const std::string &) const { return {}; }
        bool Section_line::HandleInputline(const std::string &) { return false; }
        void Section_line::PrintData(FILE *) const {}
        std::string Section_prop::GetPropValue(const std::string &) const { return {}; }
        bool Section_prop::HandleInputline(const std::string &) { return false; }
        void Section_prop::PrintData(FILE *) const {}
        int Section_prop::Get_int(const std::string &name) const
        {
            return name == "deadzone" ? 0 : 0;
        }
        const char *Section_prop::Get_string(const std::string &name) const
        {
            if (name == "joysticktype")
                return configured_type.c_str();
            if (name == "joy_x_calibration" || name == "joy_y_calibration")
                return "auto";
            return "";
        }
        bool Section_prop::Get_bool(const std::string &name) const
        {
            if (name == "timed")
                return configured_timed;
            if (name == "buttonwrap")
                return true;
            return false;
        }
        Hex Section_prop::Get_hex(const std::string &) const { return Hex(0); }
        double Section_prop::Get_double(const std::string &) const { return 0.0; }
        Prop_path *Section_prop::Get_path(const std::string &) const { return nullptr; }
        PropMultiVal *Section_prop::GetMultiVal(const std::string &) const { return nullptr; }
        PropMultiValRemain *Section_prop::GetMultiValRemain(const std::string &) const { return nullptr; }
        Property *Section_prop::Get_prop(int) { return nullptr; }

        void Section::AddDestroyFunction(SectionFunction, bool) {}
        void Section::AddEarlyInitFunction(SectionFunction, bool) {}
        void Section::AddInitFunction(SectionFunction, bool) {}
        void Section::ExecuteEarlyInit(bool) {}
        void Section::ExecuteInit(bool) {}
        void Section::ExecuteDestroy(bool) {}

        void IO_RegisterReadHandler(io_port_t port, io_read_f handler, io_width_t, io_port_t)
        {
            if (port != 0x201 || registered_read)
                std::exit(40);
            registered_read = std::move(handler);
            ++read_installs;
        }
        void IO_RegisterWriteHandler(io_port_t port, io_write_f handler, io_width_t, io_port_t)
        {
            if (port != 0x201 || registered_write)
                std::exit(41);
            registered_write = std::move(handler);
            ++write_installs;
        }
        void IO_FreeReadHandler(io_port_t, io_width_t, io_port_t)
        {
            registered_read = {};
            ++read_uninstalls;
        }
        void IO_FreeWriteHandler(io_port_t, io_width_t, io_port_t)
        {
            registered_write = {};
            ++write_uninstalls;
        }
        void IO_ReadHandleObject::Install(io_port_t port, io_read_f handler, io_width_t width, io_port_t range)
        {
            if (installed)
                std::exit(42);
            installed = true;
            m_port = port;
            m_width = width;
            m_range = range;
            IO_RegisterReadHandler(port, std::move(handler), width, range);
        }
        void IO_WriteHandleObject::Install(io_port_t port, io_write_f handler, io_width_t width, io_port_t range)
        {
            if (installed)
                std::exit(43);
            installed = true;
            m_port = port;
            m_width = width;
            m_range = range;
            IO_RegisterWriteHandler(port, std::move(handler), width, range);
        }
        void IO_ReadHandleObject::Uninstall()
        {
            if (!installed)
                return;
            IO_FreeReadHandler(m_port, m_width, m_range);
            installed = false;
        }
        void IO_WriteHandleObject::Uninstall()
        {
            if (!installed)
                return;
            IO_FreeWriteHandler(m_port, m_width, m_range);
            installed = false;
        }
        IO_ReadHandleObject::~IO_ReadHandleObject() { Uninstall(); }
        IO_WriteHandleObject::~IO_WriteHandleObject() { Uninstall(); }

        #include "\(sourcePath)"

        static void reset_host_observations()
        {
            activation_transitions = 0;
            host_owns_joystick = false;
        }

        static int run_cycle(Section_prop &section, bool timed)
        {
            configured_timed = timed;
            active_section = &section;
            reset_host_observations();

            JOYSTICK_Init(&section);
            if (read_installs != write_installs || !registered_read || !registered_write)
                return 10;
            if (gameport_timed != timed)
                return 11;

            JOYSTICK_Enable(0, true);
            if (!JOYSTICK_IsAccessible(0))
                return 12;
            if (host_owns_joystick)
                return 13;

            registered_read(0x201, io_width_t::byte);
            registered_read(0x201, io_width_t::byte);
            if (activation_transitions != 1 || !host_owns_joystick)
                return 14;

            registered_write(0x201, 0, io_width_t::byte);
            if (activation_transitions != 1)
                return 16;

            JOYSTICK_Destroy(&section);
            if (registered_read || registered_write)
                return 15;
            return 0;
        }

        int main()
        {
            control = std::make_unique<Config>();
            Section_prop section("joystick");

            if (const auto result = run_cycle(section, true))
                return result;
            if (read_installs != 1 || write_installs != 1 ||
                read_uninstalls != 1 || write_uninstalls != 1)
                return 20;

            if (const auto result = run_cycle(section, false))
                return result + 20;
            if (read_installs != 2 || write_installs != 2 ||
                read_uninstalls != 2 || write_uninstalls != 2)
                return 21;

            configured_type = "hidden";
            active_section = &section;
            JOYSTICK_Init(&section);
            if (registered_read || registered_write)
                return 22;
            JOYSTICK_Enable(0, true);
            if (JOYSTICK_IsAccessible(0))
                return 23;
            JOYSTICK_Destroy(&section);

            std::cout << "joystick runtime harness passed\\n";
            return 0;
        }
        """
    }
}
