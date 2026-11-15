// What the cold lines' report says about the machine it ran on, so that its
// figures can be read without asking: the system, the memory, the page, the
// file system and the device under the files, how far the system reads
// ahead there, and the memory limit the process is under, if it finds one.
//
// On Linux everything comes from the system's own files, read as text. No
// C structure's members are read there: in a target that imports
// Foundation the compiler does not reliably find them on Linux.

import Foundation

/// A memory limit the process is under, and the file that states it.
struct MemoryLimit {
    let bytes: UInt64
    let source: String
}

/// What is printed about the machine.
struct ColdMachine {
    /// The lines of the report's first block.
    var lines: [String] = []

    /// The limit found, or `nil`.
    var limit: MemoryLimit?

    /// Describes the machine and the volume `directory` is on.
    init(directory: String) {
        let real = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        lines.append("system: \(Self.system())")
        lines.append("processors: \(ProcessInfo.processInfo.activeProcessorCount)")
        lines.append("memory: \(Self.memory())")
        lines.append("page: \(getpagesize()) bytes")
        lines.append("the files are in: \(real)")
        #if os(Linux)
            let mounts = Mount.all()
            if let mount = Mount.holding(real, in: mounts) {
                lines.append(
                    "file system: \(mount.kind) on \(mount.source), mounted at \(mount.mountPoint), "
                        + "device \(mount.device)")
                lines.append("reading ahead: \(Self.readAhead(mount))")
            } else {
                lines.append("file system: no mount found for the folder in /proc/self/mountinfo")
                lines.append("reading ahead: not looked for, since the volume is not known")
            }
            let found = Self.limit(mounts)
            limit = found.limit
            if let limit {
                lines.append("memory limit: \(limit.bytes) bytes (\(limit.source))")
            } else {
                lines.append("memory limit: NONE FOUND (looked at: \(found.looked.joined(separator: ", ")))")
            }
        #else
            lines.append("file system: \(Self.volume(real))")
            lines.append("reading ahead: this system shows no setting for it")
            lines.append("memory limit: NONE FOUND (this system has no limit of this kind to look for)")
        #endif
    }

    private static func text(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        "\(bytes / (1 << 20)) MB"
    }

    #if os(Linux)
        private static func system() -> String {
            "Linux \(text("/proc/sys/kernel/osrelease") ?? "of a release that could not be read")"
        }

        private static func memory() -> String {
            guard let meminfo = text("/proc/meminfo") else { return "not read" }
            func kilobytes(_ name: String) -> UInt64? {
                for line in meminfo.split(separator: "\n") where line.hasPrefix(name + ":") {
                    return line.split(separator: " ").dropFirst().first.flatMap { UInt64($0) }
                }
                return nil
            }
            let total = kilobytes("MemTotal").map { megabytes($0 * 1024) } ?? "not read"
            let available = kilobytes("MemAvailable").map { megabytes($0 * 1024) } ?? "not read"
            return "\(total) in all, \(available) available when the report began"
        }

        /// One line of the system's list of mounts.
        struct Mount {
            /// The device as the list writes it, `major:minor`.
            let device: String
            /// The folder of the file system that is mounted.
            let root: String
            let mountPoint: String
            let kind: String
            let source: String
            let options: String

            /// The system's list, or nothing if it cannot be read.
            static func all() -> [Mount] {
                guard let list = ColdMachine.text("/proc/self/mountinfo") else { return [] }
                return list.split(separator: "\n").compactMap { line in
                    // "36 35 98:0 /root /mount/point options optional... - kind source options"
                    let halves = line.components(separatedBy: " - ")
                    guard halves.count == 2 else { return nil }
                    let left = halves[0].split(separator: " ")
                    let right = halves[1].split(separator: " ")
                    guard left.count >= 6, right.count >= 2 else { return nil }
                    return Mount(
                        device: String(left[2]), root: unescaped(left[3]), mountPoint: unescaped(left[4]),
                        kind: String(right[0]), source: String(right[1]),
                        options: String(left[5]) + (right.count > 2 ? "," + right[2] : ""))
                }
            }

            /// A path of the list with its escapes undone: a space, a tab, a
            /// line end and a backslash are written as a backslash and three
            /// octal digits.
            private static func unescaped(_ field: Substring) -> String {
                var path = String(field)
                for (escape, character) in [("\\040", " "), ("\\011", "\t"), ("\\012", "\n"), ("\\134", "\\")] {
                    path = path.replacingOccurrences(of: escape, with: character)
                }
                return path
            }

            /// The mount `path` is on: the one with the longest mount point
            /// that is the path or a folder above it, and of several such the
            /// last, which is the one mounted over the others.
            static func holding(_ path: String, in mounts: [Mount]) -> Mount? {
                var best: Mount?
                for mount in mounts {
                    let point = mount.mountPoint
                    guard point == "/" || path == point || path.hasPrefix(point + "/") else { continue }
                    if best == nil || point.count >= best!.mountPoint.count { best = mount }
                }
                return best
            }
        }

