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
        #expect(Platform.fileSystemKind(device: device(259, 2), path: nil, mounts: Self.mounts) == "ext4")
        #expect(Platform.fileSystemKind(device: device(0, 52), path: "/elsewhere/x", mounts: Self.mounts) == "nfs4")
        #expect(Platform.fileSystemKind(device: device(0, 61), path: nil, mounts: Self.mounts) == "fuseblk")
        // the line with several optional fields before its hyphen
        #expect(Platform.fileSystemKind(device: device(0, 44), path: nil, mounts: Self.mounts) == "btrfs")
        let large = "7 1 4660:1193046 / /big rw - xfs /dev/big rw"
        #expect(Platform.fileSystemKind(device: device(4660, 1_193_046), path: nil, mounts: large) == "xfs")
    }

    /// Where no mount has the file's device number, as for a file of a
    /// btrfs subvolume, the kind is the one of the longest mount point that
    /// leads to the file's path, taken by whole names: `/homework` is not
    /// under `/home`.
    @Test func withNoSuchDeviceTheKindIsTheOneOfTheMountThePathIsUnder() {
        let unlisted = device(0, 99)
        #expect(Platform.fileSystemKind(device: unlisted, path: "/home/user/test.db", mounts: Self.mounts) == "btrfs")
        #expect(
            Platform.fileSystemKind(device: unlisted, path: "/home/scratch/test.db", mounts: Self.mounts) == "tmpfs")
        #expect(Platform.fileSystemKind(device: unlisted, path: "/home", mounts: Self.mounts) == "btrfs")
        #expect(Platform.fileSystemKind(device: unlisted, path: "/homework/test.db", mounts: Self.mounts) == "ext4")
        #expect(Platform.fileSystemKind(device: unlisted, path: "/var/lib/test.db", mounts: Self.mounts) == "ext4")
        // a mount point that the list writes with escapes
        #expect(
            Platform.fileSystemKind(device: unlisted, path: "/mnt/with a space/test.db", mounts: Self.mounts)
                == "fuse.sshfs")
        // a later mount over the same place is the one that is there
        let covered = Self.mounts + "\n160 28 0:80 / /work rw - ext4 /dev/sdc1 rw"
        #expect(Platform.fileSystemKind(device: unlisted, path: "/work/test.db", mounts: Self.mounts) == "fuseblk")
        #expect(Platform.fileSystemKind(device: unlisted, path: "/work/test.db", mounts: covered) == "ext4")
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
                == "btrfs")
    }

    /// The kinds that are another machine's or passed through from
    /// elsewhere are not this machine's own; FUSE in every form is among
    /// them, with its subtypes and as a block device.
    @Test func theKindsThatAreNotMapped() {
        for kind in [
            "nfs", "nfs4", "cifs", "smb", "smbfs", "smb2", "smb3", "9p", "fuse", "fuseblk", "fuse.sshfs",
            "fuse.gvfsd-fuse",
            "virtiofs", "ceph", "afs", "lustre", "gfs2",
        ] {
            #expect(Platform.isRemoteFileSystem(kind), "\(kind)")
        }
        for kind in ["ext4", "btrfs", "xfs", "overlay", "tmpfs", "zfs", "f2fs", "fusectl", "apfs", ""] {
            #expect(!Platform.isRemoteFileSystem(kind), "\(kind)")
        }
    }

    #if os(Linux)
        /// The asking itself, where the list of mounts exists: a file in
        /// the tests' temporary folder is on a kind of file system the
        /// system's list has, and the answer follows from that kind.
        @Test func theSystemsListSaysWhatTheTestsFilesAreOn() throws {
            let directory = try TemporaryDirectory()
            #expect(FileManager.default.createFile(atPath: directory.path(), contents: Data([1, 2, 3])))
            let descriptor = try FileDescriptor(opening: directory.path(), access: .readOnly)
            let mounts = try String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
            var status = stat()
            #expect(fstat(descriptor.rawValue, &status) == 0)
            let kind = try #require(
                Platform.fileSystemKind(device: UInt64(status.st_dev), path: directory.path(), mounts: mounts),
                "no mount found for \(directory.path())")
            #expect(Platform.volumeIsLocal(descriptor.rawValue) == !Platform.isRemoteFileSystem(kind), "\(kind)")
        }
    #endif
}
