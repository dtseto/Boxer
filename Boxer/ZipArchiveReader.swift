//
//  Copyright (c) 2026 Alun Bestor and contributors. All rights reserved.
//  This source file is released under the GNU General Public License 2.0.
//  A full copy of this license can be found in this project's README.
//

import Compression
import Foundation

/// Reads members out of a zip archive, on top of the central directory that
/// `BXZipCentralDirectory` has already parsed.
///
/// Extraction is deliberately streamed rather than buffered: an eXoDOS game
/// routinely holds a single half-gigabyte disc image, and Monkey Island holds
/// two, so inflating a member into memory before writing it is not an option.
/// Nothing is ever written back to the archive, and the archive is opened for
/// reading only — the pack a game is dragged out of is read-only by rule.
final class ZipArchiveReader {
    enum Failure: LocalizedError {
        case unreadableArchive(URL)
        case missingMember(String)
        case malformedMember(String)
        case unsupportedCompression(String, UInt16)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .unreadableArchive(let url):
                return String(format: NSLocalizedString("“%@” could not be read as a zip archive.",
                                                        comment: "Error when a zip cannot be opened. %@ is its filename."),
                              url.lastPathComponent)
            case .missingMember(let path):
                return String(format: NSLocalizedString("The archive has no item named “%@”.",
                                                        comment: "Error when an expected zip member is absent. %@ is its path."),
                              path)
            case .malformedMember(let path):
                return String(format: NSLocalizedString("“%@” is damaged inside the archive.",
                                                        comment: "Error when a zip member's header is wrong. %@ is its path."),
                              path)
            case .unsupportedCompression(let path, let method):
                return String(format: NSLocalizedString("“%@” is stored with an unsupported compression method (%u).",
                                                        comment: "Error for an exotic zip compression method. %@ is a path, %u the method."),
                              path, UInt(method))
            case .checksumMismatch(let path):
                return String(format: NSLocalizedString("“%@” did not survive decompression intact.",
                                                        comment: "Error when a zip member's CRC does not match. %@ is its path."),
                              path)
            }
        }
    }

    /// How much is read from the archive, and written out, at a time.
    private static let chunkSize = 1 << 20

    let url: URL
    let directory: BXZipCentralDirectory

    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        self.directory = try BXZipCentralDirectory(contentsOf: url)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.unreadableArchive(url)
        }
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    /// The entry at a path, matched case-insensitively.
    ///
    /// Case matters here: eXo's own configs do not always spell a path the way
    /// the archive spells it, which is invisible on a case-insensitive Mac
    /// volume right up until something compares the two exactly.
    func entry(at path: String) -> BXZipEntry? {
        directory.entry(atPath: path)
    }

    /// Reads a whole member into memory. Only for the small ones — a config, a
    /// cue sheet — where having the text in hand is the point.
    func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw Failure.missingMember(path) }
        var collected = Data(capacity: Int(min(entry.uncompressedSize, 16 << 20)))
        try extract(entry) { chunk in
            collected.append(chunk)
            return true
        }
        return collected
    }

    /// Reads a member as text, tolerating whatever encoding it turns out to be.
    ///
    /// eXo's configs are a mix of UTF-8 and Windows code pages, and a game with
    /// an accented title in a comment must not take the whole import down, so
    /// this falls back rather than failing.
    func text(at path: String) throws -> String {
        let data = try data(at: path)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: Self.dosLatinUS)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// IBM Code Page 437 — what DOS wrote and what these archives hold.
    ///
    /// It matters for the batch files the menu interpreter reads, because their
    /// `echo` lines are full of box-drawing characters, and those now travel
    /// into the batch files we generate. Decoding them as CP1252 — which the
    /// first version did — turns CP437's full block (0xDB) into `Û` and its
    /// box corners into accented vowels: the file still writes, and the game
    /// still runs, but the banner it prints is mojibake.
    ///
    /// ISO Latin-1 sits behind it as a backstop that cannot fail, because it
    /// maps all 256 byte values. `BXZipCentralDirectory` reads entry *names*
    /// the same way and for the same reason.
    static let dosLatinUS = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    /// Writes a member straight out to a file, inflating as it goes.
    ///
    /// `progress` is handed the number of bytes written so far each chunk, and
    /// returning false from it cancels the extraction: a half-written file is
    /// removed rather than left behind for the caller to trip over.
    func extract(_ entry: BXZipEntry,
                 to destination: URL,
                 progress: (Int64) -> Bool = { _ in true }) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        manager.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: destination])
        }

        var written: Int64 = 0
        var cancelled = false
        do {
            try extract(entry) { chunk in
                try? output.write(contentsOf: chunk)
                written += Int64(chunk.count)
                if !progress(written) {
                    cancelled = true
                    return false
                }
                return true
            }
        } catch {
            try? output.close()
            try? manager.removeItem(at: destination)
            throw error
        }
        try? output.close()
        if cancelled { try? manager.removeItem(at: destination) }
    }

    /// The one place that actually reads an entry's data. Everything else here
    /// is a wrapper around this.
    ///
    /// Returning false from `consume` stops the read, and stops the checksum
    /// being enforced with it: a deliberately truncated read has no business
    /// failing validation.
    private func extract(_ entry: BXZipEntry, consume: (Data) throws -> Bool) throws {
        let dataStart = try dataOffset(of: entry)
        try handle.seek(toOffset: dataStart)

        var checksum = CRC32()
        var completed = true

        // A local function rather than a closure: `consume` is non-escaping,
        // and storing it in a variable would be treated as letting it escape.
        func emit(_ chunk: Data) throws -> Bool {
            checksum.update(chunk)
            return try consume(chunk)
        }

        switch entry.compressionMethod {
        case 0:
            var remaining = entry.compressedSize
            while remaining > 0 {
                let wanted = Int(min(remaining, UInt64(Self.chunkSize)))
                guard let chunk = try handle.read(upToCount: wanted), chunk.count == wanted else {
                    throw Failure.malformedMember(entry.path)
                }
                remaining -= UInt64(wanted)
                if try !emit(chunk) { completed = false; break }
            }
        case 8:
            completed = try inflate(entry, emit: emit)
        default:
            throw Failure.unsupportedCompression(entry.path, entry.compressionMethod)
        }

        // A zero CRC in the directory means the archive deferred the value to a
        // data descriptor, which only a streamed (unseekable) writer produces
        // and which we have no cheap way to find. Nothing in the pack does it,
        // but refusing such an archive outright would be worse than trusting it.
        if completed && entry.crc32 != 0 && checksum.value != entry.crc32 {
            throw Failure.checksumMismatch(entry.path)
        }
    }

    /// Streams an entry through the system's raw-DEFLATE decoder.
    ///
    /// `COMPRESSION_ZLIB` is Apple's name for headerless deflate, which is
    /// exactly what a zip member holds — the zlib wrapper a `.gz` carries is
    /// not present here.
    private func inflate(_ entry: BXZipEntry, emit: (Data) throws -> Bool) throws -> Bool {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw Failure.malformedMember(entry.path)
        }
        defer { compression_stream_destroy(&stream) }

        // Both buffers are allocated once and outlive every pass through the
        // loop: the decoder holds `src_ptr` across calls as it works through
        // what it was handed, so the input cannot live in a `Data` whose
        // pointer is only valid inside a `withUnsafeBytes` closure.
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer {
            output.deallocate()
            input.deallocate()
        }

        var remaining = entry.compressedSize
        stream.src_size = 0

        while true {
            if stream.src_size == 0 && remaining > 0 {
                let wanted = Int(min(remaining, UInt64(Self.chunkSize)))
                guard let chunk = try handle.read(upToCount: wanted), chunk.count == wanted else {
                    throw Failure.malformedMember(entry.path)
                }
                chunk.copyBytes(to: UnsafeMutableRawBufferPointer(start: input, count: wanted))
                stream.src_ptr = UnsafePointer(input)
                stream.src_size = wanted
                remaining -= UInt64(wanted)
            }

            stream.dst_ptr = output
            stream.dst_size = Self.chunkSize

            // FINALIZE tells the decoder no more input is coming, which is what
            // lets it report the end of the stream rather than waiting.
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)

            let produced = Self.chunkSize - stream.dst_size
            if produced > 0 {
                if try !emit(Data(bytes: output, count: produced)) { return false }
            }

            switch status {
            case COMPRESSION_STATUS_END:
                return true
            case COMPRESSION_STATUS_OK:
                // No progress in either direction with nothing left to feed it
                // means the member is truncated, not merely finished.
                if produced == 0 && stream.src_size == 0 && remaining == 0 {
                    throw Failure.malformedMember(entry.path)
                }
            default:
                throw Failure.malformedMember(entry.path)
            }
        }
    }

    /// Finds where an entry's data actually begins.
    ///
    /// The central directory records the offset of the *local* header, whose
    /// name and extra fields may be different lengths from the ones in the
    /// directory — so the data offset has to be read from the local header
    /// itself rather than computed from what the directory said.
    private func dataOffset(of entry: BXZipEntry) throws -> UInt64 {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else {
            throw Failure.malformedMember(entry.path)
        }
        guard header.readUInt32(at: 0) == 0x04034b50 else {
            throw Failure.malformedMember(entry.path)
        }
        let nameLength = UInt64(header.readUInt16(at: 26))
        let extraLength = UInt64(header.readUInt16(at: 28))
        return entry.localHeaderOffset + 30 + nameLength + extraLength
    }
}


