import Foundation
import Testing

@testable import XitDB

/// On Linux a file is read through a memory map only on a file system of a
/// kind that is this machine's own, and the kind is read from the system's
/// list of mounts. The reading of that list's text is plain code, held
/// here on every system; the asking itself is held where the list exists.
@Suite struct VolumeKindTests {
    /// A list of mounts as Linux writes it: the root on ext4, a btrfs
    /// volume, whose files report a device number that no line has, an NFS
    /// export, two FUSE mounts, one of them at a path with a space in it,
    /// a line with several optional fields before its hyphen and one with
    /// none, and a mount over a folder of the btrfs volume.
    static let mounts = """
        22 28 0:21 / /proc rw,nosuid,nodev,noexec,relatime shared:13 - proc proc rw
        28 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw,errors=remount-ro
        95 28 0:44 / /home rw,relatime shared:50 master:3 propagate_from:7 - btrfs /dev/sdb1 rw,subvolid=256,subvol=/home
        120 28 0:52 / /mnt/share rw,relatime shared:60 - nfs4 server:/export rw,vers=4.2
        130 28 0:60 / /mnt/with\\040a\\040space rw - fuse.sshfs user@host: rw
        140 28 0:61 / /work rw - fuseblk /dev/fuse rw
        150 95 0:70 / /home/scratch rw,relatime - tmpfs tmpfs rw,size=1024k
        """

    /// The device number glibc makes of a major and a minor number.
    private func device(_ major: UInt64, _ minor: UInt64) -> UInt64 {
        (major & 0xFFF) << 8 | (minor & 0xFF) | (major & ~0xFFF) << 32 | (minor & ~0xFF) << 12
    }

    /// A file is on the mount that has its device number, whatever its
    /// path: the root's, the export's, the passed-through folder's, and one
    /// whose numbers are too large for the old twenty bits.
    @Test func theKindIsTheOneOfTheMountWithTheFilesDevice() {
        #expect(Platform.fileSystemKind(device: device(259, 2), path: nil, mounts: Self.mounts) == .other("ext4"))
        #expect(Platform.fileSystemKind(device: device(0, 52), path: "/elsewhere/x", mounts: Self.mounts) == .nfs)
        #expect(Platform.fileSystemKind(device: device(0, 61), path: nil, mounts: Self.mounts) == .fuse)
        // the line with several optional fields before its hyphen
        #expect(Platform.fileSystemKind(device: device(0, 44), path: nil, mounts: Self.mounts) == .other("btrfs"))
        let large = "7 1 4660:1193046 / /big rw - xfs /dev/big rw"
        #expect(Platform.fileSystemKind(device: device(4660, 1_193_046), path: nil, mounts: large) == .other("xfs"))
    }

    /// Where no mount has the file's device number, as for a file of a
    /// btrfs subvolume, the kind is the one of the longest mount point that
    /// leads to the file's path, taken by whole names: `/homework` is not
    /// under `/home`.
    @Test func withNoSuchDeviceTheKindIsTheOneOfTheMountThePathIsUnder() {
        let unlisted = device(0, 99)
        /// The kind of the mount that the path is under, in the list above.
        func kind(of path: String, in mounts: String = Self.mounts) -> FileSystemKind? {
            Platform.fileSystemKind(device: unlisted, path: path, mounts: mounts)
        }
        #expect(kind(of: "/home/user/test.db") == .other("btrfs"))
        #expect(kind(of: "/home/scratch/test.db") == .other("tmpfs"))
        #expect(kind(of: "/home") == .other("btrfs"))
        #expect(kind(of: "/homework/test.db") == .other("ext4"))
        #expect(kind(of: "/var/lib/test.db") == .other("ext4"))
        // a mount point that the list writes with escapes; its kind is
        // FUSE with the name of the program behind it
        #expect(kind(of: "/mnt/with a space/test.db") == .fuse)
        // a later mount over the same place is the one that is there
        let covered = Self.mounts + "\n160 28 0:80 / /work rw - ext4 /dev/sdc1 rw"
        #expect(kind(of: "/work/test.db") == .fuse)
        #expect(kind(of: "/work/test.db", in: covered) == .other("ext4"))
    }

