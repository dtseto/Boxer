//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import Foundation

/// What an eXoDOS game becomes, decided before a single byte is extracted.
///
/// Everything here is worked out from two central directories and one text
/// file: the game archive's listing, the pack's `!DOSmetadata.zip`, and the
/// `dosbox.conf` inside it. That is what lets the wizard show a complete,
/// editable plan while the user is still deciding where to put the gamebox.
struct ExoDOSPlan {
    var shortName: String
    var longName: String
    var unpackedSize: UInt64
    var sourceURL: URL

    var drives: [ExoDOSDrive] = []
    var launchers: [ExoDOSLauncher] = []

    /// Commands from the original autoexec that set the machine up rather than
    /// start the game — a mixer level, a keyboard layout, a reported DOS
    /// version. They are carried into the gamebox's own `[autoexec]`.
    var setupCommands: [String] = []

    /// The settings worth keeping, by section, already translated for 0.83.
    var settings: [String: [String: String]] = [:]

    /// MT-32 ROMs shipped with the game, at wherever the archive puts them.
    var mt32ROMs: [String] = []

    /// Whether the autoexec hands off to a batch menu with `call`. True for
    /// 2,911 of the pack's 7,633 games, and what the menu interpreter will
    /// eventually key off.
    var needsMenuInterpreter = false

    /// The original autoexec, kept so the wizard can show what it was working
    /// from and so nothing has to be re-read to explain a decision.
    var autoexec: [String] = []

    /// Small batch files the converter writes into the gamebox, keyed by their
    /// path inside it. One per menu branch that has setup to do before the game
    /// starts — see `ExoDOSMenuInterpreter`.
    var generatedFiles: [String: String] = [:]

    /// Things worth telling the user that are not problems.
    var notes: [String] = []

    /// Things the user should look at: everything the derivation could not
    /// account for, in the order it was found.
    var warnings: [String] = []

    var gameboxName: String { longName + ".boxer" }
}


/// One drive the gamebox will hold.
struct ExoDOSDrive {
    enum Kind: String {
        case hdd, floppy, cdrom

        /// Boxer names a folder drive `<letter>.<suffix>` and parses the letter
        /// back off the name (`BXDrive.m:179`).
        var folderSuffix: String {
            switch self {
            case .hdd: return "harddisk"
            case .floppy: return "floppy"
            case .cdrom: return "cdrom"
            }
        }
    }

    /// A folder drive from `mount`, or a disc image from `imgmount`.
    var isImage: Bool
    var letter: String
    var kind: Kind

    /// Where the drive's contents sit inside the game archive, relative to its
    /// root folder. Empty means the root itself.
    var source: String

    /// What the drive is called inside the gamebox.
    var target: String

    /// For a `.cdmedia` bundle, the track files the descriptor references.
    var tracks: [String] = []

    /// Whether this image becomes a `.cdmedia` bundle rather than a bare file.
    /// A descriptor plus separate tracks must: dropped at the bundle root the
    /// two are separated and each track is scanned as a drive of its own,
    /// taking the letter the descriptor asked for and losing CD audio in
    /// silence (FINDINGS.md D68).
    var isBundle: Bool = false
}


/// One entry in the gamebox's launch panel.
struct ExoDOSLauncher {
    var path: String
    var arguments: [String]
    var title: String
}


/// Builds an `ExoDOSPlan` from a game archive and its pack metadata.
///
/// This is a port of `tools/exodos-import.py`, which was written first so the
/// whole 7,633-game corpus could be run and coverage measured rather than
/// estimated. Its numbers are quoted throughout, and the two are kept
/// deliberately close enough to diff against each other game by game.
enum ExoDOSPlanner {
    enum Failure: LocalizedError {
        case notAnExoDOSGame(String)
        case noConfiguration(shortName: String, archive: String)

        var errorDescription: String? {
            switch self {
            case .notAnExoDOSGame(let reason):
                return String(format: NSLocalizedString("This is not an eXoDOS game archive (%@).",
                                                        comment: "Error when conversion is asked for a non-eXoDOS zip. %@ is the reason."),
                              reason)
            case .noConfiguration(let shortName, let archive):
                return String(format: NSLocalizedString("“%@” holds no configuration for “%@”, so there is nothing to convert from.",
                                                        comment: "Error when the metadata archive lacks a game's dosbox.conf. First %@ is the archive, second the game's short name."),
                              archive, shortName)
            }
        }
    }

    /// Where the per-game folders live inside `!DOSmetadata.zip`.
    static let metadataPrefix = "eXo/eXoDOS/!dos/"

