//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import Foundation

/// One way of starting the game, recovered from an eXoDOS menu batch file.
struct ExoDOSMenuBranch {
    /// The menu prompts that led here, outermost first.
    var titles: [String] = []

    /// The label the last `choice` jumped to on the way here — `etandy`,
    /// `cdmt32`, `talkie`. This is what names the generated batch file, because
    /// it is eXo's own name for this way of playing, it is already 8.3-shaped,
    /// and it is unique per branch in a way the *last* label walked is not:
    /// Monkey Island's four EGA branches all end at the shared `:elaunch`.
    var label: String?

    /// The drive the branch ends up on, and the directory within it. Both start
    /// as the caller's, because a branch that changes neither runs where the
    /// autoexec left off.
    var drive: String
    var workingDirectory: String

    /// Everything the branch does, in the order it does it: `CONFIG -set` lines
    /// that switch sound hardware, the file copies that drop a driver's files
    /// into place, drive and directory changes, and the programs themselves.
    ///
    /// Kept as one ordered list rather than sorted into buckets, because the
    /// order is the meaning. A branch that copies files *after* changing drive
    /// does something different from one that copies before, and replaying a
    /// reordered version of it is a bug waiting to happen. What goes into the
    /// generated batch file is this, verbatim.
    ///
    /// These are the branch's **own lines**, unexpanded: its `set`s travel with
    /// it and DOS does the substituting, rather than us rewriting the command
    /// and dropping the `set`. Its `echo`, `cls` and `pause` travel with it too,
    /// since a branch may have something to say to the player before the game
    /// starts. Only the menu's own furniture — the prompt block above a
    /// `choice`, the `choice` itself, the labels and the `goto`s — is left
    /// behind, because that is the part the launcher replaces.
    var script: [String] = []

    /// The last program the branch runs, with its variables expanded — the game
    /// itself, since anything before it is a logo or a driver. Used to resolve
    /// and title the branch; the batch file replays `script` instead.
    var command: String = ""

    /// A title for the launch panel, composed from the prompts above.
    ///
    /// The inner prompt usually restates the outer one — "Floppy version with
    /// EGA" then "EGA Floppy version with Adlib" — so it stands on its own.
    /// Only where it drops something the outer prompt said is the outer one
    /// worth keeping in front of it.
    var composedTitle: String? {
        let usable = titles.filter { !$0.isEmpty }
        guard var title = usable.last else { return nil }
        var seen = Set(ExoDOSMenuInterpreter.significantWords(in: title))
        for outer in usable.dropLast().reversed() {
            let words = ExoDOSMenuInterpreter.significantWords(in: outer)
            if !Set(words).subtracting(seen).isEmpty {
                title = outer + " — " + title
                seen.formUnion(words)
            }
        }
        return title
    }
}


/// Reads an eXoDOS menu batch file and recovers the ways it can start the game.
///
/// 2,911 of the pack's 7,633 games hand off from the autoexec with `call`, and
/// what they call is a batch file that puts a menu on screen. Registering that
/// batch as the launcher — which is what Boxer did before this — reproduces
/// eXo's DOS menu inside the gamebox and works, but it means every one of those
/// games boots to a text menu rather than into Boxer's own launch panel.
///
/// This turns the menu into launchers. It is an interpreter rather than a label
/// scraper because the menus genuinely need one: they nest, their branches set
/// environment variables that the launch command then expands, they change
/// working directory and drive across shared labels, and some branches fall
/// through to an entirely different executable.
///
/// **It is deliberately conservative.** Not every batch file the autoexec calls
/// is one of eXo's menus — plenty are the game's own launcher, looping back to
/// its own menu after each play or branching on a program's exit code — and
/// flattening those would break them. What can be flattened is a *linear* path,
/// however many programs it runs; what cannot is branching. Anything whose
/// shape cannot be accounted for is refused outright and the caller keeps the
/// old behaviour, so nothing that worked can regress. Measured over the pack's
/// 2,911 games that call a menu, 1,732 flatten and 1,179 fall back.
enum ExoDOSMenuInterpreter {

    struct Unflattenable: Error {
        var reason: String
    }

