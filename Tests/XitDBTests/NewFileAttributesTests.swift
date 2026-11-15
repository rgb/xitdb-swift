import Foundation
import Testing

@testable import XitDB

/// What a new file that takes an old one's place has from it, before a
/// byte is written to it: the permission bits on every system; on Apple
/// platforms the access control list, the extended attributes, the mark
/// that keeps a file out of backups and the data protection class; on
/// Linux the owner and the group. A full copy onto a file storage that
/// replaces its file is made of this call.
///
/// Not shown here, and not by the gate: that a database on a device comes
/// back under its protection class. A Mac and a simulator show that the
/// class is asked for and set, and that a file without one is no error.
@Suite struct NewFileAttributesTests {
    /// An old file with these permission bits, and a new file beside it as
    /// a full copy makes one, both open.
    private func files(
        bits: Int = 0o600
    ) throws -> (directory: TemporaryDirectory, old: FileDescriptor, new: FileDescriptor) {
        let directory = try TemporaryDirectory()
        #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
        try FileManager.default.setAttributes([.posixPermissions: bits], ofItemAtPath: directory.path())
        let old = try FileDescriptor(opening: directory.path(), access: .readWrite)
        let new = try FileDescriptor(opening: directory.path("test.db.incoming"), access: .create)
        return (directory, old, new)
    }

