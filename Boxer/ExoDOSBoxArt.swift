//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import AppKit
import Foundation

/// Finds a game's box front inside the eXoDOS media pack.
///
/// The art lives in `Content/XODOSMetadata.zip` — the optional 4.7 GB media
/// download — under `Images/MS-DOS/Box - Front/`, sometimes directly and
/// sometimes one region folder deep (`…/Box - Front/United States/…`). Only the
/// one image is ever read out: the archive's central directory is enough to
/// find it, so a 4.7 GB file costs a fraction of a second and a single
/// inflated PNG.
///
/// Measured against the whole pack on 2026-09-17: **7,556 of the 7,633 games
/// (99.0%) have a box front that can be found this way.** The remaining 77 have
/// none under any of the names we can derive.
enum ExoDOSBoxArt {
    /// Where the per-game box fronts live inside the media archive.
    static let imagePrefix = "images/ms-dos/box - front/"

    /// LaunchBox's own catalogue, which is the only place the title an image is
    /// named after can be looked up. 36 MB, and read only when the cheaper
    /// name-based matches have all missed.
    static let cataloguePath = "xml/all/MS-DOS.xml"

    /// The media archive belonging to a pack, given that pack's metadata
    /// archive: they sit side by side in `<pack>/Content/`.
    static func mediaArchiveURL(besideMetadataArchiveAt metadataURL: URL) -> URL? {
        let candidate = metadataURL.deletingLastPathComponent()
            .appendingPathComponent("XODOSMetadata.zip")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The game's box front, already through Boxer's cover-art treatment and
    /// ready to be handed to `representedIcon`. Nil when the media pack is
    /// absent, or holds no art for this game.
    static func coverArt(forShortName shortName: String,
                         longName: String,
                         mediaArchiveAt url: URL) -> NSImage? {
        guard let data = imageData(forShortName: shortName, longName: longName, mediaArchiveAt: url),
              let image = NSImage(data: data)
        else { return nil }

        // The same treatment the finished panel applies when a user drops their
        // own artwork on it (BXImportFinishedPanelController.m:31), so an
        // imported box looks like every other box in the games folder.
        return CoverArt.coverArt(with: image) ?? image
    }

    /// The raw image, for callers that want the file rather than an icon.
    static func imageData(forShortName shortName: String,
                          longName: String,
                          mediaArchiveAt url: URL) -> Data? {
        guard let archive = try? cachedArchive(at: url) else { return nil }
        guard let path = imagePath(forShortName: shortName, longName: longName, in: archive) else {
            return nil
        }
        return try? archive.data(at: path)
    }

    /// Picks the archive entry holding this game's box front.
    ///
    /// Three keys are tried in turn, in the order that costs least. Against the
    /// whole pack: the game's full name with its year matches 244 games, the
    /// name without the year another 5,481, and LaunchBox's own title — which
    /// is what forces the catalogue to be read — the remaining 1,831.
    static func imagePath(forShortName shortName: String,
                          longName: String,
                          in archive: ZipArchiveReader) -> String? {
        let index = imageIndex(in: archive)
        guard !index.isEmpty else { return nil }

        let withoutYear = longName.replacingOccurrences(of: "\\s*\\(\\d{4}\\)\\s*$",
                                                        with: "",
                                                        options: .regularExpression)
        for name in [longName, withoutYear] {
            if let hit = index[normalised(name)] { return hit }
        }

        guard let title = catalogueTitle(forShortName: shortName, in: archive) else { return nil }
        return index[normalised(title)]
    }


    // MARK: - The archive's own index

    /// Box fronts by normalised basename, with the lowest-numbered file winning.
    ///
    /// Built once per archive: the media pack has 37,389 entries and a single
    /// import may ask it several questions.
    private static func imageIndex(in archive: ZipArchiveReader) -> [String: String] {
        indexLock.lock()
        defer { indexLock.unlock() }

        let key = archive.url.standardizedFileURL.path
        if let cached = indexCache[key] { return cached }

        var index: [String: String] = [:]
        for entry in archive.directory.entries where !entry.isDirectory {
            let path = entry.path
            guard path.lowercased().hasPrefix(imagePrefix) else { continue }

            let base = ExoDOSPlanner.basename(path)
            // Each game's images are numbered: "Title-00.png", "Title-01.jpg".
            // The lowest number is eXo's own first choice, so it is ours.
            let stem = base.replacingOccurrences(of: "-\\d+\\.[A-Za-z0-9]+$",
                                                 with: "",
                                                 options: .regularExpression)
            let name = normalised(stem)
            if let existing = index[name], existing <= path { continue }
            index[name] = path
        }
        indexCache[key] = index
        return index
    }

    /// The title LaunchBox knows a game by, which is what its images are named
    /// after when the game's own long name is not.
    ///
    /// The catalogue is 36 MB of XML and the game is found in it by the one
    /// thing both sides agree on: the short name, which appears in the game's
    /// `<ApplicationPath>`. The search is done over the raw bytes and only the
    /// surrounding record is ever decoded — turning the whole file into a
    /// `String` to find one title would cost far more than the answer is worth.
    static func catalogueTitle(forShortName shortName: String, in archive: ZipArchiveReader) -> String? {
        guard let catalogue = try? cachedCatalogue(in: archive) else { return nil }

        guard let marker = "!dos\\\(shortName)\\".data(using: .utf8),
              let found = range(of: marker, in: catalogue, caseInsensitive: true)
        else { return nil }

        // Widen to the enclosing <Game> record. The longest record in the pack
        // is a few kilobytes of <Notes>, so a generous window still costs
        // nothing.
        let start = max(catalogue.startIndex, found.lowerBound - 8192)
        let end = min(catalogue.endIndex, found.upperBound + 65536)
        guard let window = String(data: catalogue[start..<end], encoding: .utf8)
                ?? String(data: catalogue[start..<end], encoding: .isoLatin1)
        else { return nil }

        guard let markerRange = window.range(of: "!dos\\\(shortName)\\", options: .caseInsensitive),
              let recordEnd = window.range(of: "</Game>", range: markerRange.upperBound..<window.endIndex),
              let titleStart = window.range(of: "<Title>", range: markerRange.upperBound..<recordEnd.lowerBound),
              let titleEnd = window.range(of: "</Title>", range: titleStart.upperBound..<recordEnd.lowerBound)
        else { return nil }

        return unescaped(String(window[titleStart.upperBound..<titleEnd.lowerBound]))
    }


    // MARK: - Matching names to filenames

    /// Folds a title into the form its filename takes.
    ///
    /// eXo replaces the characters Windows will not take in a filename with an
    /// underscore — and the apostrophe with them, which is not obvious and
    /// costs a third of the pack's box art if missed. Comparison is
    /// case-insensitive: the archive and the catalogue do not always agree.
    static func normalised(_ name: String) -> String {
        var result = ""
        result.reserveCapacity(name.count)
        for character in name {
            switch character {
            case ":", "/", "\\", "*", "?", "\"", "<", ">", "|", "'":
                result.append("_")
            default:
                result.append(character)
            }
        }
        return result.lowercased()
    }

    private static func unescaped(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// Naive byte search. The catalogue is read once and asked one question, so
    /// there is nothing here worth a cleverer algorithm.
    private static func range(of needle: Data, in haystack: Data, caseInsensitive: Bool) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lowered: (UInt8) -> UInt8 = caseInsensitive
            ? { (65...90).contains($0) ? $0 + 32 : $0 }
            : { $0 }
        let target = needle.map(lowered)

        return haystack.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Range<Data.Index>? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let first = target[0]
            var offset = 0
            let limit = bytes.count - target.count
            while offset <= limit {
                if lowered(bytes[offset]) == first {
                    var matched = true
                    for index in 1..<target.count where lowered(bytes[offset + index]) != target[index] {
                        matched = false
                        break
                    }
                    if matched {
                        let start = haystack.startIndex + offset
                        return start..<(start + target.count)
                    }
                }
                offset += 1
            }
            return nil
        }
    }


    // MARK: - Caches

    private static var archiveCache: [String: ZipArchiveReader] = [:]
    private static var indexCache: [String: [String: String]] = [:]
    private static var catalogueCache: [String: Data] = [:]
    private static let indexLock = NSLock()

    private static func cachedArchive(at url: URL) throws -> ZipArchiveReader {
        indexLock.lock()
        defer { indexLock.unlock() }

        let key = url.standardizedFileURL.path
        if let cached = archiveCache[key] { return cached }
        let archive = try ZipArchiveReader(url: url)
        archiveCache[key] = archive
        return archive
    }

    private static func cachedCatalogue(in archive: ZipArchiveReader) throws -> Data {
        indexLock.lock()
        defer { indexLock.unlock() }

        let key = archive.url.standardizedFileURL.path
        if let cached = catalogueCache[key] { return cached }
        let data = try archive.data(at: cataloguePath)
        catalogueCache[key] = data
        return data
    }

    /// Drops everything this holds open. The media archive is the pack's
    /// largest file and the catalogue is 36 MB in memory.
    static func forgetCaches() {
        indexLock.lock()
        archiveCache.removeAll()
        indexCache.removeAll()
        catalogueCache.removeAll()
        indexLock.unlock()
    }
}
