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

    /// The autoexec the gamebox gets: eXo's own, line for line, with three
    /// kinds of line commented out rather than deleted — the mounts, which
    /// became drives; `exit`, which would end the session when the game
    /// returns; and the game's own execution line, which the launchers replace
    /// (decision 16). Everything else is carried through with eXo's
    /// pack-relative prefix stripped (decision 20).
    var gameboxAutoexec: [String] = []

    /// Whether the gamebox should open at the DOS view rather than behind the
    /// loading veil, because its autoexec stops to talk to the player.
    var showsDOSViewAtStartup = false

    /// Which launcher the gamebox starts by default, if any.
    ///
    /// Nil where the autoexec handed off to a menu we flattened: eXo's first
    /// menu entry tends to be the oldest or most limited way to play, so Boxer
    /// shows the launch panel instead of picking one (decision 21).
    var defaultLauncher: Int?

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

    /// What the drive is called inside the gamebox. Given its final value by
    /// `nameDrives`, once every mount is known — the number a queued volume
    /// carries depends on how many siblings share its letter.
    var target: String

    /// The drive's own name, before a letter and any number are put in front of
    /// it: a folder's name, or an image's filename. For a folder drive this is
    /// what reaches DOS as the volume label, which is why the number is only
    /// added when a letter really does carry a queue (decision 19).
    var name: String = ""

    /// A folder inserted between the drive and the archive's contents.
    ///
    /// Only the 1,521 games that mount the pack's whole games folder use it:
    /// their C drive is the game folder's *parent*, so the game goes inside a
    /// folder of its own and the `cd <short>` in the autoexec stays literally
    /// correct (decision 20).
    var insertFolder: String = ""

    /// The cue sheet this bundle was built from, if it had one. A bundle
    /// without one gets a synthesised descriptor instead.
    var descriptor: String = ""

    /// Bytes of user data per sector, for a descriptor we synthesise.
    var sectorSize: Int = 2048

    /// Where the game's own files sit inside the gamebox — the drive, plus the
    /// folder inserted in front of them for the 1,521 games whose C drive is
    /// the game folder's parent (decision 20). Every path the gamebox records,
    /// launchers included, is relative to this.
    var contentRoot: String {
        insertFolder.isEmpty ? target : target + "/" + insertFolder
    }

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
    ///
    /// `start` is deliberately **not** here. DOSBox-staging implements no such
    /// command, so in an eXo autoexec `start` is always the game's own
    /// `START.BAT` or `START.COM` — 124 lines in the pack use it that way.
    /// Treating it as a prefix swallowed the target and left 115 games with no
    /// launcher at all, and fed Epic's `start SOUND=S EPIC=C:\` to the resolver
    /// as though `SOUND=S` were a program.
    static let prefixCommands: Set<String> = ["call", "loadfix"]

    /// Commands that wait for the player, and so decide what the window shows.
    ///
    /// Boxer runs the autoexec behind a loading veil and lifts it when a
    /// *program* starts (`-[BXSession emulatorWillStartProgram:]`, which arms
    /// `_showDOSViewAfterProgramStart`). `pause` and `choice` are shell
    /// builtins, not programs, so nothing fires and the veil stays up — the
    /// keypress can never be given and the session hangs on its spinner.
    ///
    /// These lines are **kept**, because the message above a `pause` is
    /// addressed to the player and the `pause` is what makes it readable —
    /// eXo's own "press Ctrl-F4 to switch discs", say. What changes instead is
    /// the window: a gamebox whose autoexec waits asks Boxer to start at the
    /// DOS view rather than behind the veil
    /// (`BXShowDOSViewAtStartupGameInfoKey`). 261 games in the pack `pause` in
    /// their autoexec and 2 `choice`.
    static let interactiveCommands: Set<String> = ["pause", "choice"]

    /// Commands that set the machine up rather than start the game. Throwing
    /// them away would lose real behaviour, so they are carried across.
    static let setupCommands: Set<String> = ["mixer", "path", "ver", "keyb", "loadrom",
                                             "copy", "del", "md", "mkdir", "setver"]

    /// Pure control flow, and eXo's own Windows-side helpers: nothing a gamebox
    /// needs to keep.
    static let ignoredCommands: Set<String> = ["mount", "imgmount", "exit", "cls", "echo",
                                               "rem", "pause", "set", "choice", "if",
                                               "goto", "aspect"]

    /// The folder Boxer searches inside a gamebox for MT-32 ROMs, matching
    /// filenames against `control` and `pcm` (`BXSession+BXAudioControls.m:255`).
    ///
    /// Nothing is written here any more — decision 25 — but it is the name to
    /// use if that is ever reversed.
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

        var sizes: [String: UInt64] = [:]
        for entry in archive.directory.entries where !entry.isDirectory
            && entry.path.count > root.count
            && entry.path.lowercased().hasPrefix(root.lowercased()) {
            sizes[String(entry.path.dropFirst(root.count))] = entry.uncompressedSize
        }

        let (drives, driveWarnings) = planDrives(autoexec: configuration.autoexec,
                                                 shortName: shortName,
                                                 members: members,
                                                 sizeOf: { sizes[$0] }) { path in
            try? archive.text(at: root + path)
        }
        plan.drives = drives

        let launch = planLaunchers(autoexec: configuration.autoexec, drives: drives,
                                   members: members, shortName: shortName) { path in
            try? archive.text(at: root + path)
        }
        plan.launchers = launch.launchers
        plan.setupCommands = launch.setup
        plan.needsMenuInterpreter = launch.needsInterpreter
        plan.generatedFiles = launch.generatedFiles
        plan.defaultLauncher = launch.defaultLauncher
        plan.gameboxAutoexec = translateAutoexec(configuration.autoexec,
                                                 shortName: shortName,
                                                 launchLines: launch.launchLines,
                                                 mountsParent: drives.contains { !$0.insertFolder.isEmpty })
        plan.showsDOSViewAtStartup = plan.gameboxAutoexec.contains { line in
            let head = String(stripPrefix(line).lowercased().prefix(while: { $0 != " " && $0 != "\t" }))
            return interactiveCommands.contains(head)
        }

        let derived = planSettings(configuration.sections)
        plan.settings = derived.settings
        plan.notes = launch.notes + derived.notes
        if plan.showsDOSViewAtStartup {
            plan.notes.append("its autoexec stops to talk to you, so the gamebox opens at the DOS view")
        }

        plan.mt32ROMs = mt32ROMs(in: members)
        if !plan.mt32ROMs.isEmpty {
            plan.notes.append("ships \(plan.mt32ROMs.count) MT-32 ROM(s); Boxer uses its own, from Preferences")
        }

        plan.warnings = driveWarnings + launch.warnings
        if drives.isEmpty { plan.warnings.append("no drives were mounted by the autoexec") }
        if plan.launchers.isEmpty && !launch.autoexecStartsGame {
            plan.warnings.append("no launch command was found")
        }

        return plan
    }


    /// Turns eXo's autoexec into the one the gamebox carries.
    ///
    /// Decision 16: the autoexec goes across as it was written, and only three
    /// kinds of line are commented out — never deleted, because the comment is
    /// the record of what the pack said and is worth having in front of anyone
    /// debugging the gamebox later.
    ///
    ///  - `mount` / `imgmount`, which became drives (decision 17);
    ///  - `exit`, which would end the session the moment the game returns;
    ///  - the game's own execution line, which the gamebox's launchers replace.
    ///
    /// Every surviving line has eXo's pack-relative prefix stripped (decision
    /// 20). Which prefix depends on what the C drive turned out to be: normally
    /// it is the game's folder, so `.\eXoDOS\<short>\` goes; where the config
    /// mounted the pack's whole games folder, C is the *parent* and only
    /// `.\eXoDOS\` goes, leaving the `<short>` component the following
    /// `cd <short>` still needs.
    static func translateAutoexec(_ autoexec: [String],
                                  shortName: String,
                                  launchLines: Set<Int>,
                                  mountsParent: Bool) -> [String] {
        var result: [String] = []
        for (index, raw) in autoexec.enumerated() {
            let command = stripPrefix(raw)
            let head = String(command.lowercased().prefix(while: { $0 != " " && $0 != "\t" }))

            if head == "mount" || head == "imgmount" || head == "exit"
                || launchLines.contains(index) {
                result.append("rem " + raw)
                continue
            }
            result.append(retargetedDiscSwapKeys(
                strippedPackPrefix(raw, shortName: shortName, mountsParent: mountsParent)))
        }
        return result
    }

    /// Rewrites DOSBox's disc-swap shortcut into the one Boxer actually uses.
    ///
    /// 68 games print an instruction like *"This game is comprised of 2 CD's.
    /// Press Ctrl-F4 to switch discs when prompted"* — and inside Boxer that is
    /// simply wrong: Ctrl-F4 does nothing, and the menu item is **Next Disc**,
    /// ⇧⌘→ (`mountNextDrivesInQueues:`, right arrow with shift and command).
    /// An instruction naming a key that does nothing is worse than none.
    ///
    /// Six spellings occur in the pack — `Ctrl+F4`, `Ctrl-F4`, `ctrl-F4`,
    /// `CTRL-F4`, `ctrl+F4`, `ctrl-f4` — so the match is deliberately loose
    /// about case, separator and spacing.
    ///
    /// Note this lengthens the line, which can nudge a framed block of `echo`
    /// art out of alignment. Saying the right thing is worth more.
    static let discSwapShortcut = "Shift-Cmd-Right"

    static func retargetedDiscSwapKeys(_ line: String) -> String {
        guard line.range(of: "f *4", options: [.regularExpression, .caseInsensitive]) != nil
        else { return line }
        let pattern = "\\b(?:ctrl|control|ctl) *[-+ ]? *f *4\\b"
        return line.replacingOccurrences(of: pattern, with: discSwapShortcut,
                                         options: [.regularExpression, .caseInsensitive])
    }

    /// Removes eXo's pack-relative prefix from every string in a line.
    static func strippedPackPrefix(_ line: String, shortName: String,
                                   mountsParent: Bool) -> String {
        var prefixes = [".\\eXoDOS\\", "./eXoDOS/"]
        if !mountsParent {
            prefixes = [".\\eXoDOS\\\(shortName)\\", "./eXoDOS/\(shortName)/"] + prefixes
        }
        for prefix in prefixes {
            let stripped = line.replacingOccurrences(of: prefix, with: "",
                                                     options: [.caseInsensitive])
            if stripped != line { return stripped }
        }
        return line
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
                           sizeOf: ((String) -> UInt64?)? = nil,
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

            // Every path argument, not just the first. A multi-disc game says
            // `imgmount d disc1.cue disc2.cue …` and keeping only `tokens[2]`
            // is how 112 games came to lose every disc but one, silently — the
            // rest were not even extracted (decision 19).
            var paths: [String] = []
            var flags: [String] = []
            for token in tokens.dropFirst(2) {
                if token.hasPrefix("-") || !flags.isEmpty { flags.append(token) }
                else { paths.append(token) }
            }
            guard !paths.isEmpty else {
                warnings.append("mount command names nothing to mount: \(command)")
                continue
            }
            let media = mediaType(flags: flags)

            for path in paths {
                guard let source = packRelativePath(path, shortName: shortName, members: members) else {
                    warnings.append("mount path outside the game folder, skipped: \(command)")
                    continue
                }

                // The shape of what was named decides what it becomes, not the
                // verb that named it: `mount` and `imgmount` are one command in
                // this fork, and the pack uses both for CDs (decision 17).
                let isDirectory = source.isEmpty || Self.isDirectory(source, in: members)
                let isFile = !source.isEmpty && members.contains(source)

                if isDirectory && !isFile {
                    let kind = media ?? (letter == "a" ? .floppy : .hdd)
                    if !source.isEmpty && !members.contains(source)
                        && !Self.isDirectory(source, in: members) {
                        warnings.append("mounts a folder the archive does not ship: \(command)")
                    }
                    // `mount c .\eXoDOS\` with no folder after it mounts the
                    // pack's whole games folder, so the gamebox's C drive is the
                    // game folder's *parent* and the `cd <short>` that follows
                    // stays literally correct (decision 20).
                    // `.\eXoDOS\dune` and a bare `.\eXoDOS\` both resolve to
                    // the game's own folder, but they do not mean the same
                    // thing: the first mounts the game, the second mounts its
                    // parent and walks in. Only the second inserts a folder.
                    let mountsPackRoot = namesPackRoot(path)
                    let name = source.isEmpty ? shortName : basename(source)
                    drives.append(ExoDOSDrive(isImage: false, letter: letter, kind: kind,
                                              source: source, target: "", name: name,
                                              insertFolder: mountsPackRoot ? shortName : ""))
                    continue
                }

                let ext = pathExtension(source).lowercased()
                if !knownImageExtensions.contains(ext) {
                    warnings.append("image type .\(ext) is not in Boxer's extension map: \(command)")
                }
                if !members.contains(source) {
                    warnings.append("mounts an image the archive does not ship: \(command)")
                }

                var drive = ExoDOSDrive(isImage: true, letter: letter, kind: media ?? .hdd,
                                        source: source, target: "", name: basename(source))
                if descriptorExtensions.contains(ext), let readMember = readMember,
                   members.contains(source), let text = readMember(source) {
                    // A descriptor plus separate track files must go into a
                    // .cdmedia bundle, which keeps them together and keeps the
                    // tracks out of Boxer's drive scan (FINDINGS.md D68).
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
                    drive.tracks = tracks
                    drive.isBundle = true
                    drive.descriptor = source
                    // A cue sheet is a CD descriptor, so it is a CD unless the
                    // command said otherwise — `imgmount d <x>.cue` with no
                    // `-t` is a CD-ROM, not a hard disk.
                    drive.kind = media ?? .cdrom
                } else if let sizeOf = sizeOf {
                    drive.sectorSize = sectorSize(for: source, size: sizeOf(source))
                }
                drives.append(drive)
            }
        }
        return (nameDrives(drives), warnings)
    }

    /// Gives every drive the filename it will carry inside the gamebox.
    ///
    /// Two rules, and they interact, so this happens once all the mounts are
    /// known rather than as each is read:
    ///
    /// - **A letter carrying more than one image bundles every one of them**
    ///   (decision 18), because a `.cdmedia` holds exactly one `tracks.cue` and
    ///   so a bundle *is* one disc. A letter carrying a single self-contained
    ///   image leaves it bare — `D Dune.iso` already works, and a synthesised
    ///   cue is a guess at a sector size not worth making.
    /// - **A number orders the queue, and only appears when there is a queue**
    ///   (decision 19). `-[BXGamebox bundledDrives]` sorts on the filename
    ///   (`BXGamebox.m:607-610`), so the number is what fixes the order; it is
    ///   zero-padded because that sort is a plain string compare. Where a letter
    ///   carries one volume no number is added, because
    ///   `+[BXDrive labelForContentsOfURL:]` strips only `"<letter> "`
    ///   (`BXDrive.m:171`) and the number would otherwise reach DOS as part of
    ///   the volume label.
    static func nameDrives(_ drives: [ExoDOSDrive]) -> [ExoDOSDrive] {
        var counts: [String: Int] = [:]
        var imageCounts: [String: Int] = [:]
        for drive in drives {
            counts[drive.letter, default: 0] += 1
            if drive.isImage { imageCounts[drive.letter, default: 0] += 1 }
        }

        var seen: [String: Int] = [:]
        var named: [ExoDOSDrive] = []
        for var drive in drives {
            seen[drive.letter, default: 0] += 1
            let letter = drive.letter.uppercased()
            let numbered = (counts[drive.letter] ?? 0) > 1
            let number = numbered ? String(format: "%02d ", seen[drive.letter]!) : ""

            if drive.isImage {
                // Only a CD becomes a bundle. A queue of floppies stays a queue
                // of plain images — `A 01 Disk1.ima`, `A 02 Disk2.ima` — because
                // a `.cdmedia` is a CD-ROM to Boxer's drive scan
                // (`BXFileTypes.m:233`) and would mount a floppy as one.
                if drive.kind == .cdrom && (imageCounts[drive.letter] ?? 0) > 1 {
                    drive.isBundle = true
                }
                drive.target = drive.isBundle
                    ? "\(letter) \(number)\(stripExtension(drive.name)).cdmedia"
                    : "\(letter) \(number)\(drive.name)"
            } else {
                drive.target = "\(letter) \(number)\(drive.name).\(drive.kind.folderSuffix)"
            }
            named.append(drive)
        }
        return named
    }

    /// The sector size to write into a cue we synthesise for a bare image.
    ///
    /// An ISO9660 image holds 2,048-byte user data per sector; a raw dump holds
    /// 2,352. Nothing in the file says which, so the extension decides and the
    /// file's own size is the tie-break: a raw dump divides by 2,352 and an
    /// ISO does not.
    static func sectorSize(for path: String, size: UInt64?) -> Int {
        let raw = ["bin", "img", "mdf", "raw"].contains(pathExtension(path).lowercased())
        var chosen = raw ? 2352 : 2048
        if let size = size, size > 0, size % UInt64(chosen) != 0 {
            let other = chosen == 2048 ? 2352 : 2048
            if size % UInt64(other) == 0 { chosen = other }
        }
        return chosen
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

    /// Is this the pack's whole games folder, rather than one game in it?
    ///
    /// 1,521 games write `mount c .\eXoDOS\` and then `cd <short>`. It
    /// resolves to the same place as `mount c .\eXoDOS\<short>` once the game
    /// is on its own, which is why this asks the *written* path rather than the
    /// resolved one (decision 20).
    static func namesPackRoot(_ dosPath: String) -> Bool {
        let parts = dosPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != "." }
        return parts.count == 1 && parts[0].lowercased() == "exodos"
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
        /// The indices, into the autoexec, of the lines that start the game.
        /// Decision 16 comments these out; decision 21 reads the default
        /// launcher off them.
        var launchLines: Set<Int> = []

        /// The launcher the autoexec's own execution line named, if it named
        /// one directly rather than handing off to a menu.
        var defaultLauncher: Int?

        /// Whether a command we deliberately left to the autoexec starts the
        /// game. Such a game has no launcher and needs none, so it must not be
        /// warned about as though nothing starts it.
        var autoexecStartsGame = false

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
                              shortName: String = "",
                              text: (String) -> String? = { _ in nil }) -> LaunchPlan {
        var plan = LaunchPlan()
        // Last mount of a letter wins, as it does in DOSBox itself.
        var byLetter: [String: ExoDOSDrive] = [:]
        for drive in drives { byLetter[drive.letter] = drive }

        var current = drives.first(where: { $0.kind == .hdd })?.letter ?? "c"
        var workingDirectory = ""

        for (index, raw) in autoexec.enumerated() {
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
            let prefix = (drive != nil && !drive!.isImage) ? drive!.contentRoot + "/" : ""

            // A drive-qualified program — Dunjonquest's `c:\gwbasic inn.bas`,
            // run while standing on A — is checked on the drive it *names*.
            // Looking for it on the current drive is how that game came to be
            // told "cannot find 'c:\gwbasic' on drive a" about a command that
            // is perfectly valid.
            //
            // It is checked, and deliberately not turned into a launcher. A
            // launcher runs from its own program's directory, and these
            // commands mean "run the program on that drive, from where I am
            // standing" — gwbasic is on C and `inn.bas` is on A, so a launcher
            // pointing at gwbasic would start in the wrong place and fail. The
            // game works because the line stays in the autoexec, which it does:
            // only a line that produced a launcher is commented out.
            if let (letter, rest) = driveQualifier(in: program) {
                let named = byLetter[letter]
                if resolveProgram(rest, drive: named, members: members) != nil {
                    plan.autoexecStartsGame = true
                    plan.notes.append("'\(program)' runs from drive \(letter); the autoexec starts it rather than a launcher")
                } else if named == nil {
                    plan.warnings.append("names drive \(letter), which nothing mounts: \(command)")
                } else if named!.isImage {
                    plan.notes.append("'\(program)' runs from drive \(letter), an image this cannot look inside")
                } else {
                    plan.warnings.append("cannot find '\(program)' on drive \(letter): \(command)")
                }
                continue
            }

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
            // Only ever interpret a batch file. `call` invokes nothing else in
            // DOS, but the resolver tries `.com` and `.exe` first, so without
            // this a `call fleet` that lands on `fleet.exe` reads the binary as
            // text and "interprets" the machine code.
            if wasCall, pathExtension(resolved).lowercased() == "bat",
               let source = drive?.source,
               let text = text(source.isEmpty ? resolved : source + "/" + resolved) {
                let flattened = flattenMenu(text,
                                            batchPath: prefix + resolved,
                                            drive: current,
                                            workingDirectory: workingDirectory,
                                            byLetter: byLetter,
                                            members: members,
                                            shortName: shortName,
                                            plan: &plan)
                if flattened {
                    // A menu we flattened names no default: its first entry is
                    // usually the oldest or most limited way to play.
                    plan.launchLines.insert(index)
                    plan.defaultLauncher = nil
                    continue
                }
            }

            // `%1 %2 %3` and friends are the batch parameters eXo's own Windows
            // launcher passed in; inside a gamebox they are always empty, and
            // they must not reach BXLauncherArgsKey (decision 21).
            arguments = arguments.filter { !isBatchParameter($0) }
            plan.launchLines.insert(index)
            plan.defaultLauncher = plan.launchers.count
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
                                    shortName: String,
                                    plan: inout LaunchPlan) -> Bool {
        let branches: [ExoDOSMenuBranch]
        do {
            branches = try ExoDOSMenuInterpreter.flatten(text, drive: drive,
                                                         workingDirectory: workingDirectory,
                                                         shortName: shortName,
                                                         hostPrefix: byLetter[drive]?.contentRoot ?? "")
        } catch let failure as ExoDOSMenuInterpreter.Unflattenable {
            plan.notes.append("'\(basename(batchPath))' \(failure.reason), so it stays the launcher and its menu comes up in Boxer")
            return false
        } catch {
            return false
        }

        var launchers: [ExoDOSLauncher] = []
        var generated: [String: String] = [:]
        var usedNames = Set<String>()

        for branch in branches {
            let title = branch.composedTitle
            let target = byLetter[branch.drive]

            var tokens = splitCommand(branch.command)
            guard !tokens.isEmpty else { continue }
            var program = tokens.removeFirst()
            var arguments = tokens
            // `loadfix` and `loadfix -64` stand in front of the real program and
            // just eat memory for it; the batch replays them either way, but
            // resolving has to see past them.
            while prefixCommands.contains(program.lowercased()) {
                while let first = arguments.first, isNumericFlag(first) { arguments.removeFirst() }
                guard !arguments.isEmpty else { break }
                program = arguments.removeFirst()
            }

            // A branch that ends on an image drive cannot be checked against
            // anything — the archive ships the disc, not its contents — and a
            // branch that has to change drive or directory first cannot be said
            // as a path plus arguments either. Both get a batch file.
            let resolved = resolveProgram(program, drive: target, members: members,
                                          workingDirectory: branch.workingDirectory)
            // Only a branch that is one bare program, run where the menu was
            // called from, can be said as a launcher's path and arguments.
            // Everything else replays its script from a batch file.
            let needsBatch = branch.script.count > 1
                || branch.drive != drive
                || branch.workingDirectory != workingDirectory
                || resolved == nil

            if !needsBatch, let resolved = resolved, let target = target {
                launchers.append(ExoDOSLauncher(path: target.contentRoot + "/" + resolved,
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

            let name = uniqueBatchName(label: branch.label,
                                       title: title ?? stripExtension(basename(program)),
                                       taken: &usedNames)
            let folder = (batchPath as NSString).deletingLastPathComponent
            let path = folder.isEmpty ? name : folder + "/" + name
            generated[path] = renderBranchBatch(branch)
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
    ///
    /// The branch's own lines, in its own order, and nothing added: no drive or
    /// directory prologue, because the file is written beside the batch it
    /// replaces and Boxer runs a launcher from its own directory — so it starts
    /// exactly where eXo's menu started.
    static func renderBranchBatch(_ branch: ExoDOSMenuBranch) -> String {
        var lines = ["@echo off",
                     "rem Generated by Boxer from this game's eXoDOS menu."]
        lines.append(contentsOf: branch.script)
        // DOS wants CRLF, and wants the file to end with one.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A DOS-safe, unique 8.3 name for a branch's batch file.
    ///
    /// The menu's own label for the branch is the name to use: it is eXo's word
    /// for this way of playing, it is already 8.3-shaped, and it survives into
    /// the gamebox as something a person can read — Dune's six become `SB16`,
    /// `MT32`, `GOLD`, `CDSB16`, `CDMT32` and `CDGOLD` rather than `PLAYDU1`
    /// through `PLAYDU6`, which say nothing and only differ by their number
    /// because all six titles happen to begin "play Dune".
    ///
    /// The title is the fallback for a branch no `choice` forked to.
    private static func uniqueBatchName(label: String?, title: String, taken: inout Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics
        let source = (label?.isEmpty == false) ? label! : title
        var stem = String(String(source.unicodeScalars.filter { allowed.contains($0) })
            .uppercased()
            .prefix(8))
        if stem.isEmpty { stem = "PLAY" }

        var name = stem + ".BAT"
        var suffix = 1
        while taken.contains(name.lowercased()) {
            suffix += 1
            let digits = String(suffix)
            name = String(stem.prefix(8 - digits.count)) + digits + ".BAT"
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

        // FluidSynth is gated out of this fork (`C_FLUIDSYNTH 0`, FINDINGS.md
        // D9), so asking for it names a device Boxer cannot provide. Dropping
        // the key leaves Boxer's own MIDI handling in charge rather than
        // substituting a value eXo never wrote (decision 22).
        if settings["midi"]?["mididevice"] == "fluidsynth" {
            settings["midi"]?.removeValue(forKey: "mididevice")
            if settings["midi"]?.isEmpty == true { settings.removeValue(forKey: "midi") }
            notes.append("asks for FluidSynth, which Boxer does not provide; using Boxer's own MIDI")
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

    /// Splits `c:\gwbasic` into the drive it names and the path on it.
    ///
    /// Returns nil for a bare drive change (`c:`), which has its own handling,
    /// and for anything not of the form `<letter>:<path>`.
    static func driveQualifier(in program: String) -> (String, String)? {
        let characters = Array(program)
        guard characters.count > 2, characters[1] == ":",
              let letter = characters.first?.lowercased().first,
              letter >= "a", letter <= "x" else { return nil }
        let rest = String(characters[2...]).drop(while: { $0 == "\\" || $0 == "/" })
        guard !rest.isEmpty else { return nil }
        return (String(letter), String(rest))
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

    /// `%1` … `%9`, and `%0`. A batch parameter, never an argument.
    static func isBatchParameter(_ token: String) -> Bool {
        guard token.count == 2, token.hasPrefix("%"),
              let digit = token.last, digit.isNumber else { return false }
        return true
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
