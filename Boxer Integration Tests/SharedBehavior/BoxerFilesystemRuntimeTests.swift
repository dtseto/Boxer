import Foundation
import XCTest

final class BoxerFilesystemRuntimeTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var dosboxRoot: URL { projectRoot.appendingPathComponent("DOSBox-Staging") }

    // Protected BOXER markers: local-file-unavailable,
    // unavailable-file-read, unavailable-file-write, unavailable-file-seek,
    // unavailable-file-timestamp. Behavioral invariant: invalidating a real
    // localFile closes its host handle once while DOS-compatible read, write,
    // seek, timestamp, and close operations remain safe, and a second file
    // begins with an independent live handle. Historical references:
    // fd6e3fb60, 4e359684f, 92281b3ee. Real entry points/source:
    // localFile constructor, Read, Write, Seek, Close,
    // UpdateDateTimeFromHost, willBecomeUnavailable, and their position helpers
    // from src/dos/drive_local.cpp. Fake dependencies: DOS error sink, packed
    // timestamp conversion, and port IO. Supported adapter/version:
    // DOSBox079Adapter, v0.79.1 only. Mutation that must fail: removing the
    // production unavailable-read guard.
    func testRuntimeUnavailableLocalFileSafetyAndSecondLifecycle() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .filesystem)[0],
            encoding: .utf8
        )
        let fragment = try localFileSource(from: source)

        let normal = try compileAndRun(source: fragment, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("unavailable local file runtime harness passed"), normal.output)

        let mutation = try replacingFirst(
            "if (!fhandle) {\n\t\t*size = 0;\n\t\treturn true;\n\t}",
            with: "if (!fhandle) { return false; }",
            in: fragment
        )
        let mutationResult = try compileAndRun(source: mutation, label: "removed-read-safety")
        XCTAssertEqual(
            mutationResult.status,
            11,
            "Removed unavailable-read safety mutation did not fail behaviorally: \(mutationResult.output)"
        )
    }

    // Protected BOXER marker: local-dir-create-policy. Behavioral invariant:
    // denied directory creation never mutates the host or cache, while allowed
    // creation invokes the Boxer bridge and cache notification exactly once;
    // a second lifecycle begins clean. Historical references: fd6e3fb60,
    // 4e359684f, 92281b3ee. Real entry point/source: localDrive::MakeDir from
    // src/dos/drive_local.cpp. Fake dependencies: the minimum localDrive/cache
    // shape, Boxer policy/directory bridges, and an isolated host directory.
    // Supported adapter/version: DOSBox079Adapter, v0.79.1 only. Mutations:
    // bypassing policy or removing the Boxer creation route must fail.
    func testRuntimeDirectoryCreationPolicyAndAtomicDenial() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .filesystem)[0],
            encoding: .utf8
        )
        let function = try productionFunction(beginningWith: "bool localDrive::MakeDir(char * dir)", in: source)

        let normal = try compileAndRunDirectoryPolicy(source: function, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("directory policy runtime harness passed"), normal.output)

        let bypass = try replacingFirst(
            "if (!boxer_shouldAllowWriteAccessToPath(newdir, this))",
            with: "if (false)",
            in: function
        )
        let bypassResult = try compileAndRunDirectoryPolicy(source: bypass, label: "policy-bypass")
        XCTAssertEqual(bypassResult.status, 10, "Directory policy bypass did not fail behaviorally: \(bypassResult.output)")

        let removedRoute = try replacingFirst(
            "const bool created = boxer_createLocalDir(dirCache.GetExpandName(newdir), this);",
            with: "const bool created = false;",
            in: function
        )
        let routeResult = try compileAndRunDirectoryPolicy(source: removedRoute, label: "removed-route")
        XCTAssertEqual(routeResult.status, 12, "Removed directory route did not fail behaviorally: \(routeResult.output)")
    }

    // Protected BOXER markers: drive-cache-filter-bridge,
    // hide-host-metadata. Behavioral invariant: protected host metadata is
    // rejected before DOS short-name generation or cache insertion, while an
    // allowed file is generated and inserted exactly once; a second cache
    // lifecycle begins empty. Historical references: fd6e3fb60, 4e359684f,
    // 92281b3ee. Real entry point/source: DOS_Drive_Cache::CreateEntry from
    // src/dos/drive_cache.cpp. Fake dependencies: minimal cache node shape,
    // short-name generator, and Boxer visibility policy. Supported adapter:
    // DOSBox079Adapter, v0.79.1 only. Mutation: bypassing the visibility guard
    // must fail.
    func testRuntimeDriveCacheHidesProtectedMetadata() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .filesystem)[1],
            encoding: .utf8
        )
        let function = try productionFunction(
            beginningWith: "void DOS_Drive_Cache::CreateEntry(CFileInfo* dir, const char* name, bool is_directory)",
            in: source
        )
        let normal = try compileAndRunCacheFilter(source: function, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("drive cache filter runtime harness passed"), normal.output)

        let mutation = try replacingFirst(
            "if (!boxer_shouldShowFileWithName(name)) return;",
            with: "if (false) return;",
            in: function
        )
        let mutationResult = try compileAndRunCacheFilter(source: mutation, label: "filter-bypass")
        XCTAssertEqual(
            mutationResult.status,
            10,
            "Metadata-filter bypass did not fail behaviorally: \(mutationResult.output)"
        )
    }

    // Protected BOXER markers: file-create-write-policy,
    // local-file-created. Behavioral invariant: denied file creation is atomic;
    // allowed creation reaches the host, cache, and Boxer notification exactly
    // once; recreating an existing file truncates it without duplicating its
    // cache entry; and a second lifecycle begins clean. Historical references:
    // fd6e3fb60, 4e359684f, 92281b3ee. Real entry point/source:
    // localDrive::FileCreate from src/dos/drive_local.cpp. Fake dependencies:
    // minimal drive/cache/file shapes, DOS error sink, Boxer policy and create
    // callback, and an isolated host directory. Supported adapter/version:
    // DOSBox079Adapter, v0.79.1 only. Mutations: bypassing policy or removing
    // the creation notification must fail.
    func testRuntimeFileCreatePolicyNotificationAndTruncation() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .filesystem)[0],
            encoding: .utf8
        )
        let function = try productionFunction(
            beginningWith: "bool localDrive::FileCreate(DOS_File * * file,char * name,uint16_t /*attributes*/)",
            in: source
        )
        let normal = try compileAndRunFileCreate(source: function, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("file create runtime harness passed"), normal.output)

        let bypass = try replacingFirst(
            "if (!boxer_shouldAllowWriteAccessToPath(newname, this))",
            with: "if (false)",
            in: function
        )
        let bypassResult = try compileAndRunFileCreate(source: bypass, label: "policy-bypass")
        XCTAssertEqual(bypassResult.status, 10, "File-create policy bypass did not fail behaviorally: \(bypassResult.output)")

        let removedNotification = try replacingFirst(
            "boxer_didCreateLocalFile(name, this);",
            with: "/* mutation: file-created notification removed */",
            in: function
        )
        let notificationResult = try compileAndRunFileCreate(
            source: removedNotification,
            label: "removed-notification"
        )
        XCTAssertEqual(
            notificationResult.status,
            13,
            "Removed file-created notification did not fail behaviorally: \(notificationResult.output)"
        )
    }

    // Protected BOXER markers: file-delete-write-policy, local-file-removed,
    // local-open-file-removed. Behavioral invariant: missing or denied deletes
    // do not mutate host/cache/notification state, while an allowed delete
    // removes exactly one host file, cache entry, and Boxer-visible file; a
    // second lifecycle begins clean. Historical references: fd6e3fb60,
    // 4e359684f, 92281b3ee. Real entry point/source: localDrive::FileUnlink from
    // src/dos/drive_local.cpp. Fake dependencies: minimal drive/cache/open-file
    // inventory, DOS error sink, Boxer policy/removal callbacks, and isolated
    // host storage. Supported adapter/version: DOSBox079Adapter, v0.79.1 only.
    // Mutations: bypassing policy or removing notification must fail.
    func testRuntimeFileDeletePolicyAndNotification() throws {
        let adapter = DOSBox079Adapter(productionRoot: dosboxRoot)
        let source = try String(
            contentsOf: adapter.productionSources(for: .filesystem)[0],
            encoding: .utf8
        )
        let function = try productionFunction(
            beginningWith: "bool localDrive::FileUnlink(char * name)",
            in: source
        )
        let normal = try compileAndRunFileDelete(source: function, label: "normal")
        XCTAssertEqual(normal.status, 0, normal.output)
        XCTAssertTrue(normal.output.contains("file delete runtime harness passed"), normal.output)

        let bypass = try replacingFirst(
            "if (!boxer_shouldAllowWriteAccessToPath(fullname, this))",
            with: "if (false)",
            in: function
        )
        let bypassResult = try compileAndRunFileDelete(source: bypass, label: "policy-bypass")
        XCTAssertEqual(bypassResult.status, 10, "File-delete policy bypass did not fail behaviorally: \(bypassResult.output)")

        let removedNotification = try replacingFirst(
            "boxer_didRemoveLocalFile(fullname, this);",
            with: "/* mutation: file-removed notification removed */",
            in: function
        )
        let notificationResult = try compileAndRunFileDelete(
            source: removedNotification,
            label: "removed-notification"
        )
        XCTAssertEqual(
            notificationResult.status,
            13,
            "Removed file-delete notification did not fail behaviorally: \(notificationResult.output)"
        )
    }

    private func localFileSource(from source: String) throws -> String {
        let signatures = [
            "bool localFile::ftell_and_check()",
            "bool localFile::fseek_to_and_check(long pos, int whence)",
            "void localFile::fseek_and_check(int whence)",
            "bool localFile::Read(uint8_t *data, uint16_t *size)",
            "bool localFile::Write(uint8_t *data, uint16_t *size)",
            "bool localFile::Seek(uint32_t *pos_addr, uint32_t type)",
            "bool localFile::Close()",
            "uint16_t localFile::GetInformation(void)",
            "localFile::localFile(const char *_name, FILE *handle, const char *_basedir)",
            "bool localFile::UpdateDateTimeFromHost()",
            "void localFile::willBecomeUnavailable()"
        ]
        return try signatures.map { try productionFunction(beginningWith: $0, in: source) }
            .joined(separator: "\n\n")
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
                    return String(source[signatureRange.lowerBound...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        throw BoxerRuntimeHarnessError.launchFailed("Unbalanced production function: \(signature)")
    }

    private func replacingFirst(_ needle: String, with replacement: String, in source: String) throws -> String {
        guard let range = source.range(of: needle) else {
            throw BoxerRuntimeHarnessError.launchFailed("Could not create filesystem mutation: \(needle)")
        }
        return source.replacingCharacters(in: range, with: replacement)
    }

    private func compileAndRun(source: String, label: String) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerUnavailableFile-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let productionSource = directory.appendingPathComponent("local-file-production.cpp")
        let harnessSource = directory.appendingPathComponent("local-file-harness.cpp")
        let binary = directory.appendingPathComponent("local-file-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try harness(sourcePath: productionSource.path)
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

    private func compileAndRunDirectoryPolicy(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerDirectoryPolicy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let productionSource = directory.appendingPathComponent("make-dir-production.cpp")
        let harnessSource = directory.appendingPathComponent("make-dir-harness.cpp")
        let binary = directory.appendingPathComponent("make-dir-harness")
        let fixture = directory.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try directoryPolicyHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["clang++", "-std=c++17", harnessSource.path, "-o", binary.path]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [fixture.path])
    }

    private func compileAndRunCacheFilter(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerCacheFilter-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let productionSource = directory.appendingPathComponent("cache-filter-production.cpp")
        let harnessSource = directory.appendingPathComponent("cache-filter-harness.cpp")
        let binary = directory.appendingPathComponent("cache-filter-harness")
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try cacheFilterHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["clang++", "-std=c++17", harnessSource.path, "-o", binary.path]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [])
    }

    private func compileAndRunFileCreate(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerFileCreate-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let productionSource = directory.appendingPathComponent("file-create-production.cpp")
        let harnessSource = directory.appendingPathComponent("file-create-harness.cpp")
        let binary = directory.appendingPathComponent("file-create-harness")
        let fixture = directory.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try fileCreateHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["clang++", "-std=c++17", harnessSource.path, "-o", binary.path]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [fixture.path])
    }

    private func compileAndRunFileDelete(
        source: String,
        label: String
    ) throws -> BoxerRuntimeProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxerFileDelete-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let productionSource = directory.appendingPathComponent("file-delete-production.cpp")
        let harnessSource = directory.appendingPathComponent("file-delete-harness.cpp")
        let binary = directory.appendingPathComponent("file-delete-harness")
        let fixture = directory.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try source.write(to: productionSource, atomically: true, encoding: .utf8)
        try fileDeleteHarness(sourcePath: productionSource.path)
            .write(to: harnessSource, atomically: true, encoding: .utf8)
        let compile = try BoxerRuntimeProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["clang++", "-std=c++17", harnessSource.path, "-o", binary.path]
        )
        XCTAssertEqual(compile.status, 0, compile.output)
        guard compile.status == 0 else { return compile }
        return try BoxerRuntimeProcessRunner.run(executable: binary.path, arguments: [fixture.path])
    }

    private func harness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <cstdio>
        #include <iostream>
        #include <utime.h>
        #include "cross.h"
        #include "dos_inc.h"
        #include "drives.h"
        #include "inout.h"
        #include "string_utils.h"
        #include "support.h"

        static uint16_t last_error = 0;
        void DOS_SetError(uint16_t error) { last_error = error; }
        uint16_t DOS_PackTime(const struct tm *) { return 1; }
        uint16_t DOS_PackDate(const struct tm *) { return 1; }
        uint8_t IO_ReadB(io_port_t) { return 0; }
        void IO_WriteB(io_port_t, uint8_t) {}
        void strreplace(char *string, char old_character, char new_character) {
            for (; *string; ++string)
                if (*string == old_character)
                    *string = new_character;
        }

        namespace loguru {
        Verbosity current_verbosity_cutoff() { return Verbosity_OFF; }
        void log(Verbosity, const char *, unsigned, const char *, ...) {}
        }

        #include "\(sourcePath)"

        static int run_cycle() {
            FILE *handle = tmpfile();
            if (!handle)
                return 10;
            localFile file("SAVE.DAT", handle, "/tmp/");
            file.flags = OPEN_READWRITE;
            file.willBecomeUnavailable();

            uint8_t buffer[4] = {1, 2, 3, 4};
            uint16_t size = sizeof(buffer);
            if (!file.Read(buffer, &size) || size != 0)
                return 11;
            size = sizeof(buffer);
            if (!file.Write(buffer, &size) || size != 0)
                return 12;
            uint32_t position = 99;
            if (!file.Seek(&position, DOS_SEEK_SET) || position != 0)
                return 13;
            if (file.UpdateDateTimeFromHost())
                return 14;
            if (!file.Close())
                return 15;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle())
                return result;
            if (const auto result = run_cycle())
                return result + 20;
            std::cout << "unavailable local file runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func directoryPolicyHarness(sourcePath: String) -> String {
        """
        #include <cerrno>
        #include <cstdint>
        #include <cstdio>
        #include <cstring>
        #include <iostream>
        #include <string>
        #include <sys/stat.h>
        #include <unistd.h>

        #define CROSS_LEN 4096
        #define CROSS_FILENAME(path) replace_slashes(path)
        #define LOG_MSG(...) do {} while (0)
        static void replace_slashes(char *path) {
            for (; *path; ++path) if (*path == '\\\\') *path = '/';
        }
        static void safe_strcpy(char *destination, const char *source) {
            std::snprintf(destination, CROSS_LEN, "%s", source);
        }
        static void safe_strcat(char *destination, const char *source) {
            std::strncat(destination, source, CROSS_LEN - std::strlen(destination) - 1);
        }

        class localDrive;
        static bool allow_write = false;
        static int policy_calls = 0;
        static int create_calls = 0;
        static int cache_calls = 0;
        static uint16_t last_error = 0;
        bool boxer_shouldAllowWriteAccessToPath(const char *, localDrive *) {
            ++policy_calls;
            return allow_write;
        }
        bool boxer_createLocalDir(const char *path, localDrive *) {
            ++create_calls;
            return mkdir(path, 0700) == 0;
        }
        void DOS_SetError(uint16_t error) { last_error = error; }
        constexpr uint16_t DOSERR_ACCESS_DENIED = 5;

        struct FakeCache {
            char expanded[CROSS_LEN] = {};
            char *GetExpandName(char *path) {
                safe_strcpy(expanded, path);
                return expanded;
            }
            void CacheOut(char *, bool) { ++cache_calls; }
        };
        class localDrive {
        public:
            explicit localDrive(const char *root) { safe_strcpy(basedir, root); }
            bool MakeDir(char *dir);
            char basedir[CROSS_LEN] = {};
            FakeCache dirCache;
        };

        #include "\(sourcePath)"

        static bool exists(const std::string &path) {
            struct stat info = {};
            return stat(path.c_str(), &info) == 0;
        }
        static int run_cycle(const std::string &root, int cycle) {
            policy_calls = create_calls = cache_calls = 0;
            last_error = 0;
            localDrive drive((root + "/").c_str());
            std::string denied_name = "denied" + std::to_string(cycle);
            char denied[32] = {};
            std::strcpy(denied, denied_name.c_str());
            allow_write = false;
            if (drive.MakeDir(denied) || exists(root + "/" + denied_name))
                return 10;
            if (last_error != DOSERR_ACCESS_DENIED || policy_calls != 1 ||
                create_calls != 0 || cache_calls != 0)
                return 11;

            std::string allowed_name = "allowed" + std::to_string(cycle);
            char allowed[32] = {};
            std::strcpy(allowed, allowed_name.c_str());
            allow_write = true;
            if (!drive.MakeDir(allowed) || !exists(root + "/" + allowed_name))
                return 12;
            if (policy_calls != 2 || create_calls != 1 || cache_calls != 1)
                return 13;
            return 0;
        }
        int main(int argc, char **argv) {
            if (argc != 2) return 50;
            if (const auto result = run_cycle(argv[1], 1)) return result;
            if (const auto result = run_cycle(argv[1], 2)) return result + 20;
            std::cout << "directory policy runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func cacheFilterHarness(sourcePath: String) -> String {
        """
        #include <algorithm>
        #include <cstdint>
        #include <cstring>
        #include <iostream>
        #include <string>
        #include <vector>

        #define CROSS_LEN 4096
        static int visibility_calls = 0;
        static int short_name_calls = 0;
        bool boxer_shouldShowFileWithName(const char *name) {
            ++visibility_calls;
            return std::strcmp(name, ".DS_Store") != 0 &&
                   std::strcmp(name, "Icon\\r") != 0;
        }
        static void safe_strcpy(char *destination, const char *source) {
            std::snprintf(destination, CROSS_LEN, "%s", source);
        }

        class DOS_Drive_Cache {
        public:
            struct CFileInfo {
                char orgname[CROSS_LEN] = {};
                char shortname[CROSS_LEN] = {};
                int shortNr = 0;
                bool isDir = false;
                std::vector<CFileInfo *> fileList;
                ~CFileInfo() { for (auto *entry : fileList) delete entry; }
            };
            void CreateEntry(CFileInfo *dir, const char *name, bool is_directory);
            void CreateShortName(CFileInfo *, CFileInfo *info) {
                ++short_name_calls;
                safe_strcpy(info->shortname, info->orgname);
            }
        };

        #include "\(sourcePath)"

        static int run_cycle() {
            visibility_calls = short_name_calls = 0;
            DOS_Drive_Cache cache;
            DOS_Drive_Cache::CFileInfo root;
            cache.CreateEntry(&root, ".DS_Store", false);
            cache.CreateEntry(&root, "Icon\\r", false);
            if (!root.fileList.empty() || short_name_calls != 0)
                return 10;
            cache.CreateEntry(&root, "SAVE.DAT", false);
            if (root.fileList.size() != 1 || short_name_calls != 1 ||
                std::strcmp(root.fileList[0]->orgname, "SAVE.DAT") != 0 ||
                root.fileList[0]->isDir)
                return 11;
            if (visibility_calls != 3)
                return 12;
            return 0;
        }

        int main() {
            if (const auto result = run_cycle()) return result;
            if (const auto result = run_cycle()) return result + 20;
            std::cout << "drive cache filter runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func fileCreateHarness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <cstdio>
        #include <cstring>
        #include <iostream>
        #include <string>
        #include <sys/stat.h>

        #define CROSS_LEN 4096
        #define CROSS_FILENAME(path) replace_slashes(path)
        #define LOG_MSG(...) do {} while (0)
        constexpr uint16_t DOSERR_ACCESS_DENIED = 5;
        constexpr uint32_t OPEN_READWRITE = 2;
        static void replace_slashes(char *path) {
            for (; *path; ++path) if (*path == '\\\\') *path = '/';
        }
        static void safe_strcpy(char *destination, const char *source) {
            std::snprintf(destination, CROSS_LEN, "%s", source);
        }
        static void safe_strcat(char *destination, const char *source) {
            std::strncat(destination, source, CROSS_LEN - std::strlen(destination) - 1);
        }
        static FILE *fopen_wrap(const char *path, const char *mode) { return std::fopen(path, mode); }

        class localDrive;
        class DOS_File {
        public:
            virtual ~DOS_File() = default;
            uint32_t flags = 0;
        };
        class localFile final : public DOS_File {
        public:
            localFile(const char *, FILE *handle, const char *) : file(handle) {}
            ~localFile() override { if (file) std::fclose(file); }
            FILE *file;
        };
        struct FakeCache {
            int additions = 0;
            char expanded[CROSS_LEN] = {};
            char *GetExpandName(char *path) { safe_strcpy(expanded, path); return expanded; }
            void AddEntry(char *, bool) { ++additions; }
        };
        class localDrive {
        public:
            explicit localDrive(const char *root) { safe_strcpy(basedir, root); }
            bool FileCreate(DOS_File **file, char *name, uint16_t attributes);
            char basedir[CROSS_LEN] = {};
            FakeCache dirCache;
        };

        static bool allow_write = false;
        static int policy_calls = 0;
        static int create_notifications = 0;
        static uint16_t last_error = 0;
        bool boxer_shouldAllowWriteAccessToPath(const char *, localDrive *) {
            ++policy_calls;
            return allow_write;
        }
        void boxer_didCreateLocalFile(const char *, localDrive *) { ++create_notifications; }
        void DOS_SetError(uint16_t error) { last_error = error; }

        #include "\(sourcePath)"

        static size_t file_size(const std::string &path) {
            struct stat info = {};
            return stat(path.c_str(), &info) == 0 ? static_cast<size_t>(info.st_size) : SIZE_MAX;
        }
        static int run_cycle(const std::string &root, int cycle) {
            policy_calls = create_notifications = 0;
            last_error = 0;
            localDrive drive((root + "/").c_str());
            DOS_File *file = nullptr;
            std::string denied_name = "DENIED" + std::to_string(cycle) + ".DAT";
            char denied[64] = {};
            std::strcpy(denied, denied_name.c_str());
            allow_write = false;
            if (drive.FileCreate(&file, denied, 0) || file ||
                file_size(root + "/" + denied_name) != SIZE_MAX)
                return 10;
            if (last_error != DOSERR_ACCESS_DENIED || policy_calls != 1 ||
                create_notifications != 0 || drive.dirCache.additions != 0)
                return 11;

            std::string allowed_name = "SAVE" + std::to_string(cycle) + ".DAT";
            char allowed[64] = {};
            std::strcpy(allowed, allowed_name.c_str());
            allow_write = true;
            if (!drive.FileCreate(&file, allowed, 0) || !file)
                return 12;
            delete file;
            file = nullptr;
            if (file_size(root + "/" + allowed_name) != 0 ||
                create_notifications != 1 || drive.dirCache.additions != 1)
                return 13;

            FILE *seed = std::fopen((root + "/" + allowed_name).c_str(), "wb");
            std::fputs("payload", seed);
            std::fclose(seed);
            if (!drive.FileCreate(&file, allowed, 0) || !file)
                return 14;
            delete file;
            if (file_size(root + "/" + allowed_name) != 0 ||
                create_notifications != 2 || drive.dirCache.additions != 1 || policy_calls != 3)
                return 15;
            return 0;
        }
        int main(int argc, char **argv) {
            if (argc != 2) return 50;
            if (const auto result = run_cycle(argv[1], 1)) return result;
            if (const auto result = run_cycle(argv[1], 2)) return result + 20;
            std::cout << "file create runtime harness passed\\n";
            return 0;
        }
        """
    }

    private func fileDeleteHarness(sourcePath: String) -> String {
        """
        #include <cstdint>
        #include <cstdio>
        #include <cstring>
        #include <iostream>
        #include <string>
        #include <sys/stat.h>

        #define CROSS_LEN 4096
        #define CROSS_FILENAME(path) replace_slashes(path)
        #define DEBUG_LOG_MSG(...) do {} while (0)
        constexpr uint16_t DOSERR_ACCESS_DENIED = 5;
        constexpr uint16_t DOSERR_FILE_NOT_FOUND = 2;
        constexpr size_t DOS_FILES = 127;
        static void replace_slashes(char *path) {
            for (; *path; ++path) if (*path == '\\\\') *path = '/';
        }
        static void safe_strcpy(char *destination, const char *source) {
            std::snprintf(destination, CROSS_LEN, "%s", source);
        }
        static void safe_strcat(char *destination, const char *source) {
            std::strncat(destination, source, CROSS_LEN - std::strlen(destination) - 1);
        }

        class localDrive;
        class DOS_File {
        public:
            bool IsOpen() const { return false; }
            bool Close() { return true; }
            int RemoveRef() { return 0; }
        };
        struct FakeCache {
            int deletions = 0;
            char expanded[CROSS_LEN] = {};
            char *GetExpandName(char *path) { safe_strcpy(expanded, path); return expanded; }
            void DeleteEntry(char *) { ++deletions; }
        };
        class localDrive {
        public:
            explicit localDrive(const char *root) { safe_strcpy(basedir, root); }
            bool FileUnlink(char *name);
            bool FileExists(const char *name) {
                char path[CROSS_LEN] = {};
                safe_strcpy(path, basedir);
                safe_strcat(path, name);
                struct stat info = {};
                return stat(path, &info) == 0;
            }
            char basedir[CROSS_LEN] = {};
            FakeCache dirCache;
        };
        DOS_File *FindOpenFile(const localDrive *, const char *) { return nullptr; }

        static bool allow_write = false;
        static int policy_calls = 0;
        static int removal_notifications = 0;
        static uint16_t last_error = 0;
        bool boxer_shouldAllowWriteAccessToPath(const char *, localDrive *) {
            ++policy_calls;
            return allow_write;
        }
        void boxer_didRemoveLocalFile(const char *, localDrive *) { ++removal_notifications; }
        void DOS_SetError(uint16_t error) { last_error = error; }

        #include "\(sourcePath)"

        static bool exists(const std::string &path) {
            struct stat info = {};
            return stat(path.c_str(), &info) == 0;
        }
        static void seed(const std::string &path) {
            FILE *file = std::fopen(path.c_str(), "wb");
            std::fputs("payload", file);
            std::fclose(file);
        }
        static int run_cycle(const std::string &root, int cycle) {
            policy_calls = removal_notifications = 0;
            last_error = 0;
            localDrive drive((root + "/").c_str());

            char missing[] = "MISSING.DAT";
            if (drive.FileUnlink(missing) || last_error != DOSERR_FILE_NOT_FOUND ||
                policy_calls != 0 || removal_notifications != 0 || drive.dirCache.deletions != 0)
                return 9;

            const std::string name = "SAVE" + std::to_string(cycle) + ".DAT";
            const std::string path = root + "/" + name;
            seed(path);
            char dos_name[64] = {};
            std::strcpy(dos_name, name.c_str());
            allow_write = false;
            if (drive.FileUnlink(dos_name) || !exists(path))
                return 10;
            if (last_error != DOSERR_ACCESS_DENIED || policy_calls != 1 ||
                removal_notifications != 0 || drive.dirCache.deletions != 0)
                return 11;

            allow_write = true;
            if (!drive.FileUnlink(dos_name) || exists(path))
                return 12;
            if (policy_calls != 2 || removal_notifications != 1 ||
                drive.dirCache.deletions != 1)
                return 13;
            return 0;
        }
        int main(int argc, char **argv) {
            if (argc != 2) return 50;
            if (const auto result = run_cycle(argv[1], 1)) return result;
            if (const auto result = run_cycle(argv[1], 2)) return result + 20;
            std::cout << "file delete runtime harness passed\\n";
            return 0;
        }
        """
    }
}