        /// How far the system reads ahead on the volume, each figure with
        /// the file that says it: the file system's own setting, which is
        /// what a read of a file goes by, and the setting of the device it
        /// is made on, with whether the system takes that device for a
        /// turning disk. Where neither is
        /// found, what every backing device of the system says.
        private static func readAhead(_ mount: Mount) -> String {
            var found: [String] = []
            func look(_ what: String, _ path: String) -> Bool {
                guard let value = text(path) else { return false }
                found.append("\(what) \(value) KB (\(path))")
                return true
            }
            func entries(_ folder: String) -> [String] {
                ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            }
            // the device's name as the system's files have it, behind any link
            let name =
                mount.source.hasPrefix("/dev/")
                ? URL(fileURLWithPath: mount.source).resolvingSymlinksInPath().lastPathComponent : nil
            // the file system's: under its device number, or for btrfs, which
            // makes a number of its own, under the volume that has the device
            if !look("the file system", "/sys/class/bdi/\(mount.device)/read_ahead_kb"), mount.kind == "btrfs",
                let name
            {
                for volume in entries("/sys/fs/btrfs")
                where FileManager.default.fileExists(atPath: "/sys/fs/btrfs/\(volume)/devices/\(name)") {
                    _ = look("the file system", "/sys/fs/btrfs/\(volume)/bdi/read_ahead_kb")
                }
            }
            // the device's: its own queue, or for a partition the disk's
            if let name {
                for queue in ["/sys/class/block/\(name)/queue", "/sys/class/block/\(name)/../queue"]
                where look("the device \(name)", queue + "/read_ahead_kb") {
                    if let turns = text(queue + "/rotational") {
                        found.append("a turning disk by the system's word: \(turns == "1" ? "yes" : "no")")
                    }
                    break
                }
            }
            if !found.isEmpty { return found.joined(separator: "; ") }
            let all = entries("/sys/class/bdi").compactMap { name in
                text("/sys/class/bdi/\(name)/read_ahead_kb").map { "\(name): \($0) KB" }
            }
            return "no setting found for device \(mount.device) on \(mount.source); every backing device of the "
                + "system: " + (all.isEmpty ? "none readable" : all.joined(separator: ", "))
        }

        /// The memory limit the process is under: the least of what its
        /// control group and the groups above it state, in either of the two
        /// layouts the system's files have. `looked` names the files read.
        private static func limit(_ mounts: [Mount]) -> (limit: MemoryLimit?, looked: [String]) {
            var looked: [String] = []
            var least: MemoryLimit?
            guard let groups = text("/proc/self/cgroup") else { return (nil, ["/proc/self/cgroup, not readable"]) }
            for line in groups.split(separator: "\n") {
                // "hierarchy:controllers:path"; the unified layout has hierarchy 0 and no controllers
                let fields = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { continue }
                let unified = fields[0] == "0" && fields[1].isEmpty
                let first = fields[1].split(separator: ",").contains("memory")
                guard unified || first else { continue }
                let file = unified ? "memory.max" : "memory.limit_in_bytes"
                let mount = mounts.first { mount in
                    unified
                        ? mount.kind == "cgroup2"
                        : mount.kind == "cgroup" && mount.options.split(separator: ",").contains("memory")
                }
                guard let mount else {
                    looked.append("no mount of the \(unified ? "unified" : "memory") control groups")
                    continue
                }
                // the group's path is from the hierarchy's root, of which the mount may show a part
                var path = String(fields[2])
                if mount.root != "/", path.hasPrefix(mount.root) { path = String(path.dropFirst(mount.root.count)) }
                if path.isEmpty { path = "/" }
                while true {
                    let name = mount.mountPoint + (path == "/" ? "" : path) + "/" + file
                    if let value = text(name) {
                        looked.append("\(name): \(value)")
                        // "max", or in the older layout a number near the largest, is no limit
                        if let bytes = UInt64(value), bytes < 1 << 60, least == nil || bytes < least!.bytes {
                            least = MemoryLimit(bytes: bytes, source: name)
                        }
                    } else {
                        looked.append("\(name): not there")
                    }
                    if path == "/" { break }
                    path = String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
                    if path.isEmpty { path = "/" }
                }
            }
            if looked.isEmpty { looked.append("/proc/self/cgroup, which names no memory group") }
            return (least, looked)
        }
    #else
        private static func system() -> String {
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        }

        private static func memory() -> String {
            "\(megabytes(ProcessInfo.processInfo.physicalMemory)) in all"
        }

        /// The kind of the volume and what it is made on.
        private static func volume(_ path: String) -> String {
            var status = statfs()
            guard statfs(path, &status) == 0 else { return "not read, error \(errno)" }
            func string<T>(_ tuple: T) -> String {
                withUnsafeBytes(of: tuple) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            return "\(string(status.f_fstypename)) on \(string(status.f_mntfromname)), "
                + "mounted at \(string(status.f_mntonname))"
        }
    #endif
}