    /// Commands that say something, or set the screen up to say it.
    ///
    /// All of these travel with the branch rather than being dropped: they cost
    /// nothing to keep and a branch may have something to tell the player. They
    /// are buffered rather than written straight out, because above a `choice`
    /// they are the menu's own furniture — the prompt block the launch panel
    /// replaces — and the `choice` discards them.
    ///
    /// `choice` is not here: it has its own case below, and it is the one piece
    /// of the menu the launch panel actually replaces.
    private static let presentation: Set<String> = ["echo", "cls", "pause", "rem",
                                                    "title", "prompt", "ver", "verify",
                                                    "break", "shift", "color"]

    /// DOS file commands, not programs.
    ///
    /// After the `choice` itself, the commonest line in these menus is
    /// `copy .\sb16\*.* .\` — dropping a sound driver's files into the game
    /// directory before it starts. Counting that as "a second program" would
    /// refuse to flatten a third of the corpus. It is setup, and it travels
    /// with its branch into the batch file generated for it, exactly as
    /// `CONFIG -set` does.
    private static let setupCommands: Set<String> = ["copy", "xcopy", "del", "erase",
                                                     "move", "ren", "rename", "md",
                                                     "mkdir", "rd", "rmdir", "deltree",
                                                     "attrib", "type", "path", "keyb",
                                                     "mode", "loadhigh", "lh", "config"]

    /// `mount` and its deprecated alias.
    ///
    /// These appear *inside* a menu branch in 11 of the pack's games — a branch
    /// that mounts its own disc before starting. Without this they fall through
    /// to "anything left is a program", which makes the mount command itself the
    /// branch's program and resolves it against the drive.
    private static let mountCommands: Set<String> = ["mount", "imgmount"]

    /// How deep a menu may nest before we stop believing it is a menu.
    private static let maximumDepth = 8

    /// Recovers every way the batch file can start the game.
    ///
    /// - Throws: `Unflattenable` when the file's shape cannot be accounted for,
    ///   which is the signal to leave the batch registered as the launcher.
    static func flatten(_ text: String, drive: String, workingDirectory: String,
                        shortName: String, hostPrefix: String) throws -> [ExoDOSMenuBranch] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { cleaned($0) }

        // DOS jumps to a label's first occurrence, so later duplicates are dead.
        var labels: [String: Int] = [:]
        for (index, line) in lines.enumerated() where line.hasPrefix(":") {
            let name = String(line.dropFirst()).components(separatedBy: CharacterSet.whitespaces)
                .first?.lowercased() ?? ""
            if !name.isEmpty, labels[name] == nil { labels[name] = index }
        }

        var branches: [ExoDOSMenuBranch] = []
        let start = ExoDOSMenuBranch(drive: drive, workingDirectory: workingDirectory)
        try walk(lines: lines, labels: labels, from: 0, state: start,
                 into: &branches, visited: [], depth: 0, variables: [:],
                 shortName: shortName, hostPrefix: hostPrefix)

