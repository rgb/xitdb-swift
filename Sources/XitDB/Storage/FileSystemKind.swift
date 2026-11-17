/// A kind of file system, as far as the library tells kinds apart: the kinds
/// that are another machine's or are passed through from somewhere else,
/// each a case of its own, and every other kind in one case, with the
/// system's own word for it.
///
/// The library does one thing with a kind. A file on one that is another
/// machine's or passed through is not read through a memory map, since what
/// the other side of such a mount does to the file is not ours to know; a
/// file on any other kind is. So the named cases are the ones ``isRemote``
/// says yes to, and a kind the library has never heard of is in
/// ``other(_:)`` and is treated as this machine's own.
///
/// The system's word is read in one place, ``init(linuxName:)``, and
/// nothing after it compares a word. It is Linux's word: on Apple platforms
/// the system says of a mount itself whether it is local, and no kind is
/// asked for.
enum FileSystemKind: Hashable, Sendable {
    /// NFS, in its versions: Linux's `nfs` and `nfs4`.
    case nfs
    /// SMB, under the names Linux has had for it: `cifs`, `smb`, `smbfs`,
    /// `smb2` and `smb3`.
    case smb
    /// 9p, which a virtual machine's shared folder often is: `9p`.
    case plan9
    /// FUSE in every form: `fuse`, `fuseblk`, and `fuse.` with the name of
    /// the program behind it, as in `fuse.sshfs`. A folder of the host's
    /// mounted into a container is one.
    case fuse
    /// virtiofs, a host's folder in a virtual machine.
    case virtiofs
    /// Ceph.
    case ceph
    /// AFS.
    case afs
    /// Lustre.
    case lustre
    /// GFS2, a disk shared between the machines of a cluster.
    case gfs2
    /// Any other kind, with the system's own word for it, as in `ext4`,
    /// `btrfs` or `tmpfs`: kept so that a message to a person can say it.
    case other(String)

    /// The kind that Linux's word for a file system names, as its list of
    /// mounts writes it after the lone hyphen. A word the library does not
    /// know is ``other(_:)``.
    init(linuxName name: String) {
        self =
            switch name {
            case "nfs", "nfs4": .nfs
            case "cifs", "smb", "smbfs", "smb2", "smb3": .smb
            case "9p": .plan9
            case "fuse", "fuseblk": .fuse
            case "virtiofs": .virtiofs
            case "ceph": .ceph
            case "afs": .afs
            case "lustre": .lustre
            case "gfs2": .gfs2
            default: name.hasPrefix("fuse.") ? .fuse : .other(name)
            }
    }

    /// Whether the file system is another machine's or is passed through
    /// from somewhere else, so that a file on it is not read through a
    /// memory map.
    var isRemote: Bool {
        switch self {
        case .nfs, .smb, .plan9, .fuse, .virtiofs, .ceph, .afs, .lustre, .gfs2: true
        case .other: false
        }
    }
}
