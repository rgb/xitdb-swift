import Foundation
import Testing

@testable import XitDB

/// The reader did not say what a test expected of it.
struct ReaderSaidSomethingElse: Error, CustomStringConvertible {
    let expected: String
    let said: String

    var description: String { "the reader in the other process was to say \"\(expected)\" and said \"\(said)\"" }
}

/// The reader's process ended, or closed its output, before it answered.
struct ReaderEnded: Error, CustomStringConvertible {
    let question: String

    var description: String { "the reader in the other process ended before it answered \"\(question)\"" }
}

/// A reader in another process than the one that replaces a file, and what
/// its storage tells it: `isStillAtPath`, which is how such a reader learns
/// that the path it opened now leads to another file, or to none, and that
/// it has to open the path again.
///
/// The reader is the package's tool (`XitDBFuzz watch`), which opens the
/// file to be read with no lock and no memory map, as a reader beside a
/// writer in another process does, and uses nothing but what a program of
/// another package has. This process is the writer. It replaces the file by
/// the storage's own mechanism, called directly: a full copy does not call
/// it yet.
///
/// What a reader in another process has that one in this process has not is
/// a table of open files of its own, and a view of the folder of its own.
/// Nothing here depends on which storages a full copy will replace the
/// file of.
@Suite struct ReaderInAnotherProcessTests {
    /// How the reader's storage reads its file, by the tool's names for
    /// the three: a file opened to be read (a `ReadOnlyFileStorage`), read
    /// by file calls and through a memory map in either of its two ways.
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case file
        case fileMap = "file-map"
        case fileMapReadAhead = "file-map-read-ahead"

        var testDescription: String { rawValue }