    /// Settings worth carrying into the gamebox. This is Boxer's own whitelist
    /// from `+sanitizedVersionOfConfiguration:`
    /// (`BXImportSession+BXImportPolicies.m:458`) with two deliberate changes:
    ///
    ///  - `[midi]` gains `mididevice`. Boxer's list has only `mpu401`, so an
    ///    eXo config's `mididevice=mt32` is dropped without a word — and 772
    ///    configs in the pack set it.
    ///  - `[cpu]` loses `cycles`, which is handled separately below: 0.83
    ///    deprecated it, and leaving one in the file puts 0.83 back into its
    ///    legacy cycles mode (`BXSession.m:867-875`).
    static let relevantSettings: [String: Set<String>] = [
        "dosbox":   ["machine", "memsize"],
        "dos":      ["ems", "xms", "umb"],
        "cpu":      ["core", "cputype"],
        "midi":     ["mpu401", "mididevice"],
        "sblaster": ["sbtype", "sbbase", "irq", "dma", "hdma",
                     "oplmode", "oplemu", "sbmixer"],
        "gus":      ["gus", "gusbase", "gusirq", "gusdma"],
        "speaker":  ["pcspeaker", "tandy", "disney"],
    ]

    /// Image extensions Boxer maps to a mountable type (`BXFileTypes.m:224`).
    /// Anything else falls back to UTI sniffing, which an import should not
    /// rely on, so an unmapped image raises a warning rather than failing
    /// silently later.
    static let knownImageExtensions: Set<String> = ["cue", "inst", "iso", "cdr", "mds", "ima", "vfd", "gog"]

    /// Descriptors that name track files sitting beside them.
    static let descriptorExtensions: Set<String> = ["cue", "inst"]

    /// Commands that stand in front of the program actually being launched, so
    /// the real target is whatever follows them.
    static let prefixCommands: Set<String> = ["call", "loadfix", "start"]

    /// Commands that set the machine up rather than start the game. Throwing
    /// them away would lose real behaviour, so they are carried across.
    static let setupCommands: Set<String> = ["mixer", "path", "ver", "keyb", "loadrom",
                                             "copy", "del", "md", "mkdir", "setver"]

    /// Pure control flow, and eXo's own Windows-side helpers: nothing a gamebox
    /// needs to keep.
    static let ignoredCommands: Set<String> = ["mount", "imgmount", "exit", "cls", "echo",
                                               "rem", "pause", "set", "choice", "if",
                                               "goto", "aspect"]

    /// The folder Boxer searches for MT-32 ROMs, matching filenames against
    /// `control` and `pcm` (`BXSession+BXAudioControls.m:255`).
    static let mt32ROMDirectory = "MT-32 ROMs"


    // MARK: - The whole plan

    /// Works out what the game archive at `gameURL` should become, reading its
    /// configuration out of the pack's metadata archive.
    static func plan(gameArchiveAt gameURL: URL,
                     metadataArchiveAt metadataURL: URL,
                     classification: BXArchiveClassification? = nil) throws -> ExoDOSPlan {
        let verdict: BXArchiveClassification
        if let classification = classification {
            verdict = classification
        } else {
            verdict = try BXImportClassifier.classifyArchive(at: gameURL)
        }
        guard verdict.kind == .exoDOSGame,
              let shortName = verdict.shortName,
              let longName = verdict.gameTitle
        else {
            throw Failure.notAnExoDOSGame(verdict.rejectionReason ?? verdict.localizedSummary)
        }

        let archive = try ZipArchiveReader(url: gameURL)
        let root = shortName + "/"
        var members = Set<String>()
        for path in archive.directory.paths where path.count > root.count
            && path.lowercased().hasPrefix(root.lowercased()) {
            members.insert(String(path.dropFirst(root.count)))
        }

        let configuration = try readConfiguration(shortName: shortName, metadataArchiveAt: metadataURL)

        var plan = ExoDOSPlan(shortName: shortName,
                              longName: longName,
                              unpackedSize: verdict.unpackedSize,
                              sourceURL: gameURL)
        plan.autoexec = configuration.autoexec

        let (drives, driveWarnings) = planDrives(autoexec: configuration.autoexec,
                                                 shortName: shortName,
                                                 members: members) { path in
            try? archive.text(at: root + path)
        }
        plan.drives = drives

        let launch = planLaunchers(autoexec: configuration.autoexec, drives: drives,
                                   members: members) { path in
            try? archive.text(at: root + path)
        }
        plan.launchers = launch.launchers
        plan.setupCommands = launch.setup
        plan.needsMenuInterpreter = launch.needsInterpreter
        plan.generatedFiles = launch.generatedFiles

        let derived = planSettings(configuration.sections)
        plan.settings = derived.settings
        plan.notes = launch.notes + derived.notes

        plan.mt32ROMs = mt32ROMs(in: members)
        if !plan.mt32ROMs.isEmpty {
            plan.notes.append("relocating \(plan.mt32ROMs.count) MT-32 ROM(s) into '\(mt32ROMDirectory)'")
        }

        plan.warnings = driveWarnings + launch.warnings
        if drives.isEmpty { plan.warnings.append("no drives were mounted by the autoexec") }
        if plan.launchers.isEmpty { plan.warnings.append("no launch command was found") }

        return plan
    }