        guard !branches.isEmpty else {
            throw Unflattenable(reason: "no path through it reaches a program")
        }
        return branches
    }

    /// Rewrites a `mount` line so it still means something inside a gamebox.
    ///
    /// Two changes, and only two:
    ///
    /// - **`imgmount` becomes `mount`.** They are one program in this fork —
    ///   `dos_programs.cpp:102-104` registers `IMGMOUNT.COM` as `MOUNT` "for
    ///   backward compatibility (with a deprecation warning)" — and `MOUNT::Run`
    ///   prints that warning on every invocation when called by the old name
    ///   (`mount.cpp:1319-1324`).
    /// - **eXo's `.\eXoDOS\<game>\` prefix is stripped**, which is decision 20
    ///   applied to the path argument. What is left resolves as a *DOS* path:
    ///   `MOUNT::ProcessPaths` runs every path through `GetDosMappedHostPath`
    ///   (`mount.cpp:988`, `:1029`), which is `DOS_MakeName` plus the local
    ///   drive's host mapping, and `DOS_MakeName` prefixes the drive's current
    ///   directory when the path is not rooted (`dos_files.cpp:256`). The game
    ///   folder is the C drive, so the path lands inside the gamebox — and it
    ///   keeps working when the gamebox is moved, which a host path would not.
    ///
    /// **Decided 2026-09-18: the path is left relative, not qualified with the
    /// branch's drive letter.** It then means what it meant at that point in
    /// eXo's script, which is the same rule the rest of the branch follows. The
    /// alternative — emitting `C:\cd\disc.cue` from the drive and directory the
    /// interpreter is tracking — is immune to a branch that changed drive before
    /// mounting, and is what to reach for if this is ever found wanting.
    static func rewrittenMountCommand(_ line: String, shortName: String,
                                      hostPrefix: String) -> String {
        var tokens = ExoDOSPlanner.splitCommand(line)
        guard !tokens.isEmpty else { return line }

        // `imgmount` is a deprecated alias for `mount` in this fork and prints a
        // banner on every invocation (`dos_programs.cpp:102-104`,
        // `mount.cpp:1319-1324`).
        if tokens[0].lowercased() == "imgmount" { tokens[0] = "mount" }

        var rebuilt = [tokens[0]]
        var index = 1
        // The drive letter, then paths until the first flag.
        if tokens.count > 1 { rebuilt.append(tokens[1]); index = 2 }
        var seenFlag = false
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.hasPrefix("-") { seenFlag = true }
            if seenFlag { rebuilt.append(token); continue }
            rebuilt.append("\"" + hostPath(token, shortName: shortName, hostPrefix: hostPrefix) + "\"")
        }
        return rebuilt.joined(separator: " ")
    }

    /// Turns one of eXo's pack-relative mount paths into a gamebox-relative one.
    ///
    /// `mount` wants a **host** path, and Boxer points the emulator's working
    /// directory at the gamebox itself (`BXSession.m:1855-1866`), so a path
    /// relative to the gamebox root is the form that keeps working when the
    /// gamebox is moved or copied to another machine.
    ///
    /// It is quoted because these names have spaces in them, and it is a host
    /// path rather than a DOS one because a host path has no 8.3 limit:
    /// `CARMAGEDDON.CUE` is eleven characters and `SPLAT PACK.CUE` has a space,
    /// and neither can be said as a DOS name at all.
    static func hostPath(_ dosPath: String, shortName: String, hostPrefix: String) -> String {
        var path = dosPath.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        for prefix in [".\\eXoDOS\\\(shortName)\\", "./eXoDOS/\(shortName)/",
                       ".\\eXoDOS\\", "./eXoDOS/"] {
            let stripped = path.replacingOccurrences(of: prefix, with: "",
                                                     options: [.caseInsensitive])
            if stripped != path { path = stripped; break }
        }
        path = path.replacingOccurrences(of: "\\", with: "/")
        return hostPrefix.isEmpty ? path : hostPrefix + "/" + path
    }

    /// Strips the leading `@`, the end-of-file marker, NUL padding and
    /// whitespace. Some of these `.bat` files are padded to a block boundary.
    private static func cleaned(_ raw: String) -> String {
        var line = raw.replacingOccurrences(of: "\u{1a}", with: "")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("@") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private static func walk(lines: [String],
                             labels: [String: Int],
                             from start: Int,
                             state: ExoDOSMenuBranch,
                             into branches: inout [ExoDOSMenuBranch],
                             visited: Set<String>,
                             depth: Int,
                             variables inherited: [String: String],
                             shortName: String,
                             hostPrefix: String) throws {
        if depth > maximumDepth {
            throw Unflattenable(reason: "its menus nest more than \(maximumDepth) deep")
        }

        var state = state
        var visited = visited
        var index = start
        // The text of the echo block above a `choice`, which is the only
        // description these menus carry for their branches.
        var prompts: [String] = []
        // Carried down into each branch, because DOS carries them: a `set`
        // before the first `choice` is in scope for every branch below it.
        var variables = inherited

        // `echo`, `cls` and `pause` are held here rather than written straight
        // into the script, because the same three commands do two different
        // jobs in these files. Above a `choice` they are the menu's own
        // furniture — the prompt block the launcher replaces — and a `choice`
        // discards them. Anywhere else they are the branch talking to the
        // player, and the first real command flushes them into the script.
        var pending: [String] = []
        func flush() {
            state.script.append(contentsOf: pending)
            pending.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.isEmpty || line.hasPrefix(":") { continue }

            let lowered = line.lowercased()
            // `echo.` is the DOS idiom for a blank line: one token, not `echo`
            // plus an argument, so a plain word match misses it.
            var head = String(lowered.prefix(while: { $0 != " " && $0 != "\t" }))
            while head.hasSuffix(".") { head = String(head.dropLast()) }

            if head == "echo" {
                if let prompt = menuPrompt(in: line) { prompts.append(prompt) }
                pending.append(line)
                continue
            }
            if presentation.contains(head) {
                pending.append(line)
                continue
            }

            if head == "exit" {
                if !state.command.isEmpty { flush(); branches.append(state) }
                return
            }

            if head == "goto" {
                let target = String(lowered.dropFirst(4))
                    .trimmingCharacters(in: .whitespaces)
                    .drop(while: { $0 == ":" })
                    .prefix(while: { $0 != " " && $0 != "\t" })
                let name = String(target)
                guard let destination = labels[name] else {
                    // `goto end`/`goto quit`/`goto eof` with nothing to land on
                    // is how a good many of these simply stop.
                    if ["eof", "end", "quit", "exit"].contains(name) {
                        if !state.command.isEmpty { flush(); branches.append(state) }
                        return
                    }
                    throw Unflattenable(reason: "jumps to ':\(name)', which it does not define")
                }
                if visited.contains(name) {
                    throw Unflattenable(reason: "loops back on itself at ':\(name)'")
                }
                visited.insert(name)
                index = destination + 1
                continue
            }

            if head == "choice" {
                let targets = choiceBranches(in: lines, from: index)
                guard !targets.isEmpty else {
                    throw Unflattenable(reason: "offers a choice with nothing to branch to")
                }
                // Whatever was on screen above the choice is the menu's own
                // prompt block, and the launch panel replaces it.
                pending.removeAll()
                for key in targets.keys.sorted() {
                    let name = targets[key]!
                    guard let destination = labels[name] else {
                        throw Unflattenable(reason: "offers a choice leading to ':\(name)', which it does not define")
                    }
                    var branch = state
                    // The prompts are positional: the Nth "Press N for …" line
                    // describes the Nth errorlevel branch below it.
                    if key >= 1 && key <= prompts.count {
                        branch.titles.append(prompts[key - 1])
                    }
                    // The deepest fork names the branch, so a nested menu ends
                    // up named for the entry that was actually chosen.
                    branch.label = name
                    try walk(lines: lines, labels: labels, from: destination + 1,
                             state: branch, into: &branches,
                             visited: visited.union([name]), depth: depth + 1,
                             variables: variables, shortName: shortName,
                             hostPrefix: hostPrefix)
                }
                return
            }

            if lowered.hasPrefix("if errorlevel") {
                throw Unflattenable(reason: "branches on a program's exit code")
            }
            if head == "if" || head == "for" {
                throw Unflattenable(reason: "uses '\(head)', which a launcher cannot express")
            }
            if head == "call" || head == "command" {
                throw Unflattenable(reason: "calls another batch file")
            }
            if head == "boot" {
                // `boot` hands a disk image to the BIOS rather than running a
                // program, so there is nothing for a launcher to point at. The
                // batch file stays the launcher and runs it in DOS, as before.
                throw Unflattenable(reason: "boots a disk image, which a launcher cannot express")
            }

            if head == "set" {
                // The `set` travels with the branch rather than being consumed:
                // DOS does the substituting, so nothing has to be rewritten.
                // It is still recorded, because `command` — which titles and
                // resolves the branch — needs the expanded form.
                flush()
                state.script.append(line)
                if let separator = line.dropFirst(3).firstIndex(of: "=") {
                    let name = line[line.index(line.startIndex, offsetBy: 3)..<separator]
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: separator)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { variables[name] = value }
                }
                continue
            }

            // A branch that mounts its own disc. Rewritten rather than treated
            // as a program: left alone it becomes the branch's `command` and is
            // then resolved against the drive, which is how one game came to be
            // refused for "runs 'mount', which drive c does not hold".
            if mountCommands.contains(head) {
                flush()
                state.script.append(rewrittenMountCommand(line, shortName: shortName,
                                                          hostPrefix: hostPrefix))
                continue
            }

            if setupCommands.contains(head) {
                flush()
                state.script.append(line)
                continue
            }

            if let letter = ExoDOSPlanner.driveChange(in: lowered) {
                state.drive = letter
                state.workingDirectory = ""
                flush()
                state.script.append(line)
                continue
            }

            if var argument = ExoDOSPlanner.changeDirectoryArgument(in: lowered) {
                // `cd C:\RAYMAN` names the drive as well as the directory, and
                // dropping the letter leaves a path resolving against nothing.
                if argument.count >= 2 {
                    let characters = Array(argument)
                    if characters[1] == ":", characters[0].isLetter {
                        state.drive = String(characters[0]).lowercased()
                        state.workingDirectory = ""
                        argument = String(argument.dropFirst(2))
                            .drop(while: { $0 == "\\" || $0 == "/" })
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
                state.workingDirectory = applyChangeDirectory(state.workingDirectory, argument: argument)
                flush()
                state.script.append(line)
                continue
            }

            // Anything left is a program. A branch may run several in a row —
            // Dune's every entry runs `logo` and then `duneprg` — and that is
            // not a reason to give up: the generated batch replays the sequence
            // exactly as the branch wrote it. What cannot be flattened is
            // *branching*, and `if errorlevel` and the loop check above catch
            // that. The last program is the game; anything before it is a logo
            // or a driver.
            //
            // Keep walking rather than stopping here: whether the batch does
            // something *after* the game is a property of this path, not of the
            // lines that happen to follow in the file — the labels below
            // usually belong to other branches.
            // The script keeps the line as the branch wrote it; `command` is the
            // expanded form, used only to title and resolve the branch.
            state.command = expand(line, with: variables)
            flush()
            state.script.append(line)
        }

        // Falling off the end of the file ends the path, exactly as `exit` does.
        if !state.command.isEmpty { flush(); branches.append(state) }
    }

    /// Maps a `choice`'s one-based index onto the label it jumps to.
    ///
    /// The `if errorlevel = N goto L` lines are written in descending order
    /// because DOS reads `errorlevel N` as "N or above"; taken as a block they
    /// are an exact index-to-label table.
    private static func choiceBranches(in lines: [String], from start: Int) -> [Int: String] {
        var branches: [Int: String] = [:]
        var index = start
        var inspected = 0
        while index < lines.count && inspected < 20 {
            let line = lines[index]
            index += 1
            if line.isEmpty || line.hasPrefix(":") { continue }
            inspected += 1

            let lowered = line.lowercased()
            guard lowered.hasPrefix("if errorlevel") else { break }
            let rest = String(lowered.dropFirst("if errorlevel".count))
                .drop(while: { $0 == " " || $0 == "\t" || $0 == "=" })
            let digits = rest.prefix(while: { $0.isNumber })
            guard let level = Int(digits) else { break }
            guard let gotoRange = rest.range(of: "goto") else { break }
            let target = rest[gotoRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .drop(while: { $0 == ":" })
                .prefix(while: { $0 != " " && $0 != "\t" })
            if target.isEmpty { break }
            branches[level] = String(target)
        }
        return branches
    }

    /// The description in `echo Press 1 for VGA with Adlib`.
    private static func menuPrompt(in line: String) -> String? {
        let lowered = line.lowercased()
        guard lowered.hasPrefix("echo ") else { return nil }
        let body = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix("press ") else { return nil }

        // "Press 1 for …" / "Press 2 to play …" — skip the key, then the verb.
        var rest = String(body.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        rest = String(rest[rest.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        let leading = rest.lowercased()
        if leading.hasPrefix("for ") { rest = String(rest.dropFirst(4)) }
        else if leading.hasPrefix("to ") { rest = String(rest.dropFirst(3)) }
        else { return nil }

        let prompt = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .\t"))
        return prompt.isEmpty ? nil : prompt
    }

    private static func applyChangeDirectory(_ current: String, argument: String) -> String {
        let argument = argument.trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
        if argument.isEmpty || argument == "\\" || argument == "/" { return "" }

        var result = current
        for part in argument.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/") {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                result = result.components(separatedBy: "/").dropLast().joined(separator: "/")
            } else {
                result = result.isEmpty ? part : result + "/" + part
            }
        }
        return result
    }

    /// Substitutes `%name%` from the variables the branch set on its way here.
    ///
    /// Monkey Island needs this: its four EGA branches differ only in a `set
    /// eaudio=…` before they all jump to a shared `:elaunch` that runs
    /// `monkey e %eaudio%`.
    private static func expand(_ line: String, with variables: [String: String]) -> String {
        guard line.contains("%") else { return line }
        var result = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "%") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "%") else {
                result += rest[open...]
                return result.trimmingCharacters(in: .whitespaces)
            }
            let name = String(rest[afterOpen..<close]).lowercased()
            result += variables[name] ?? ""
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// The words worth comparing when deciding whether one prompt restates
    /// another: short ones carry no meaning and only get in the way.
    static func significantWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }
}
