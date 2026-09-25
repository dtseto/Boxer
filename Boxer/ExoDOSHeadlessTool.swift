//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import Foundation

/// Drives the eXoDOS conversion from the command line, with no window involved.
///
/// This exists to be *checked*: `tools/exodos-import.py` was written first
/// precisely so the whole 7,633-game pack could be run through it and coverage
/// measured rather than estimated, and the only honest way to retire it is to
/// run the same corpus through this code and diff the two plans game by game.
/// It is a development harness, not a shipped feature — the arguments are
/// undocumented and nothing in the UI reaches them.
///
///     Boxer.app/Contents/MacOS/Boxer --exodosPlan=<game.zip|pack folder>
///     Boxer.app/Contents/MacOS/Boxer --exodosConvert=<game.zip> --exodosOutput=<folder>
///
/// `--exodosPack=<folder>` overrides where the metadata archive is looked for,
/// which is otherwise found beside the game the way the wizard finds it.
@objc(BXExoDOSHeadlessTool)
final class ExoDOSHeadlessTool: NSObject {
    /// Acts on the tool's arguments if any are present, and returns whether it
    /// did. The caller is expected to stop launching if so.
    @objc(runWithArguments:)
    static func run(arguments: [String]) -> Bool {
        let planPath = value(of: "--exodosPlan", in: arguments)
        let convertPath = value(of: "--exodosConvert", in: arguments)
        let boxArtPath = value(of: "--exodosBoxArt", in: arguments)
        guard planPath != nil || convertPath != nil || boxArtPath != nil else { return false }

        let packOverride = value(of: "--exodosPack", in: arguments).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        if let planPath = planPath {
            let url = URL(fileURLWithPath: planPath)
            if isDirectory(url) {
                planWholePack(at: url)
            } else {
                emit(planObject(for: url, packURL: packOverride))
            }
        } else if let boxArtPath = boxArtPath {
            reportBoxArt(inPackAt: URL(fileURLWithPath: boxArtPath, isDirectory: true))
        } else if let convertPath = convertPath {
            let output = value(of: "--exodosOutput", in: arguments) ?? FileManager.default.currentDirectoryPath
            convert(URL(fileURLWithPath: convertPath),
                    into: URL(fileURLWithPath: output, isDirectory: true),
                    packURL: packOverride,
                    replacing: arguments.contains("--exodosForce"))
        }
        return true
    }


    // MARK: - The two jobs

    /// Plans every game in a pack, the way `--all --dry-run` does.
    private static func planWholePack(at packURL: URL) {
        let gamesFolder = packURL.appendingPathComponent("eXo/eXoDOS", isDirectory: true)
        let metadata = BXImportClassifier.metadataArchiveURLInPack(at: packURL)

        let names = ((try? FileManager.default.contentsOfDirectory(atPath: gamesFolder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".zip") }
            .sorted()

        var plans: [[String: Any]] = []
        plans.reserveCapacity(names.count)
        for name in names {
            let url = gamesFolder.appendingPathComponent(name)
            plans.append(planObject(for: url, packURL: metadata == nil ? nil : packURL))
        }
        emit(plans)
    }

    /// Reports which games in a pack have a box front, and by which of the
    /// three names it was found. The 99.0% in EXODOS-IMPORT.md is this.
    private static func reportBoxArt(inPackAt packURL: URL) {
        guard let metadata = BXImportClassifier.metadataArchiveURLInPack(at: packURL) else {
            emit(["error": "no !DOSmetadata.zip in this pack"])
            return
        }
        guard let media = ExoDOSBoxArt.mediaArchiveURL(besideMetadataArchiveAt: metadata) else {
            emit(["error": "no XODOSMetadata.zip beside \(metadata.path)"])
            return
        }
        let archive: ZipArchiveReader
        do {
            archive = try ZipArchiveReader(url: media)
        } catch {
            emit(["error": "could not read \(media.path): \(error.localizedDescription)"])
            return
        }

        let gamesFolder = packURL.appendingPathComponent("eXo/eXoDOS", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: gamesFolder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".zip") }
            .sorted()

        var found = 0
        var missing: [String] = []
        for name in names {
            let url = gamesFolder.appendingPathComponent(name)
            guard let verdict = try? BXImportClassifier.classifyArchive(at: url),
                  verdict.kind == .exoDOSGame,
                  let shortName = verdict.shortName, let longName = verdict.gameTitle
            else { continue }

            if ExoDOSBoxArt.imagePath(forShortName: shortName, longName: longName, in: archive) != nil {
                found += 1
            } else {
                missing.append(longName)
            }
        }
        emit(["games": names.count, "with_box_art": found,
              "without_box_art": missing.count, "missing": missing])
    }

