import Foundation
import XCTest

final class BoxerRuntimeHarnessSupportTests: XCTestCase {
    func testEventRecorderPreservesOrderAndResetsState() throws {
        let recorder = BoxerRuntimeEventRecorder()
        try recorder.assertReset()

        recorder.record("shell-start")
        recorder.record("autoexec-start")
        recorder.record("prompt-return")
        XCTAssertEqual(recorder.events, ["shell-start", "autoexec-start", "prompt-return"])

        recorder.reset()
        try recorder.assertReset()
    }

    func testProcessRunnerReportsChildFailure() throws {
        let result = try BoxerRuntimeProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'intentional harness failure\\n'; exit 7"]
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "intentional harness failure\n")
    }

    func test079AdapterMapsProductionJoystickEntryPointsOnce() {
        let root = URL(fileURLWithPath: "/tmp/DOSBox-Staging")
        let adapter = DOSBox079Adapter(productionRoot: root)

        XCTAssertEqual(adapter.supportedVersions, ["0.79.1"])
        XCTAssertEqual(
            adapter.productionSources(for: .joystick),
            [root.appendingPathComponent("src/hardware/joystick.cpp")]
        )
        XCTAssertEqual(
            adapter.entryPoints(for: .joystick),
            ["JOYSTICK_Init", "IO_ReadB", "IO_WriteB", "JOYSTICK_Destroy"]
        )
    }

    func test080AdapterCannotBeUsedBeforeCompatibilityVerification() {
        let adapter = DOSBox080Adapter(productionRoot: URL(fileURLWithPath: "/tmp/official-080"))
        XCTAssertTrue(adapter.supportedVersions.isEmpty)
        XCTAssertTrue(adapter.productionSources(for: .mouse).isEmpty)
        XCTAssertTrue(adapter.entryPoints(for: .mouse).isEmpty)
    }
}
