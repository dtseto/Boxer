//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import Foundation

/// Turns an `ExoDOSPlan` into a gamebox on disk.
///
/// The archive is extracted **straight into the destination**, never to a
/// temporary folder first. Monkey Island alone is a 553 MB disc image, a 468 MB
/// speech file and two complete FLAC sets; extracting it somewhere else and
/// then copying costs twice the space and twice the wait.
final class ExoDOSConverter {
    struct Progress {
        /// How many bytes have been written into the gamebox so far.
        var bytesWritten: Int64
        /// How many the plan expects in total. Zero if it could not be totalled.
        var totalBytes: Int64
        /// What is being written right now, for display.
        var currentItem: String

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(bytesWritten) / Double(totalBytes))
        }
    }

    enum Failure: LocalizedError {
        case gameboxExists(URL)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .gameboxExists(let url):
                return String(format: NSLocalizedString("“%@” already exists.",
                                                        comment: "Error when the destination gamebox is already there. %@ is its name."),
                              url.lastPathComponent)
            case .cancelled:
                return NSLocalizedString("The import was cancelled.",
                                         comment: "Error reported when an import is cancelled by the user.")
            }
        }
    }

    /// The name Boxer looks for inside a `.cdmedia` bundle.
    /// `+[BXDrive mountPointForContentsOfURL:]` (`BXDrive.m:241`) appends
    /// exactly this, with no fallback and no search, so a bundle whose
    /// descriptor is called anything else will not mount at all.
    static let cdMediaDescriptorName = "tracks.cue"

    private let plan: ExoDOSPlan
    private let destinationDirectory: URL
    private let overwrite: Bool

    /// Consulted between files, and between chunks of a large one.
    var isCancelled: () -> Bool = { false }
    var onProgress: (Progress) -> Void = { _ in }

    /// Archive members the plan had no place for. Not an error — eXo ships
    /// Windows-side helpers and its own marker file in every game — but worth
    /// having when a conversion looks light.
    private(set) var skippedMembers: [String] = []

    init(plan: ExoDOSPlan, destinationDirectory: URL, overwrite: Bool = false) {
        self.plan = plan
        self.destinationDirectory = destinationDirectory
        self.overwrite = overwrite
    }

    /// Builds the gamebox and returns where it landed.
    @discardableResult
    func run() throws -> URL {
        let manager = FileManager.default
        let gamebox = destinationDirectory.appendingPathComponent(plan.gameboxName, isDirectory: true)

        var replacedExisting = false
        if manager.fileExists(atPath: gamebox.path) {
            guard overwrite else { throw Failure.gameboxExists(gamebox) }
            try manager.removeItem(at: gamebox)
            replacedExisting = true
        }
        _ = replacedExisting

        try manager.createDirectory(at: gamebox, withIntermediateDirectories: true)

        do {
            try extractMembers(into: gamebox)
            try writeCDMediaDescriptors(into: gamebox)
            try writeGeneratedBatchFiles(into: gamebox)
            try writeConfiguration(into: gamebox)
            try writeGameInfo(into: gamebox)
        } catch {
            // A half-built gamebox is worse than none: it looks importable and
            // is not. Anything we created is ours to take away again.
            try? manager.removeItem(at: gamebox)
            throw error
        }
        return gamebox
    }


    // MARK: - Extraction

    private func extractMembers(into gamebox: URL) throws {
        let archive = try ZipArchiveReader(url: plan.sourceURL)
        let root = plan.shortName + "/"

        var work: [(entry: BXZipEntry, destination: URL)] = []
        var total: Int64 = 0

        for entry in archive.directory.entries where !entry.isDirectory {
            guard entry.path.count > root.count,
                  entry.path.lowercased().hasPrefix(root.lowercased()) else { continue }
            let member = String(entry.path.dropFirst(root.count))
            guard let relative = destination(for: member) else {
                skippedMembers.append(member)
                continue
            }
            work.append((entry, gamebox.appendingPathComponent(relative)))
            total += Int64(entry.uncompressedSize)
        }

        var written: Int64 = 0
        for item in work {
            if isCancelled() { throw Failure.cancelled }
            let name = ExoDOSPlanner.basename(item.entry.path)
            onProgress(Progress(bytesWritten: written, totalBytes: total, currentItem: name))

            let before = written
            var stopped = false
            try archive.extract(item.entry, to: item.destination) { bytes in
                if self.isCancelled() { stopped = true; return false }
                written = before + bytes
                self.onProgress(Progress(bytesWritten: written, totalBytes: total, currentItem: name))
                return true
            }
            if stopped { throw Failure.cancelled }
            written = before + Int64(item.entry.uncompressedSize)
        }
        onProgress(Progress(bytesWritten: total, totalBytes: total, currentItem: ""))
    }

    /// Maps one archive member onto its place inside the gamebox.
    ///
    /// Most specific claim wins. A disk image is claimed by name before any
    /// folder drive gets a look in, because the folder drive is usually the
    /// game's whole directory — mounted at the root of the archive it would
    /// otherwise swallow the CD image sitting in a subfolder and leave the D
    /// drive with nothing to mount. Folder drives are then tried
    /// longest-source-first, so a drive mounted on a subfolder beats the one
    /// mounted on everything.
    func destination(for member: String) -> String? {
        // MT-32 ROMs are deliberately *not* relocated into the gamebox
        // (decision 25). Boxer keeps its own in Application Support and reads
        // those first — `<gamebox>/MT-32 ROMs/` is only the fallback
        // (`BXSession+BXAudioControls.m:124-131`) — so a copy per gamebox is
        // 1.5 MB of duplicate ROM for every one of the 1,639 games that ask for
        // MT-32. They stay where the archive puts them and travel onto the C
        // drive like any other file, so nothing is dropped.

        for drive in plan.drives where drive.isImage {
            if drive.isBundle {
                if drive.tracks.contains(member) {
                    return drive.target + "/" + ExoDOSPlanner.basename(member)
                }
                // A descriptor is never copied: a rewritten one is written into
                // the bundle under the name Boxer looks for. An image that *is*
                // the disc still goes in, beside a descriptor we synthesise.
                if member == drive.descriptor { return nil }
                if member == drive.source {
                    return drive.target + "/" + ExoDOSPlanner.basename(member)
                }
            } else if member == drive.source {
                return drive.target
            }
        }

        let folders = plan.drives.filter { !$0.isImage }
            .sorted { $0.source.count > $1.source.count }
        for drive in folders {
            let inside = drive.insertFolder.isEmpty ? "" : drive.insertFolder + "/"
            if drive.source.isEmpty { return drive.target + "/" + inside + member }
            if member.hasPrefix(drive.source + "/") {
                return drive.target + "/" + inside
                    + String(member.dropFirst(drive.source.count + 1))
            }
        }
        return nil
    }


    // MARK: - The pieces Boxer reads back

    /// Each `.cdmedia` bundle gets a descriptor naming its tracks as plain
    /// siblings, under the one filename Boxer will look for.
    private func writeCDMediaDescriptors(into gamebox: URL) throws {
        let bundles = plan.drives.filter { $0.isBundle }
        guard !bundles.isEmpty else { return }

        let archive = try ZipArchiveReader(url: plan.sourceURL)
        let root = plan.shortName + "/"
        for drive in bundles {
            let descriptor = gamebox.appendingPathComponent(drive.target)
                .appendingPathComponent(Self.cdMediaDescriptorName)
            try FileManager.default.createDirectory(at: descriptor.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            let text: String
            if !drive.descriptor.isEmpty {
                // eXo's own cue, with its FILE paths rewritten to bare names --
                // every track now sits beside the descriptor.
                text = Self.rewriteCue(try archive.text(at: root + drive.descriptor))
            } else {
                // A bare image sharing its letter with another disc. It has no
                // cue of its own, so it gets one naming just itself.
                text = Self.synthesisedCue(for: ExoDOSPlanner.basename(drive.source),
                                           sectorSize: drive.sectorSize)
            }
            let rewritten = text.replacingOccurrences(of: "\n", with: "\r\n")
            try rewritten.write(to: descriptor, atomically: true, encoding: .utf8)
        }
    }

    /// Rewrites a cue sheet's `FILE` paths to bare filenames.
    ///
    /// Inside a `.cdmedia` bundle every track sits beside the descriptor, so
    /// any directory component the original carried would now point outside it.
    /// Boxer's own `BXDriveBundleImport` does the same thing for the same
    /// reason.
    /// A minimal cue for an image that came without one.
    ///
    /// Only reached for an image queued behind another on the same letter, where
    /// decision 18 asks for a bundle per disc. A single self-contained image is
    /// left bare precisely so this guess is not needed.
    static func synthesisedCue(for filename: String, sectorSize: Int) -> String {
        return "FILE \"\(filename)\" BINARY\n"
             + "  TRACK 01 MODE1/\(sectorSize)\n"
             + "    INDEX 01 00:00:00\n"
    }

    static func rewriteCue(_ text: String) -> String {
        var output: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("file "),
                  let range = line.range(of: "FILE", options: [.caseInsensitive]) else {
                output.append(line)
                continue
            }

            let leading = String(line[line.startIndex..<range.lowerBound])
            let rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)

            var name = ""
            var trailing = ""
            if rest.hasPrefix("\"") {
                let body = rest.dropFirst()
                if let close = body.firstIndex(of: "\"") {
                    name = String(body[body.startIndex..<close])
                    trailing = String(body[body.index(after: close)...])
                }
            } else if let space = rest.firstIndex(of: " ") {
                name = String(rest[rest.startIndex..<space])
                trailing = String(rest[space...])
            } else {
                name = rest
            }

            let bare = ExoDOSPlanner.basename(name.replacingOccurrences(of: "\\", with: "/"))
            output.append("\(leading)FILE \"\(bare)\"\(trailing)")
        }
        return output.joined(separator: "\n")
    }

    /// Writes the one-line batch files the menu interpreter asked for.
    ///
    /// A menu branch that switches MIDI device, copies a sound driver's files
    /// into place or changes drive before starting the game cannot be said as a
    /// launcher's path and arguments, so it gets a batch file of its own on the
    /// drive the menu was called from. These are written after extraction so a
    /// name clash with the archive's own files resolves in our favour.
    private func writeGeneratedBatchFiles(into gamebox: URL) throws {
        for path in plan.generatedFiles.keys.sorted() {
            let url = gamebox.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // CP437 is what DOS reads, and every one of these is ASCII anyway.
            // CP437, not ASCII: a branch's `echo` lines carry DOS box-drawing
            // characters, and `.ascii` cannot encode them — the write throws,
            // the half-built gamebox is torn down, and the import fails outright
            // on a game whose only sin is an ASCII-art banner.
            try plan.generatedFiles[path]!.write(to: url, atomically: true,
                                                 encoding: ZipArchiveReader.dosLatinUS)
        }
    }

    /// Writes the gamebox's `DOSBox Preferences.conf`.
    private func writeConfiguration(into gamebox: URL) throws {
        let url = gamebox.appendingPathComponent(BXConfigurationFileName)
            .appendingPathExtension(BXConfigurationFileExtension)
        try Self.renderConfiguration(settings: plan.settings, autoexec: plan.gameboxAutoexec)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    static func renderConfiguration(settings: [String: [String: String]],
                                    autoexec: [String]) -> String {
        var lines = [
            "# Generated by Boxer from the game's eXoDOS dosbox.conf.",
            "# In here you can specify any additional DOSBox settings or startup commands",
            "# needed for this game.",
            "",
        ]
        for section in settings.keys.sorted() {
            lines.append("[\(section)]")
            for key in settings[section]!.keys.sorted() {
                lines.append("\(key)=\(settings[section]![key]!)")
            }
            lines.append("")
        }
        // eXo's own autoexec, line for line, with the mounts, the `exit` and
        // the game's execution line commented out (decision 16). The launchers
        // start the game; everything the original did to set the machine up
        // still happens, in the order it happened in.
        lines.append("[autoexec]")
        lines.append(contentsOf: autoexec)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Writes the gamebox's `Game Info.plist`, including its launchers.
    private func writeGameInfo(into gamebox: URL) throws {
        let url = gamebox.appendingPathComponent(BXGameInfoFileName)
            .appendingPathExtension(BXGameInfoFileExtension)
        let data = try PropertyListSerialization.data(fromPropertyList: Self.gameInfo(for: plan),
                                                      format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    static func gameInfo(for plan: ExoDOSPlan) -> [String: Any] {
        var info: [String: Any] = [
            BXGameIdentifierGameInfoKey: UUID().uuidString,
            BXGameIdentifierTypeGameInfoKey: BXGameIdentifierType.UUID.rawValue,
        ]
        guard !plan.launchers.isEmpty else { return info }

        var entries: [[String: Any]] = []
        for launcher in plan.launchers {
            var entry: [String: Any] = [
                BXLauncherTitleKey: launcher.title,
                BXLauncherRelativePathKey: launcher.path,
            ]
            if !launcher.arguments.isEmpty {
                entry[BXLauncherArgsKey] = launcher.arguments.joined(separator: " ")
            }
            entries.append(entry)
        }
        // Only the launcher the autoexec's own execution line named is marked
        // default. Where it handed off to a menu we flattened, nothing is
        // marked: `BXSession.m:397-403` then leaves `targetURL` unset and Boxer
        // brings up the launch panel, which is better than guessing at eXo's
        // first menu entry (decision 21). A gamebox with exactly one launcher
        // still starts it unprompted.
        info[BXLaunchersGameInfoKey] = entries
        if let index = plan.defaultLauncher, entries.indices.contains(index) {
            entries[index][BXLauncherDefaultKey] = true
            info[BXLaunchersGameInfoKey] = entries
            info[BXTargetProgramGameInfoKey] = plan.launchers[index].path
        }
        return info
    }
}