    /// Nothing is learnt where neither the device nor the path is found: no
    /// path at all, a path of a file that has lost its name, which the
    /// system gives with " (deleted)" after it, a list with no mount for
    /// the path, and lines that are no lines of the list.
    @Test func whereNothingMatchesNoKindIsLearnt() {
        let unlisted = device(0, 99)
        #expect(Platform.fileSystemKind(device: unlisted, path: nil, mounts: Self.mounts) == nil)
        #expect(
            Platform.fileSystemKind(device: unlisted, path: "/home/user/test.db (deleted)", mounts: Self.mounts) == nil)
        #expect(Platform.fileSystemKind(device: unlisted, path: "/home/x", mounts: "") == nil)
        let noRoot = "120 28 0:52 / /mnt/share rw,relatime shared:60 - nfs4 server:/export rw"
        #expect(Platform.fileSystemKind(device: unlisted, path: "/home/x", mounts: noRoot) == nil)
        let broken = "28 1 259:2 / / rw,relatime shared:1 ext4 /dev/nvme0n1p2 rw\nnot a line\n28 1 259:2 / / rw -"
        #expect(Platform.fileSystemKind(device: device(259, 2), path: "/x", mounts: broken) == nil)
        // and the device still decides for a file that has lost its name
        #expect(
            Platform.fileSystemKind(device: device(0, 44), path: "/home/user/test.db (deleted)", mounts: Self.mounts)
                == .other("btrfs"))
    }

    /// The kinds that are another machine's or passed through from
    /// elsewhere are not this machine's own, and each is a case: the
    /// system's words for them, with every name Linux has had for SMB and
    /// FUSE in every form, with its subtypes and as a block device, are
    /// read into those cases, and every one of them is remote.
    @Test func theKindsThatAreNotMappedAreCasesOfTheirOwn() {
        let named: [(word: String, kind: FileSystemKind)] = [
            ("nfs", .nfs), ("nfs4", .nfs), ("cifs", .smb), ("smb", .smb), ("smbfs", .smb), ("smb2", .smb),
            ("smb3", .smb), ("9p", .plan9), ("fuse", .fuse), ("fuseblk", .fuse), ("fuse.sshfs", .fuse),
            ("fuse.gvfsd-fuse", .fuse), ("virtiofs", .virtiofs), ("ceph", .ceph), ("afs", .afs), ("lustre", .lustre),
            ("gfs2", .gfs2),
        ]
        for (word, kind) in named {
            #expect(FileSystemKind(linuxName: word) == kind, "\(word)")
            #expect(kind.isRemote, "\(word)")
        }
        // the nine cases, each reached by a word
        #expect(Set(named.map(\.kind)).count == 9)
    }

    /// A word the library does not know is in the case for the rest, with
    /// the word kept, and is treated as this machine's own, as it was when
    /// words were compared: the common local kinds, one that only begins
    /// as FUSE's name does, Apple's, no word at all, and a word in another
    /// case of letters, which is another word.
    @Test func anyOtherKindKeepsItsWordAndIsThisMachinesOwn() {
        for word in ["ext4", "btrfs", "xfs", "overlay", "tmpfs", "zfs", "f2fs", "fusectl", "apfs", "", "NFS", "fuse_x"]
        {
            let kind = FileSystemKind(linuxName: word)
            #expect(kind == .other(word), "\(word)")
            #expect(!kind.isRemote, "\(word)")
        }
        #expect(FileSystemKind.other("ext4") != .other("btrfs"))
    }

    #if os(Linux)
        /// The asking itself, where the list of mounts exists: a file in
        /// the tests' temporary folder is on a kind of file system the
        /// system's list has, and the answer follows from that kind.
        @Test func theSystemsListSaysWhatTheTestsFilesAreOn() throws {
            let directory = try TemporaryDirectory()
            #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
            let descriptor = try FileDescriptor(opening: directory.path(), .toRead)
            let mounts = try String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
            // the file's device from Foundation and not by a `stat` of the
            // tests' own, whose members the compiler does not reliably
            // find here
            let device = try #require(
                try FileManager.default.attributesOfItem(atPath: directory.path())[.systemNumber] as? NSNumber)
            let kind = try #require(
                Platform.fileSystemKind(device: device.uint64Value, path: directory.path(), mounts: mounts),
                "no mount found for \(directory.path())")
            #expect(Platform.volumeIsLocal(descriptor.rawValue) == !kind.isRemote, "\(kind)")
        }
    #endif
}