// MARK: - Checksums

/// The zip format's CRC-32, computed a chunk at a time.
///
/// Written out here rather than reached for in zlib: it needs no module map, no
/// link-time dependency and no bridging. The slicing-by-eight arrangement is
/// worth the extra tables — a byte-at-a-time loop was the single biggest cost
/// in extracting a gamebox, and Monkey Island moves 1.7 GB through this.
struct CRC32 {
    /// Eight 256-entry tables, laid out end to end. Table 0 is the ordinary
    /// CRC-32 table; each later one folds in the byte before it, which is what
    /// lets eight bytes be consumed per round.
    private static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 8 * 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            tables[index] = value
        }
        for slice in 1..<8 {
            for index in 0..<256 {
                let previous = tables[(slice - 1) * 256 + index]
                tables[slice * 256 + index] = (previous >> 8) ^ tables[Int(previous & 0xFF)]
            }
        }
        return tables
    }()

    private var state: UInt32 = 0xFFFFFFFF

    var value: UInt32 { state ^ 0xFFFFFFFF }

    mutating func update(_ data: Data) {
        var crc = state
        Self.tables.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                let count = raw.count

                while count - offset >= 8 {
                    let first = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian ^ crc
                    let second = raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian
                    crc = table[7 * 256 + Int(first & 0xFF)]
                        ^ table[6 * 256 + Int((first >> 8) & 0xFF)]
                        ^ table[5 * 256 + Int((first >> 16) & 0xFF)]
                        ^ table[4 * 256 + Int(first >> 24)]
                        ^ table[3 * 256 + Int(second & 0xFF)]
                        ^ table[2 * 256 + Int((second >> 8) & 0xFF)]
                        ^ table[1 * 256 + Int((second >> 16) & 0xFF)]
                        ^ table[Int(second >> 24)]
                    offset += 8
                }
                while offset < count {
                    crc = table[Int((crc ^ UInt32(raw[offset])) & 0xFF)] ^ (crc >> 8)
                    offset += 1
                }
            }
        }
        state = crc
    }
}


// MARK: - Little-endian reads

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1))) }
    }
}