    private func bits(_ path: String) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber).intValue
    }

    /// The new file has the old one's permission bits, narrower or wider
    /// than a new file's own, whatever the process's mask.
    @Test(arguments: [0o600, 0o640, 0o660, 0o664, 0o666])
    func thePermissionBitsAreCarried(old: Int) throws {
        let (directory, oldFile, newFile) = try files(bits: old)
        #expect(try bits(directory.path("test.db.incoming")) != old || old == 0o644)
        try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue)
        #expect(try bits(directory.path("test.db.incoming")) == old)
        #expect(try bits(directory.path()) == old)
    }

    /// A step that fails is the carry's failure, with the system's error:
    /// here a new file that is not open.
    @Test func aStepThatFailsIsAnError() throws {
        let (_, oldFile, _) = try files()
        #expect(throws: XitDBError.storageFailure(errno: EBADF)) {
            try Platform.carryAttributes(from: oldFile.rawValue, to: -1)
        }
        #expect(throws: XitDBError.storageFailure(errno: EBADF)) {
            try Platform.carryAttributes(from: -1, to: oldFile.rawValue)
        }
    }

    /// The replaceable call of a file storage is the platform's.
    @Test func theReplaceableCallIsThePlatforms() throws {
        let (directory, oldFile, newFile) = try files(bits: 0o640)
        try FileCalls().carryAttributes(oldFile.rawValue, newFile.rawValue)
        #expect(try bits(directory.path("test.db.incoming")) == 0o640)
    }

    #if canImport(Darwin)
        /// An extended attribute of the caller's is on the new file.
        @Test func anExtendedAttributeIsCarried() throws {
            let (directory, oldFile, newFile) = try files()
            let note = Array("kept beside the bytes".utf8)
            #expect(setxattr(directory.path(), "org.example.note", note, note.count, 0, 0) == 0)
            try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue)
            var read = [UInt8](repeating: 0, count: 64)
            let count = getxattr(directory.path("test.db.incoming"), "org.example.note", &read, read.count, 0, 0)
            #expect(count == note.count)
            #expect(Array(read.prefix(max(count, 0))) == note)
        }

        /// The mark that keeps a file out of backups, which is an extended
        /// attribute, is on the new file.
        @Test func theMarkAgainstBackupsIsCarried() throws {
            let (directory, oldFile, newFile) = try files()
            var marked = URL(fileURLWithPath: directory.path())
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try marked.setResourceValues(values)
            let before = try URL(fileURLWithPath: directory.path("test.db.incoming"))
                .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            #expect(before == false)

            try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue)
            let after = try URL(fileURLWithPath: directory.path("test.db.incoming"))
                .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            #expect(after == true)
        }

        /// The text of an open file's access control list, or `nil` if it
        /// has none.
        private func accessList(_ descriptor: Int32) -> String? {
            guard let list = acl_get_fd(descriptor) else { return nil }
            defer { acl_free(UnsafeMutableRawPointer(list)) }
            guard let text = acl_to_text(list, nil) else { return nil }
            defer { acl_free(text) }
            return String(cString: text)
        }

        /// An access control list, made by the system's own calls for it,
        /// is on the new file: an entry that lets this user read.
        @Test func theAccessControlListIsCarried() throws {
            let (_, oldFile, newFile) = try files()
            var list = acl_init(1)
            defer { acl_free(UnsafeMutableRawPointer(list)) }
            var entry: acl_entry_t?
            #expect(acl_create_entry(&list, &entry) == 0)
            #expect(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0)
            // the system's identifier for a local user: a fixed prefix
            // and the user's number
            let user = getuid()
            var identifier: uuid_t = (
                0xFF, 0xFF, 0xEE, 0xEE, 0xDD, 0xDD, 0xCC, 0xCC, 0xBB, 0xBB, 0xAA, 0xAA, UInt8(user >> 24),
                UInt8(user >> 16 & 0xFF), UInt8(user >> 8 & 0xFF), UInt8(user & 0xFF)
            )
            #expect(withUnsafePointer(to: &identifier) { acl_set_qualifier(entry, $0) } == 0)
            var permissions: acl_permset_t?
            #expect(acl_get_permset(entry, &permissions) == 0)
            #expect(acl_add_perm(permissions, ACL_READ_DATA) == 0)
            #expect(acl_set_fd(oldFile.rawValue, list) == 0)
            let old = try #require(accessList(oldFile.rawValue))
            #expect(old.contains("allow:read"))
            #expect(accessList(newFile.rawValue) == nil)

            try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue)
            #expect(accessList(newFile.rawValue) == old)
        }

        /// The data protection class of the old file, where it has one, is
        /// the new file's, and a file without one is no error. What this
        /// shows on a Mac and a simulator is little: the carry asks and
        /// sets without failing, and the two files' classes agree. A Mac
        /// reports a class for a file and takes a request for another
        /// without changing it, so no class other than a new file's own
        /// can be seen to be carried here; a device, where the class
        /// decides whether a database can be read while it is locked, is
        /// where that would show, and the gate has none.
        @Test func theProtectionClassIsCarried() throws {
            let (_, oldFile, newFile) = try files()
            let own = fcntl(oldFile.rawValue, F_GETPROTECTIONCLASS)
            if own >= 0 {
                // another class than a new file is given, where the system
                // lets the old file's be changed
                _ = fcntl(oldFile.rawValue, F_SETPROTECTIONCLASS, own == 4 ? 3 : 4)
            }
            let old = fcntl(oldFile.rawValue, F_GETPROTECTIONCLASS)
            try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue)
            #expect(fcntl(newFile.rawValue, F_GETPROTECTIONCLASS) == old)
        }
    #else
        /// The owner and the group of the file at `path`, asked of
        /// Foundation and not by a `stat` of the tests' own, whose members
        /// the compiler does not reliably find here on Linux.
        private func owner(_ path: String) throws -> (uid_t, gid_t) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let owner = try #require(attributes[.ownerAccountID] as? NSNumber)
            let group = try #require(attributes[.groupOwnerAccountID] as? NSNumber)
            return (owner.uint32Value, group.uint32Value)
        }

        /// The owner and the group of the old file are the new file's,
        /// where the process may give a file away: the superuser may.
        @Test(.enabled(if: geteuid() == 0, "only the superuser can give a file to another owner"))
        func theOwnerAndTheGroupAreCarried() throws {
            let (directory, oldFile, newFile) = try files()
            #expect(fchown(oldFile.rawValue, 1234, 5678) == 0)
            #expect(try owner(directory.path()) == (1234, 5678))
            #expect(try owner(directory.path("test.db.incoming")) != (1234, 5678))
            try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue)
            #expect(try owner(directory.path("test.db.incoming")) == (1234, 5678))
        }

        /// A process that may not give the file to the old owner asks for
        /// the group alone; refused that too, it leaves the new file its
        /// own, which is no error. Any other failure is the carry's.
        @Test func aProcessThatMayNotSetTheOwnerAsksForTheGroupAlone() throws {
            let (directory, oldFile, newFile) = try files()
            let (uid, gid) = try owner(directory.path())
            final class Asked {
                var calls: [[UInt32]] = []
            }
            let asked = Asked()
            try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue) { _, owner, group in
                asked.calls.append([owner, group])
                return owner == uid_t.max ? 0 : EPERM
            }
            #expect(asked.calls == [[uid, gid], [uid_t.max, gid]])

            asked.calls = []
            try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue) { _, owner, group in
                asked.calls.append([owner, group])
                return EPERM
            }
            #expect(asked.calls == [[uid, gid], [uid_t.max, gid]])

            #expect(throws: XitDBError.storageFailure(errno: EIO)) {
                try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue) { _, _, _ in EIO }
            }
            #expect(throws: XitDBError.storageFailure(errno: EROFS)) {
                try Platform.carryAttributes(from: oldFile.rawValue, to: newFile.rawValue) { _, owner, _ in
                    owner == uid_t.max ? EROFS : EPERM
                }
            }
        }
    #endif
}
