import Foundation

/// Ordered, resettable observation sink shared by every Boxer runtime harness.
///
/// Harnesses record only Boxer-visible outcomes here. Production entry points
/// remain in the DOSBox source compiled by each version adapter.
final class BoxerRuntimeEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
    }

    func assertReset(file: StaticString = #filePath, line: UInt = #line) throws {
        guard events.isEmpty else {
            throw BoxerRuntimeHarnessError.dirtyState(events: events, file: file, line: line)
        }
    }
}

struct BoxerRuntimeProcessResult {
    let status: Int32
    let output: String
}

enum BoxerRuntimeHarnessError: Error, CustomStringConvertible {
    case launchFailed(String)
    case dirtyState(events: [String], file: StaticString, line: UInt)

    var description: String {
        switch self {
        case .launchFailed(let message):
            return message
        case .dirtyState(let events, let file, let line):
            return "Runtime harness state was not reset at \(file):\(line): \(events)"
        }
    }
}

/// Child-process runner used to compile and invoke real DOSBox production files.
/// Standard output and error are merged so compiler and mutation failures retain
/// their complete diagnostic reason.
enum BoxerRuntimeProcessRunner {
    static func run(executable: String, arguments: [String]) throws -> BoxerRuntimeProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw BoxerRuntimeHarnessError.launchFailed(
                "Could not launch \(executable): \(error.localizedDescription)"
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return BoxerRuntimeProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}

/// Version adapters map shared behavioral expectations to real production
/// sources and entry points. They never weaken or duplicate expectations.
protocol BoxerDOSBoxRuntimeAdapter {
    var identifier: String { get }
    var supportedVersions: [String] { get }
    var productionRoot: URL { get }
    var includeDirectories: [URL] { get }

    func productionSources(for behavior: BoxerRuntimeBehavior) -> [URL]
    func entryPoints(for behavior: BoxerRuntimeBehavior) -> [String]
}

enum BoxerRuntimeBehavior: String, CaseIterable {
    case joystick
    case lifecycle
    case keyboard
    case printer
    case filesystem
    case shell
    case mouse
    case render
    case audio
    case configuration
    case media
    case localization
    case capture
}

/// v0.79.1 adapter.
///
/// Production files compiled by the initial harnesses:
/// - src/hardware/joystick.cpp
/// - lifecycle, keyboard, printer, filesystem, and shell files returned below
///
/// API mapping uses the v0.79.1 JOYSTICK_Init/Destroy, DOSBOX_RunMachine,
/// BIOS/console, CParallel, localDrive, and DOS_Shell entry points. Host services
/// are linker-provided fakes. This adapter does not claim v0.80 compatibility:
/// the v0.80 mouse, renderer, mixer, and configuration layouts require separate
/// verification before an adapter can be shared.
struct DOSBox079Adapter: BoxerDOSBoxRuntimeAdapter {
    let productionRoot: URL

    var identifier: String { "dosbox-0.79" }
    var supportedVersions: [String] { ["0.79.1"] }

    var includeDirectories: [URL] {
        [
            productionRoot,
            productionRoot.appendingPathComponent("include"),
            productionRoot.appendingPathComponent("src")
        ]
    }

    func productionSources(for behavior: BoxerRuntimeBehavior) -> [URL] {
        let paths: [String]
        switch behavior {
        case .joystick:
            paths = ["src/hardware/joystick.cpp"]
        case .lifecycle:
            paths = ["src/dosbox.cpp", "src/dos/dos.cpp"]
        case .keyboard:
            paths = [
                "src/hardware/keyboard.cpp",
                "src/ints/bios_keyboard.cpp",
                "src/dos/dev_con.h",
                "src/dos/dos_keyboard_layout.cpp"
            ]
        case .printer:
            paths = [
                "src/hardware/parport/parport.cpp",
                "src/hardware/parport/printer_redir.cpp",
                "src/ints/bios.cpp",
                "src/dos/dos.cpp"
            ]
        case .filesystem:
            paths = ["src/dos/drive_local.cpp", "src/dos/drive_cache.cpp"]
        case .shell:
            paths = [
                "src/shell/shell.cpp",
                "src/shell/shell_batch.cpp",
                "src/shell/shell_misc.cpp"
            ]
        case .mouse:
            paths = ["src/hardware/mouse.cpp"]
        case .render:
            paths = ["src/gui/render.cpp"]
        case .audio:
            paths = ["src/hardware/mixer.cpp"]
        case .configuration:
            paths = ["src/dosbox.cpp"]
        case .media:
            paths = ["src/dos/program_mount.cpp", "src/dos/program_imgmount.cpp"]
        case .localization:
            paths = ["src/misc/messages.cpp"]
        case .capture:
            paths = ["src/hardware/hardware.cpp"]
        }
        return paths.map(productionRoot.appendingPathComponent)
    }

    func entryPoints(for behavior: BoxerRuntimeBehavior) -> [String] {
        switch behavior {
        case .joystick: return ["JOYSTICK_Init", "IO_ReadB", "IO_WriteB", "JOYSTICK_Destroy"]
        case .lifecycle: return ["DOSBOX_RunMachine", "DOS_Shutdown"]
        case .keyboard: return ["KEYBOARD_Init", "BIOS_AddKeyToBuffer"]
        case .printer: return ["PARALLEL_Init", "CParallel::Putchar"]
        case .filesystem: return ["localDrive::FileCreate", "localDrive::FileOpen"]
        case .shell: return ["DOS_Shell::Run"]
        case .mouse: return ["MOUSE_Init", "Mouse_CursorMoved"]
        case .render: return ["RENDER_Reset", "RENDER_StartUpdate", "RENDER_EndUpdate"]
        case .audio: return ["MIXER_Init", "MIXER_CallBack"]
        case .configuration: return ["DOSBOX_Init"]
        case .media: return ["MOUNT_ProgramStart", "IMGMOUNT_ProgramStart"]
        case .localization: return ["MSG_Get"]
        case .capture: return ["OpenCaptureFile"]
        }
    }
}

/// Placeholder mapping boundary for the v0.80 source family.
///
/// v0.80.0 and v0.80.1 are intentionally not declared compatible here. Their
/// production signatures and layouts must be compared in isolated official
/// worktrees, with narrow DOSBox0800Adapter/DOSBox0801Adapter types introduced
/// for any mouse, mixer, callback, shell, filesystem, or property difference.
struct DOSBox080Adapter: BoxerDOSBoxRuntimeAdapter {
    let productionRoot: URL

    var identifier: String { "dosbox-0.80-unverified" }
    var supportedVersions: [String] { [] }
    var includeDirectories: [URL] { [productionRoot.appendingPathComponent("include")] }

    func productionSources(for behavior: BoxerRuntimeBehavior) -> [URL] {
        []
    }

    func entryPoints(for behavior: BoxerRuntimeBehavior) -> [String] {
        []
    }
}