        /// Whether the reader opens its file to be read through a map.
        var isThroughAMap: Bool { self != .file }
    }

    static let old = Array("the old file's bytes, which a reader that has them keeps".utf8)
    static let new = Array("THE NEW FILE'S BYTES, under the old file's name".utf8)

    /// The first sixteen bytes, as the reader prints what it reads.
    static func said(_ bytes: [UInt8]) -> String {
        bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    #if os(macOS) || os(Linux)
        /// The reader: the tool, started, with the file at a path open.
        final class Reader {
            private let process = Process()
            private let questions = Pipe()
            private let answers = Pipe()
            private var unread = Data()

            /// Starts the tool on `path` and waits until it has the file
            /// open.
            init(_ kind: Kind, at path: String) throws {
                // A line written to a reader that has ended is an error to
                // throw, and not the signal that ends this process and with
                // it every test in it.
                signal(SIGPIPE, SIG_IGN)
                process.executableURL = try builtTool("XitDBFuzz")
                process.arguments = ["watch", kind.rawValue, path]
                process.standardInput = questions
                process.standardOutput = answers
                try process.run()
                let first = try line(for: "open")
                guard first == "open" else { throw ReaderSaidSomethingElse(expected: "open", said: first) }
            }

            deinit {
                try? questions.fileHandleForWriting.write(contentsOf: Data((Question.quit.rawValue + "\n").utf8))
                try? questions.fileHandleForWriting.close()
                process.waitUntilExit()
            }

            /// The next line the tool prints. The tool ends by itself after
            /// twenty seconds, so this does not wait for ever.
            private func line(for question: String) throws -> String {
                while true {
                    if let end = unread.firstIndex(of: 0x0A) {
                        let line = String(decoding: unread[unread.startIndex..<end], as: UTF8.self)
                        unread.removeSubrange(unread.startIndex...end)
                        return line
                    }
                    let more = answers.fileHandleForReading.availableData
                    guard !more.isEmpty else { throw ReaderEnded(question: question) }
                    unread.append(more)
                }
            }

            /// What a test asks the tool, a word to a line: the tool's own
            /// words for its questions.
            private enum Question: String {
                case still, mapped, read, quit
            }

            /// What the tool answers to a line.
            private func ask(_ question: Question) throws -> String {
                try questions.fileHandleForWriting.write(contentsOf: Data((question.rawValue + "\n").utf8))
                return try line(for: question.rawValue)
            }

            /// The reader's storage's `isStillAtPath`.
            func isStillAtPath() throws -> Bool {
                let answer = try ask(.still)
                guard answer == "true" || answer == "false" else {
                    throw ReaderSaidSomethingElse(expected: "true or false", said: answer)
                }
                return answer == "true"
            }

            /// The file's first sixteen bytes as the reader's storage reads
            /// them, in hexadecimal.
            func read() throws -> String {
                try ask(.read)
            }

            /// The reader's storage's `isMemoryMapped`.
            func isMemoryMapped() throws -> Bool {
                let answer = try ask(.mapped)
                guard answer == "true" || answer == "false" else {
                    throw ReaderSaidSomethingElse(expected: "true or false", said: answer)
                }
                return answer == "true"
            }
        }

        /// A folder with the old file in it, under the folder's own name
        /// for a file. The folder is removed when the value goes away, so a
        /// test keeps it to its end.
        private static func folder() throws -> TemporaryFolder {
            let folder = try TemporaryFolder()
            #expect(FileManager.default.createFile(atPath: folder.path(), contents: Data(old)))
            return folder
        }

        /// This process's writer on the file at `path`, with the exclusive
        /// lock, asked for the memory map or not.
        private static func writer(at path: String, mapped: Bool) throws -> FileStorage {
            try FileStorage(
                path: path, access: .readWrite, durability: .none, lock: .exclusive,
                reading: mapped ? .memoryMap : .fileCalls)
        }

        /// Writes the new file's bytes through the writer, at the start.
        private static func writeTheNewBytes(_ writer: FileStorage) throws {
            try writer.write(new.span, at: 0)
        }
    #endif

    /// A reader keeps being told that its path leads to its file while the
    /// writer makes the new file and writes it, and reads the old bytes all
    /// the while. Once the new file has the name the reader is told that its
    /// path leads elsewhere, and it still reads the old file, whole. A
    /// reader that opens the path then has the new file.
    @Test(
        .enabled(if: aTestCanStartAProcess, "a test cannot start another process on this system"),
        arguments: Kind.allCases, [false, true])
    func aReaderIsToldWhenTheNewFileHasTheName(kind: Kind, mapped: Bool) throws {
        #if os(macOS) || os(Linux)
            let folder = try Self.folder()
            defer { withExtendedLifetime(folder) {} }
            let path = folder.path()
            let reader = try Reader(kind, at: path)
            #expect(try reader.isMemoryMapped() == kind.isThroughAMap)
            #expect(try reader.isStillAtPath())
            #expect(try reader.read() == Self.said(Self.old))

            let writer = try Self.writer(at: path, mapped: mapped)
            #expect(try reader.isStillAtPath(), "a writer that opens the file replaces nothing")
            try writer.beginReplacement()
            #expect(try reader.isStillAtPath(), "the new file is beside the old one and has not the name")
            try Self.writeTheNewBytes(writer)
            #expect(try reader.isStillAtPath())
            #expect(try reader.read() == Self.said(Self.old))

            try writer.commitReplacement()
            #expect(try reader.isStillAtPath() == false, "the name is the new file's")
            #expect(try reader.read() == Self.said(Self.old), "and the reader's file is the old one, whole")
            #expect(try writer.isStillAtPath)

            let later = try Reader(kind, at: path)
            #expect(try later.isStillAtPath())
            #expect(try later.read() == Self.said(Self.new))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["test.db"])
        #endif
    }

    /// A replacement that is given up tells a reader nothing: its path led
    /// to its file before, during and after, and no file is left beside it.
    @Test(
        .enabled(if: aTestCanStartAProcess, "a test cannot start another process on this system"),
        arguments: Kind.allCases, [false, true])
    func aReaderIsToldNothingOfAReplacementThatIsGivenUp(kind: Kind, mapped: Bool) throws {
        #if os(macOS) || os(Linux)
            let folder = try Self.folder()
            defer { withExtendedLifetime(folder) {} }
            let path = folder.path()
            let reader = try Reader(kind, at: path)
            let writer = try Self.writer(at: path, mapped: mapped)
            try writer.beginReplacement()
            try Self.writeTheNewBytes(writer)
            #expect(try reader.isStillAtPath())
            writer.abandonReplacement()
            #expect(try reader.isStillAtPath())
            #expect(try reader.read() == Self.said(Self.old))
            #expect(try Reader(kind, at: path).read() == Self.said(Self.old))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["test.db"])
        #endif
    }

    /// What is written into the file in place is no replacement: the path
    /// leads to the same file, the reader is told so, and it reads the new
    /// bytes, since they are in its file. The property says where a path
    /// leads, not whether the file changed.
    @Test(
        .enabled(if: aTestCanStartAProcess, "a test cannot start another process on this system"),
        arguments: Kind.allCases)
    func aReaderIsToldNothingOfBytesWrittenInPlace(kind: Kind) throws {
        #if os(macOS) || os(Linux)
            let folder = try Self.folder()
            defer { withExtendedLifetime(folder) {} }
            let path = folder.path()
            let reader = try Reader(kind, at: path)
            let writer = try Self.writer(at: path, mapped: false)
            try Self.writeTheNewBytes(writer)
            #expect(try reader.isStillAtPath())
            // a new reader, so that nothing a buffer kept is read
            #expect(try Reader(kind, at: path).read() == Self.said(Self.new))
            #expect(try reader.isStillAtPath())
        #endif
    }

    /// A reader is told when its file is removed, and goes on reading it;
    /// and another file made under the name afterwards is another file.
    @Test(
        .enabled(if: aTestCanStartAProcess, "a test cannot start another process on this system"),
        arguments: Kind.allCases)
    func aReaderIsToldWhenTheFileIsRemoved(kind: Kind) throws {
        #if os(macOS) || os(Linux)
            let folder = try Self.folder()
            defer { withExtendedLifetime(folder) {} }
            let path = folder.path()
            let reader = try Reader(kind, at: path)
            #expect(try reader.isStillAtPath())
            try FileManager.default.removeItem(atPath: path)
            #expect(try reader.isStillAtPath() == false, "no file has the name")
            #expect(try reader.read() == Self.said(Self.old))

            #expect(FileManager.default.createFile(atPath: path, contents: Data(Self.new)))
            #expect(try reader.isStillAtPath() == false, "another file has the name")
            #expect(try reader.read() == Self.said(Self.old))
            #expect(try Reader(kind, at: path).isStillAtPath())
        #endif
    }

    /// A reader that opened a symbolic link is told about the link as it is
    /// when it asks: changed to lead to another file, the path no longer
    /// leads to the reader's; changed back, it does again; and when the
    /// writer, which opened the same link, replaces the real file behind
    /// it, the link is as it was and leads to the new file.
    @Test(
        .enabled(if: aTestCanStartAProcess, "a test cannot start another process on this system"),
        arguments: Kind.allCases, [false, true])
    func aReaderIsToldWhenALinkLeadsElsewhere(kind: Kind, mapped: Bool) throws {
        #if os(macOS) || os(Linux)
            let folder = try Self.folder()
            defer { withExtendedLifetime(folder) {} }
            let path = folder.path()
            let link = folder.path("link.db")
            let elsewhere = folder.path("elsewhere.db")
            #expect(FileManager.default.createFile(atPath: elsewhere, contents: Data([4, 5, 6])))
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
            let reader = try Reader(kind, at: link)
            #expect(try reader.isStillAtPath())

            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: elsewhere)
            #expect(try reader.isStillAtPath() == false, "the link leads to another file")
            #expect(try reader.read() == Self.said(Self.old))
            try FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
            #expect(try reader.isStillAtPath(), "the link leads to the reader's file again")

            let writer = try Self.writer(at: link, mapped: mapped)
            try writer.beginReplacement()
            try Self.writeTheNewBytes(writer)
            #expect(try reader.isStillAtPath())
            try writer.commitReplacement()
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == path)
            #expect(try reader.isStillAtPath() == false, "the link leads to the real path, whose file is the new one")
            #expect(try reader.read() == Self.said(Self.old))
            #expect(try Reader(kind, at: link).read() == Self.said(Self.new))
        #endif
    }
}