    private static func convert(_ gameURL: URL, into destination: URL, packURL: URL?, replacing: Bool) {
        guard let metadata = metadataArchiveURL(for: gameURL, packURL: packURL) else {
            emit(["source_zip": gameURL.path, "error": "no eXoDOS pack found for this game"])
            return
        }

        let operation = ExoDOSImportOperation(gameArchiveURL: gameURL,
                                              metadataArchiveURL: metadata,
                                              destinationURL: destination)
        operation.replacesExistingGamebox = replacing

        var lastPercent = -1
        let observer = NotificationCenter.default.addObserver(forName: .ADBOperationInProgress,
                                                             object: operation, queue: nil) { _ in
            let percent = Int(operation.currentProgress * 100)
            if percent != lastPercent {
                lastPercent = percent
                FileHandle.standardError.write(Data("\r\(percent)% \(operation.currentItemName)".utf8))
            }
        }
        operation.start()
        NotificationCenter.default.removeObserver(observer)
        FileHandle.standardError.write(Data("\n".utf8))

        var result: [String: Any] = ["source_zip": gameURL.path]
        if let error = operation.error {
            result["error"] = error.localizedDescription
        } else {
            result["gamebox_path"] = operation.gameboxURL?.path ?? ""
            result["warnings"] = operation.planWarnings
            result["box_art_bytes"] = operation.boxArtData?.count ?? 0
        }
        emit(result)
    }


    // MARK: - Reporting

    /// Renders a plan in the same shape `tools/exodos-import.py --dry-run`
    /// prints, so the two can be diffed against each other directly.
    static func planObject(for gameURL: URL, packURL: URL?) -> [String: Any] {
        guard let metadata = metadataArchiveURL(for: gameURL, packURL: packURL) else {
            return ["source_zip": gameURL.path, "error": "no eXoDOS pack found for this game"]
        }
        do {
            let plan = try ExoDOSPlanner.plan(gameArchiveAt: gameURL, metadataArchiveAt: metadata)
            return object(for: plan)
        } catch {
            return ["source_zip": gameURL.path, "error": error.localizedDescription]
        }
    }

    static func object(for plan: ExoDOSPlan) -> [String: Any] {
        var drives: [[String: Any]] = []
        for drive in plan.drives {
            var entry: [String: Any] = [
                "letter": drive.letter,
                "verb": drive.isImage ? "imgmount" : "mount",
                "kind": drive.kind.rawValue,
                "source": drive.source,
                "target": drive.target,
            ]
            entry["name"] = drive.name
            entry["insert_folder"] = drive.insertFolder
            if drive.isImage {
                entry["tracks"] = drive.tracks
                entry["bundle"] = drive.isBundle
                entry["descriptor"] = drive.descriptor
                entry["sector_size"] = drive.sectorSize
            }
            drives.append(entry)
        }

        return [
            "short_name": plan.shortName,
            "long_name": plan.longName,
            "gamebox_name": plan.gameboxName,
            "unpacked_size": plan.unpackedSize,
            "gamebox_autoexec": plan.gameboxAutoexec,
            "default_launcher": plan.defaultLauncher as Any,
            "shows_dos_view_at_startup": plan.showsDOSViewAtStartup,
            "source_zip": plan.sourceURL.path,
            "drives": drives,
            "launchers": plan.launchers.map {
                ["path": $0.path, "args": $0.arguments, "title": $0.title]
            },
            "setup_commands": plan.setupCommands,
            "settings": plan.settings,
            "mt32_roms": plan.mt32ROMs,
            "needs_menu_interpreter": plan.needsMenuInterpreter,
            "generated_files": plan.generatedFiles,
            "autoexec": plan.autoexec,
            "notes": plan.notes,
            "warnings": plan.warnings,
        ]
    }

    private static func emit(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }


    // MARK: - Finding the pack

    private static func metadataArchiveURL(for gameURL: URL, packURL: URL?) -> URL? {
        if let packURL = packURL {
            return BXImportClassifier.metadataArchiveURLInPack(at: packURL)
        }
        return BXImportClassifier.metadataArchiveURLForGameArchive(at: gameURL)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        for argument in arguments where argument.hasPrefix(flag + "=") {
            return String(argument.dropFirst(flag.count + 1))
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }
}