    // MARK: - Reading the configuration

    struct Configuration {
        var sections: [String: [String: String]] = [:]
        var autoexec: [String] = []
    }

    /// Splits a DOSBox config into sections plus the autoexec.
    ///
    /// Tolerates the 32 DOSBox-X configs in the pack, whose long comment blocks
    /// sit between the section headers.
    static func parseConfiguration(_ text: String) -> Configuration {
        var configuration = Configuration()
        var current: String?

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let section = current else { continue }

            if section == "autoexec" {
                configuration.autoexec.append(line)
            } else if let separator = line.firstIndex(of: "=") {
                let key = String(line[line.startIndex..<separator])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                configuration.sections[section, default: [:]][key] = value
            }
        }
        return configuration
    }

    /// Pulls `!dos/<short>/dosbox.conf` out of the metadata archive.
    ///
    /// An eXoDOS game holds no configuration of its own: the drive layout, the
    /// launch command and the machine settings all come from here, which is why
    /// the pack is a hard requirement rather than a nicety (decision 10).
    static func readConfiguration(shortName: String, metadataArchiveAt url: URL) throws -> Configuration {
        let archive = try metadataArchive(at: url)
        let path = metadataPrefix + shortName + "/dosbox.conf"
        guard let entry = archive.entry(at: path) else {
            throw Failure.noConfiguration(shortName: shortName, archive: url.lastPathComponent)
        }
        return parseConfiguration(try archive.text(at: entry.path))
    }

    /// The metadata archive is opened once and kept.
    ///
    /// It holds 30,818 entries, and a batch conversion asks it for one game
    /// after another; re-reading its central directory each time is the
    /// difference between a minute and an afternoon (481 ms to index, 1 ms a
    /// game thereafter).
    private static func metadataArchive(at url: URL) throws -> ZipArchiveReader {
        metadataCacheLock.lock()
        defer { metadataCacheLock.unlock() }

        let key = url.standardizedFileURL.path
        if let cached = metadataCache[key] { return cached }
        let archive = try ZipArchiveReader(url: url)
        metadataCache[key] = archive
        return archive
    }

    private static var metadataCache: [String: ZipArchiveReader] = [:]
    private static let metadataCacheLock = NSLock()

    /// Drops the metadata archive Boxer is holding open, if any.
    static func forgetCachedMetadata() {
        metadataCacheLock.lock()
        metadataCache.removeAll()
        metadataCacheLock.unlock()
    }


    // MARK: - Drives

    /// Works out the gamebox's drive layout from the autoexec's mount commands.
    ///
    /// `members` is every path inside the game archive, relative to its root
    /// folder, which is what says whether a mounted folder or image is actually
    /// shipped — 327 games in the pack mount something that is not.
    static func planDrives(autoexec: [String],
                           shortName: String,
                           members: Set<String>,
                           readMember: ((String) -> String?)? = nil) -> ([ExoDOSDrive], [String]) {
        var drives: [ExoDOSDrive] = []
        var warnings: [String] = []

        for raw in autoexec {
            let command = stripPrefix(raw)
            let verb = command.components(separatedBy: " ").first?.lowercased() ?? ""
            guard verb == "mount" || verb == "imgmount" else { continue }

            let tokens = splitCommand(command)
            guard tokens.count >= 3 else {
                warnings.append("unparseable mount command: \(command)")
                continue
            }

            let letter = tokens[1].lowercased()
            guard letter.count == 1, let character = letter.first,
                  character >= "a" && character <= "x" else {
                warnings.append("unusable drive letter '\(tokens[1])' in: \(command)")
                continue
            }

            let media = mediaType(flags: Array(tokens.dropFirst(3)))
            guard let source = packRelativePath(tokens[2], shortName: shortName, members: members) else {
                warnings.append("mount path outside the game folder, skipped: \(command)")
                continue
            }

            if verb == "mount" {
                let kind = media ?? (letter == "a" ? .floppy : .hdd)
                if !source.isEmpty && !members.contains(source) {
                    warnings.append("mounts a folder the archive does not ship: \(command)")
                }
                drives.append(ExoDOSDrive(isImage: false, letter: letter, kind: kind,
                                          source: source,
                                          target: "\(letter.uppercased()).\(kind.folderSuffix)"))
                continue
            }

            let ext = pathExtension(source).lowercased()
            if !knownImageExtensions.contains(ext) {
                warnings.append("image type .\(ext) is not in Boxer's extension map: \(command)")
            }
            if !members.contains(source) {
                warnings.append("mounts an image the archive does not ship: \(command)")
            }

            if descriptorExtensions.contains(ext), let readMember = readMember,
               members.contains(source), let text = readMember(source) {
                // A descriptor plus separate track files goes into a .cdmedia
                // bundle, which keeps them together and keeps the tracks out of
                // Boxer's drive scan.
                var tracks: [String] = []
                var missing: [String] = []
                for name in cueTrackNames(in: text) {
                    if let resolved = resolveTrack(name, cuePath: source, members: members) {
                        tracks.append(resolved)
                    } else {
                        missing.append(name)
                    }
                }
                if !missing.isEmpty {
                    warnings.append("cue sheet references \(missing.count) file(s) the archive does not ship (\(missing.prefix(3).joined(separator: ", "))): \(command)")
                }
                drives.append(ExoDOSDrive(isImage: true, letter: letter, kind: media ?? .cdrom,
                                          source: source,
                                          target: "\(letter.uppercased()).cdmedia",
                                          tracks: tracks, isBundle: true))
            } else {
                // A self-contained image needs no bundle: Boxer parses the
                // drive letter back off the filename, so it keeps its own name
                // behind a "<letter> " prefix.
                drives.append(ExoDOSDrive(isImage: true, letter: letter, kind: media ?? .hdd,
                                          source: source,
                                          target: "\(letter.uppercased()) \(basename(source))"))
            }
        }
        return (drives, warnings)
    }

    /// Resolves one of eXo's pack-root-relative paths against the game folder.
    ///
    /// This is the trap behind Boxer's own mount-command import: eXo writes
    /// `mount c .\eXoDOS\dune`, relative to the *pack root*, while the config
    /// it is written in lives in a different archive under `!dos/dune/`. Boxer
    /// resolves it against the config's own directory
    /// (`BXImportSession.m:807`), gets `!dos/dune/eXoDOS/dune`, fails to find
    /// it, and then — in its own comment — "pretends everything's OK"
    /// (`BXImportSession.m:1156`), leaving an empty gamebox and no error.
    ///
    /// Returns nil when the path points somewhere outside the game's folder,
    /// which the caller reports rather than guesses at.
    static func packRelativePath(_ dosPath: String, shortName: String, members: Set<String>?) -> String? {
        let normalised = dosPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = normalised.components(separatedBy: "/").filter { !$0.isEmpty && $0 != "." }

        // The common shape: eXoDOS/<short>[/more...].
        if parts.count >= 2, parts[0].lowercased() == "exodos",
           parts[1].lowercased() == shortName.lowercased() {
            return canonical(parts.dropFirst(2).joined(separator: "/"), members: members)
        }

        // 1,521 games instead mount the pack's whole `eXoDOS` folder as C: and
        // then `cd` into the game from there. A gamebox holds one game, so the
        // game's own folder is the right thing to mount, and the `cd` that
        // follows becomes a no-op that the launcher walk absorbs.
        if parts.count == 1, parts[0].lowercased() == "exodos" { return "" }

        // Anything else may still be shipped inside the game folder — some
        // games imgmount their discs as `.\discs\1.cue`, which is where the
        // archive puts them, whatever that path means to DOSBox's own resolver.
        // Believe the archive rather than the path when the two reconcile.
        if let members = members {
            let candidate = parts.joined(separator: "/")
            if let hit = caseInsensitiveLookup(candidate, in: members) { return hit }
        }
        return nil
    }

    /// Reads the media type off a mount command's `-t` flag.
    ///
    /// The pack spells a CD-ROM two ways — `-t cdrom` 1,247 times and `-t iso`
    /// another 88 — and matching only the first silently demotes 88 CD drives
    /// to hard disks.
    static func mediaType(flags: [String]) -> ExoDOSDrive.Kind? {
        let lowered = flags.map { $0.lowercased() }
        guard let index = lowered.firstIndex(of: "-t"), index + 1 < lowered.count else { return nil }
        switch lowered[index + 1] {
        case "cdrom", "iso": return .cdrom
        case "floppy": return .floppy
        case "hdd": return .hdd
        default: return nil
        }
    }

    /// The track filenames a cue sheet references, in order.
    static func cueTrackNames(in text: String) -> [String] {
        var names: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("file") else { continue }
            let rest = String(trimmed.dropFirst(4))
            guard let first = rest.first, first == " " || first == "\t" else { continue }
            let argument = rest.trimmingCharacters(in: .whitespaces)
            if argument.hasPrefix("\"") {
                let body = argument.dropFirst()
                if let close = body.firstIndex(of: "\"") {
                    names.append(String(body[body.startIndex..<close]))
                }
            } else if let token = argument.components(separatedBy: .whitespaces).first, !token.isEmpty {
                names.append(token)
            }
        }
        return names
    }

    /// Finds a cue's track file, which normally sits beside the cue itself.
    static func resolveTrack(_ name: String, cuePath: String, members: Set<String>) -> String? {
        let relative = name.replacingOccurrences(of: "\\", with: "/")
        let directory = dirname(cuePath)
        let candidate = directory.isEmpty ? relative : directory + "/" + relative
        return caseInsensitiveLookup(candidate, in: members)
            ?? caseInsensitiveLookup(relative, in: members)
    }


    // MARK: - Launchers

    struct LaunchPlan {
        var launchers: [ExoDOSLauncher] = []
        var warnings: [String] = []
        var setup: [String] = []
        var needsInterpreter = false

        /// Things worth saying about the menu that are not problems: how many
        /// ways to start the game it offered, or why it could not be flattened.
        var notes: [String] = []

        /// Small batch files the converter writes into the gamebox, keyed by
        /// their path inside it. One per menu branch that has something to do
        /// before the game starts — switching MIDI device, copying a sound
        /// driver's files into place, or changing to another drive — none of
        /// which a launcher's path-and-arguments can express on its own.
        var generatedFiles: [String: String] = [:]
    }

    /// Decides what the gamebox should launch.
    ///
    /// Most games need no batch interpretation at all: only 2,911 of the 7,633
    /// configs hand off to a `run.bat` menu with `call`, and the rest launch the
    /// executable straight from the autoexec, where the command is already
    /// sitting in plain sight.
    ///
    /// Where a `call` *is* present the batch file itself is registered as the
    /// launcher, which reproduces eXo's own DOS menu inside Boxer. That is the
    /// honest floor until the menu interpreter lands: turning those menus into
    /// separate launchers is an interpreter's job, not a label scraper's — they
    /// nest, their branches set environment variables and change directory, and
    /// some labels fall through to a different executable entirely.
    static func planLaunchers(autoexec: [String],
                              drives: [ExoDOSDrive],
                              members: Set<String>,
                              text: (String) -> String? = { _ in nil }) -> LaunchPlan {
        var plan = LaunchPlan()
        // Last mount of a letter wins, as it does in DOSBox itself.
        var byLetter: [String: ExoDOSDrive] = [:]
        for drive in drives { byLetter[drive.letter] = drive }

        var current = drives.first(where: { $0.kind == .hdd })?.letter ?? "c"
        var workingDirectory = ""

        for raw in autoexec {
            let command = stripPrefix(raw)
            if command.isEmpty || command.hasPrefix(":") { continue }
            let lowered = command.lowercased()

            // `echo.` is the DOS idiom for a blank line, and is far and away the
            // commonest of these: it is one token, not `echo` plus an argument,
            // so a plain word match misses it.
            let head = String(lowered.prefix(while: { $0 != " " && $0 != "\t" && $0 != "=" }))
            if ignoredCommands.contains(head) ||
               ignoredCommands.contains(head.trimmingTrailing(".")) { continue }
            if setupCommands.contains(head) {
                plan.setup.append(command)
                continue
            }

            // `boot` hands a disk image to the BIOS rather than running a
            // program. A Boxer launcher is a path plus arguments, so there is
            // nothing to point it at; such a game needs a hand-built boot drive.
            if head == "boot" {
                plan.warnings.append("boots a disk image, which a launcher cannot express: \(command)")
                continue
            }

            // A bare drive change tracks the working drive for what follows.
            if let letter = driveChange(in: lowered) {
                current = letter
                workingDirectory = ""
                continue
            }

            // `cd` is the other half of the pack's second-commonest shape:
            // mount the whole eXoDOS folder, then `cd` into the game. Tracking
            // it is what turns the command that follows into a path we can
            // resolve — without it, `cd` itself looks like a program that is not
            // there, which is the single largest source of noise in a corpus run.
            if let argument = changeDirectoryArgument(in: lowered) {
                workingDirectory = applyChangeDirectory(workingDirectory, argument: argument, members: members)
                continue
            }

            var tokens = splitCommand(command)
            guard !tokens.isEmpty else { continue }
            var target: String? = tokens.removeFirst()
            var arguments = tokens
            var wasCall = false

            while let candidate = target, prefixCommands.contains(candidate.lowercased()) {
                if candidate.lowercased() == "call" {
                    plan.needsInterpreter = true
                    wasCall = true
                }
                // `loadfix` and `loadfix -64` have no program behind them; they
                // just eat memory for whatever runs next.
                while let first = arguments.first, isNumericFlag(first) { arguments.removeFirst() }
                if arguments.isEmpty { target = nil; break }
                target = arguments.removeFirst()
            }
            guard let program = target else { continue }

            let drive = byLetter[current]
            let prefix = (drive != nil && !drive!.isImage) ? drive!.target + "/" : ""
            guard let resolved = resolveProgram(program, drive: drive,
                                                members: members, workingDirectory: workingDirectory) else {
                plan.warnings.append("cannot find '\(program)' on drive \(current): \(command)")
                continue
            }

            // A `call` reaches one of eXo's menus. Where the menu can be read
            // and accounted for, each of its branches becomes a launcher of its
            // own; where it cannot, the batch file stays the launcher and eXo's
            // menu comes up inside Boxer, which is what happened before this and
            // is still a working game.
            if wasCall, let source = drive?.source,
               let text = text(source.isEmpty ? resolved : source + "/" + resolved) {
                let flattened = flattenMenu(text,
                                            batchPath: prefix + resolved,
                                            drive: current,
                                            workingDirectory: workingDirectory,
                                            byLetter: byLetter,
                                            members: members,
                                            plan: &plan)
                if flattened { continue }
            }

            plan.launchers.append(ExoDOSLauncher(path: prefix + resolved,
                                                 arguments: arguments,
                                                 title: stripExtension(basename(resolved))))
        }
        return plan
    }

    /// Turns one of eXo's menu batch files into a launcher per branch.
    ///
    /// Returns false when the menu could not be accounted for, which leaves the
    /// caller to register the batch file itself as the launcher — eXo's own DOS
    /// menu, inside Boxer, which is what every one of these games did before.
    private static func flattenMenu(_ text: String,
                                    batchPath: String,
                                    drive: String,
                                    workingDirectory: String,
                                    byLetter: [String: ExoDOSDrive],
                                    members: Set<String>,
                                    plan: inout LaunchPlan) -> Bool {
        let branches: [ExoDOSMenuBranch]
        do {
            branches = try ExoDOSMenuInterpreter.flatten(text, drive: drive,
                                                         workingDirectory: workingDirectory)
        } catch let failure as ExoDOSMenuInterpreter.Unflattenable {
            plan.notes.append("'\(basename(batchPath))' \(failure.reason), so it stays the launcher and its menu comes up in Boxer")
            return false
        } catch {
            return false
        }

        var launchers: [ExoDOSLauncher] = []
        var generated: [String: String] = [:]
        var usedNames = Set<String>()

        for (index, branch) in branches.enumerated() {
            let title = branch.composedTitle
            let target = byLetter[branch.drive]

            var tokens = splitCommand(branch.command)
            guard !tokens.isEmpty else { continue }
            let program = tokens.removeFirst()
            let arguments = tokens

            // A branch that ends on an image drive cannot be checked against
            // anything — the archive ships the disc, not its contents — and a
            // branch that has to change drive or directory first cannot be said
            // as a path plus arguments either. Both get a batch file.
            let resolved = resolveProgram(program, drive: target, members: members,
                                          workingDirectory: branch.workingDirectory)
            let needsBatch = !branch.setup.isEmpty
                || branch.drive != drive
                || !branch.workingDirectory.isEmpty
                || resolved == nil

            if !needsBatch, let resolved = resolved, let target = target {
                launchers.append(ExoDOSLauncher(path: target.target + "/" + resolved,
                                                arguments: arguments,
                                                title: title ?? stripExtension(basename(resolved))))
                continue
            }

            // A branch ending on an image drive cannot be checked — the archive
            // ships the disc, not its contents — but one on a folder drive can,
            // and a program that is not there means the menu has been read
            // wrongly. Rather than quietly drop that entry and offer the user a
            // shorter menu than eXo did, give the whole file up and let the
            // batch stay the launcher.
            if resolved == nil, let target = target, !target.isImage {
                plan.notes.append("'\(basename(batchPath))' runs '\(program)', which drive \(branch.drive) does not hold, so it stays the launcher and its menu comes up in Boxer")
                return false
            }

            let name = uniqueBatchName(for: title ?? stripExtension(basename(program)),
                                       index: index, taken: &usedNames)
            let folder = (batchPath as NSString).deletingLastPathComponent
            let path = folder.isEmpty ? name : folder + "/" + name
            generated[path] = renderBranchBatch(branch, program: program, arguments: arguments)
            launchers.append(ExoDOSLauncher(path: path,
                                            arguments: [],
                                            title: title ?? stripExtension(basename(program))))
        }

        guard !launchers.isEmpty else { return false }
        plan.launchers.append(contentsOf: launchers)
        plan.generatedFiles.merge(generated) { _, new in new }
        plan.notes.append("'\(basename(batchPath))' offered \(launchers.count) way(s) to start the game; each is its own launcher")
        return true
    }

    /// Writes out one menu branch as a batch file the gamebox can launch.
    static func renderBranchBatch(_ branch: ExoDOSMenuBranch,
                                  program: String,
                                  arguments: [String]) -> String {
        var lines = ["@echo off",
                     "rem Generated by Boxer from this game's eXoDOS menu."]
        lines.append(contentsOf: branch.setup)
        lines.append("\(branch.drive):")
        if !branch.workingDirectory.isEmpty {
            lines.append("cd \(branch.workingDirectory.replacingOccurrences(of: "/", with: "\\"))")
        }
        lines.append(([program] + arguments).joined(separator: " "))
        // DOS wants CRLF, and wants the file to end with one.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A DOS-safe, unique 8.3 name for a branch's batch file.
    private static func uniqueBatchName(for title: String, index: Int, taken: inout Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics
        var stem = String(title.unicodeScalars.filter { allowed.contains($0) })
            .uppercased()
            .prefix(6)
        if stem.isEmpty { stem = "PLAY" }

        var name = "\(stem)\(index + 1).BAT"
        var suffix = index + 1
        while taken.contains(name.lowercased()) {
            suffix += 1
            name = "\(stem)\(suffix).BAT"
        }
        taken.insert(name.lowercased())
        return name
    }

    /// Applies one `cd` to the tracked working directory.
    ///
    /// Checked against what the archive actually ships, which settles the no-op
    /// case without special-casing it: where the config mounted the pack's whole
    /// eXoDOS folder as C:, the `cd <game>` that follows is reaching for a
    /// directory that is already the root of our C drive. It resolves to nothing
    /// the archive has, stripping its first component does, so it is dropped.
    static func applyChangeDirectory(_ current: String, argument: String, members: Set<String>) -> String {
        if argument.isEmpty || argument == "\\" || argument == "/" { return "" }

        var result = current
        let parts = argument.replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/").filter { !$0.isEmpty && $0 != "." }
        for part in parts {
            if part == ".." {
                result = dirname(result)
            } else {
                result = result.isEmpty ? part : result + "/" + part
            }
        }

        if result.isEmpty || isDirectory(result, in: members) { return result }
        guard let slash = result.firstIndex(of: "/") else { return "" }
        let trimmed = String(result[result.index(after: slash)...])
        if trimmed.isEmpty || isDirectory(trimmed, in: members) { return trimmed }
        return result
    }

    /// Does the archive ship anything under this directory?
    static func isDirectory(_ path: String, in members: Set<String>) -> Bool {
        let prefix = path.lowercased() + "/"
        return members.contains { $0.lowercased().hasPrefix(prefix) }
    }

    /// Finds the file a bare DOS command refers to, inside the mounted folder.
    ///
    /// DOS resolves an extensionless command against .COM, .EXE then .BAT, and
    /// the archive's casing will not match the config's, so both are handled
    /// here. The command is looked for in the tracked working directory first
    /// and then at the root of the drive, which is how DOS itself would find it.
    static func resolveProgram(_ target: String,
                               drive: ExoDOSDrive?,
                               members: Set<String>,
                               workingDirectory: String = "") -> String? {
        guard let drive = drive, !drive.isImage else { return nil }
        let base = drive.source
        let wanted = target.replacingOccurrences(of: "\\", with: "/")
            .drop(while: { $0 == "/" })
        let name = String(wanted)

        let candidates = pathExtension(name).isEmpty
            ? [".com", ".exe", ".bat"].map { name + $0 }
            : [name]

        for directory in (workingDirectory.isEmpty ? [""] : [workingDirectory, ""]) {
            for candidate in candidates {
                let relative = directory.isEmpty ? candidate : directory + "/" + candidate
                let full = base.isEmpty ? relative : base + "/" + relative
                if let hit = caseInsensitiveLookup(full, in: members) {
                    return base.isEmpty ? hit : String(hit.dropFirst(base.count + 1))
                }
            }
        }
        return nil
    }


    // MARK: - Settings

    /// Carries the settings worth keeping, and fixes up the ones 0.83 renamed.
    static func planSettings(_ sections: [String: [String: String]]) -> (settings: [String: [String: String]], notes: [String]) {
        var settings: [String: [String: String]] = [:]
        var notes: [String] = []

        for (section, keys) in relevantSettings {
            for key in keys.sorted() {
                if let value = sections[section]?[key], !value.isEmpty {
                    settings[section, default: [:]][key] = value
                }
            }
        }

        // 0.83 split `cycles` into a real-mode and a protected-mode setting.
        // Boxer writes `cpu_cycles` with `cpu_cycles_protected=auto` following
        // it and clears any `cycles` key, because leaving one puts 0.83 into its
        // legacy cycles mode and overrides both (`BXSession.m:867-875`, D39).
        // Carrying eXo's `cycles` through verbatim — which Boxer's own whitelist
        // would do — lands every imported game in that legacy mode.
        if let cycles = sections["cpu"]?["cycles"], !cycles.isEmpty {
            settings["cpu", default: [:]]["cpu_cycles"] = cycles
            settings["cpu"]?["cpu_cycles_protected"] = "auto"
            notes.append("cycles=\(cycles) carried across as cpu_cycles (0.83 renamed it)")
        }

        if settings["midi"]?["mididevice"] == "mt32" {
            notes.append("game asks for MT-32")
        }
        return (settings, notes)
    }

    /// Locates MT-32 ROMs shipped with the game, wherever they happen to sit.
    ///
    /// Three sources disagree about where these live: the config says
    /// `mt32.romdir=.\mt32` relative to the pack root, games such as Monkey
    /// Island ship them at the top level of the game folder instead, and Boxer
    /// looks only in `<gamebox>/MT-32 ROMs/`, matching names against `control`
    /// and `pcm` (`BXSession+BXAudioControls.m:255`). So we find them and move
    /// them.
    static func mt32ROMs(in members: Set<String>) -> [String] {
        members.filter { member in
            let name = basename(member).lowercased()
            return name.hasSuffix(".rom") && (name.contains("control") || name.contains("pcm"))
        }.sorted()
    }


    // MARK: - Small shared helpers

    /// Drops the leading `@` and whitespace DOSBox allows on autoexec lines.
    static func stripPrefix(_ command: String) -> String {
        String(command.drop(while: { $0 == "@" || $0 == " " || $0 == "\t" }))
    }

    /// Tokenises a DOS command, honouring double quotes around paths.
    ///
    /// A quote only opens a token when it is the token's first character:
    /// `"disk 1.ima"-t` is two tokens, the quoted path and `-t`, which is how
    /// DOSBox reads it and how ShadowCaster's five-floppy `imgmount` gets its
    /// media type. Treating the quote as a mode that spans the rest of the run
    /// instead swallows the `-t` and quietly mounts its floppies as hard disks.
    static func splitCommand(_ command: String) -> [String] {
        var tokens: [String] = []
        var index = command.startIndex

        while index < command.endIndex {
            if command[index] == " " || command[index] == "\t" {
                index = command.index(after: index)
                continue
            }

            if command[index] == "\"",
               let close = command[command.index(after: index)...].firstIndex(of: "\"") {
                tokens.append(String(command[command.index(after: index)..<close]))
                index = command.index(after: close)
                continue
            }

            var end = index
            while end < command.endIndex, command[end] != " ", command[end] != "\t" {
                end = command.index(after: end)
            }
            let token = command[index..<end].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !token.isEmpty { tokens.append(token) }
            index = end
        }
        return tokens
    }

    /// `c:` or `d:\` — a bare drive change and nothing else.
    static func driveChange(in lowered: String) -> String? {
        var text = lowered
        if text.hasSuffix("\\") { text = String(text.dropLast()) }
        guard text.count == 2, text.hasSuffix(":"),
              let letter = text.first, letter >= "a", letter <= "x" else { return nil }
        return String(letter)
    }

    /// The argument of a `cd` command, or nil if this is not one.
    ///
    /// `cd..` and `cd\` are as valid in DOS as `cd ..`, so the separator is
    /// optional — but only in front of a path. Without that restriction `cdkaw`
    /// reads as `cd kaw`, and the four games in the pack whose executable
    /// happens to start with those two letters lose their launch command
    /// entirely, silently and with no warning to show for it.
    static func changeDirectoryArgument(in lowered: String) -> String? {
        guard lowered == "cd" || lowered.hasPrefix("cd") else { return nil }
        let rest = String(lowered.dropFirst(2))
        guard rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t")
                || rest.hasPrefix(".") || rest.hasPrefix("\\") || rest.hasPrefix("/") else { return nil }

        var argument = rest.trimmingCharacters(in: .whitespaces)
        if argument.hasPrefix("\\") { argument = String(argument.dropFirst()) }
        return argument.trimmingCharacters(in: .whitespaces)
    }

    private static func isNumericFlag(_ token: String) -> Bool {
        guard token.hasPrefix("-"), token.count > 1 else { return false }
        return token.dropFirst().allSatisfy { $0.isNumber }
    }

    /// Returns a path spelled the way the archive spells it.
    ///
    /// eXo's configs do not always match their own archives' casing — the pack
    /// has at least one such mismatch — and on a case-insensitive Mac volume
    /// that is invisible until something compares the two exactly.
    /// Canonicalising here means every later comparison, extraction and
    /// membership test can be exact. Doing it moved clean plans from 90.3% to
    /// 91.0% on its own: 53 games whose only problem was letter case.
    static func canonical(_ path: String, members: Set<String>?) -> String {
        guard !path.isEmpty, let members = members else { return path }
        return caseInsensitiveLookup(path, in: members) ?? path
    }

    static func caseInsensitiveLookup(_ path: String, in members: Set<String>) -> String? {
        if members.contains(path) { return path }
        let wanted = path.lowercased()
        return members.first { $0.lowercased() == wanted }
    }

    static func basename(_ path: String) -> String {
        path.components(separatedBy: "/").last ?? path
    }

    static func dirname(_ path: String) -> String {
        var parts = path.components(separatedBy: "/")
        guard parts.count > 1 else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    static func pathExtension(_ path: String) -> String {
        let name = basename(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    static func stripExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex..<dot])
    }
}


private extension String {
    func trimmingTrailing(_ character: Character) -> String {
        var result = self
        while result.last == character { result.removeLast() }
        return result
    }
}
