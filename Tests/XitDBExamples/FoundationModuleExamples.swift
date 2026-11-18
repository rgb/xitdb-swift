import Foundation
import Testing
import XitDB
import XitDBFoundation
import XitDBHashing

// The examples of XitDBFoundation's landing page.

@Suite("The Foundation module") struct FoundationModuleExamples {
    @Test func aFileByItsURL() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let folder = URL(fileURLWithPath: scratch.path("project.db")).deletingLastPathComponent()

        let storage = try BufferedFileStorage(url: folder.appending(path: "project.db"), access: .create)
        let database = try Database(creating: storage, hashing: SHA256.self)
        try HashMap(database.rootCursor).put("Alice", forKey: "name")
        #expect(scratch.has("project.db"))
    }

    @Test func anErrorAPersonCanRead() throws {
        let scratch = ScratchDirectory()
        defer { scratch.remove() }
        let folder = URL(fileURLWithPath: scratch.path("project.db")).deletingLastPathComponent()
        var shown: [String] = []
        func show(_ text: String) { shown.append(text) }

        do {
            _ = try ReadOnlyFileStorage(url: folder.appending(path: "nothing-here.db"))
        } catch {
            // "the storage failed with system error 2: No such file or directory"
            show(error.localizedDescription)
        }
        #expect(shown == ["the storage failed with system error 2: No such file or directory"])
    }

    @Test func dataAsAValue() throws {
        func loadAvatar() throws -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }
        let database = try Database(creating: MemoryStorage(), hashing: SHA256.self)
        let people = try HashMap(database.rootCursor)

        let avatar: Data = try loadAvatar()
        try people.put(avatar, forKey: "avatar")
        let stored = try people.value(forKey: "avatar", as: Data.self)
        #expect(stored == avatar)
        #expect(try people.value(forKey: "avatar", as: [UInt8].self) == Array(avatar))
    }
}
