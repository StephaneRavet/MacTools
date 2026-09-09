import Darwin
import Foundation

struct CLIManagedReceipt: Codable, Equatable, Sendable {
    let owner: String
    let manifest: CLIReleaseManifest
    let executableHash: String
    let managedPath: String
    let linkPath: String
}

struct CLIManagedState: Codable, Sendable {
    let owner: String
    var active: String?
    var previous: String?
    var automaticUpdates: Bool
    var pending: Bool
}

/// All writes are per-user and serialized by a no-follow flock. The command symlink is created
/// with symlink(2), never rename-overwritten. Only the private `current` pointer changes on update.
struct CLIManagedStore: Sendable {
    let root: URL
    let command: URL
    let owner: String
    private var current: URL { root.appendingPathComponent("current") }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    var commandTarget: String { current.appendingPathComponent("mactools").path }

    init(manifest: CLIReleaseManifest, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        owner = Self.owner(for: manifest)
        root = home.appendingPathComponent("Library/Application Support/MacTools Nightly/CLI/" + owner)
        command = home.appendingPathComponent(".local/bin/mactools-nightly")
    }

    private static func owner(for manifest: CLIReleaseManifest) -> String {
        cliSHA256(Data((manifest.signingIdentifier + "|" + manifest.teamIdentifier + "|"
            + manifest.sourceRelease.deletingLastPathComponent().absoluteString).utf8))
    }

    static func entry(_ url: URL) throws -> stat? {
        var result = stat()
        if lstat(url.path, &result) == 0 { return result }
        if errno == ENOENT { return nil }
        throw CLIInstallError.filesystem
    }

    static func regular(_ url: URL, maximum: Int = CLIReleaseManifest.maximumArchiveSize) throws {
        guard let info = try entry(url), info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximum else { throw CLIInstallError.ownership }
    }

    /// Reject redirected parents, including .local/bin, instead of following user-created links.
    static func directory(_ url: URL, create: Bool) throws {
        if url.path == "/" { return }
        try directory(url.deletingLastPathComponent(), create: create)
        if try entry(url) == nil, create {
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw CLIInstallError.filesystem }
        }
        guard let info = try entry(url), info.st_mode & S_IFMT == S_IFDIR else { throw CLIInstallError.ownership }
    }

    func lock(create: Bool) throws -> Int32 {
        try Self.directory(root, create: create)
        guard let info = try Self.entry(root), info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CLIInstallError.ownership
        }
        let url = root.appendingPathComponent("lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CLIInstallError.ownership }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CLIInstallError.busy
        }
        return descriptor
    }

    func readState() throws -> CLIManagedState? {
        guard try Self.entry(stateURL) != nil else { return nil }
        try Self.regular(stateURL, maximum: 16384)
        let state = try JSONDecoder().decode(CLIManagedState.self, from: Data(contentsOf: stateURL))
        guard state.owner == owner else { throw CLIInstallError.ownership }
        for version in [state.active, state.previous].compactMap({ $0 }) {
            _ = try receipt(version)
        }
        return state
    }

    func writeState(_ state: CLIManagedState) throws {
        if try Self.entry(stateURL) != nil { try Self.regular(stateURL, maximum: 16384) }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try Self.synchronizeFile(stateURL)
        try syncRoot()
    }

    func receipt(_ name: String) throws -> CLIManagedReceipt {
        guard name.range(of: "^[0-9]+(\\.[0-9]+){0,3}-[0-9]+(\\.[0-9]+){0,3}-[a-f0-9]{12}$",
                         options: .regularExpression) != nil else { throw CLIInstallError.ownership }
        let directory = root.appendingPathComponent(name)
        try Self.directory(directory, create: false)
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["mactools", "LICENSE", "receipt.json"] else {
            throw CLIInstallError.ownership
        }
        let receiptURL = directory.appendingPathComponent("receipt.json")
        try Self.regular(receiptURL, maximum: 16384)
        let receipt = try JSONDecoder().decode(CLIManagedReceipt.self, from: Data(contentsOf: receiptURL))
        let executable = directory.appendingPathComponent("mactools")
        try Self.regular(executable)
        try Self.regular(directory.appendingPathComponent("LICENSE"), maximum: 65536)
        guard receipt.owner == owner, Self.owner(for: receipt.manifest) == owner,
              receipt.manifest.channel == "nightly",
              receipt.manifest.directoryName == name, receipt.managedPath == executable.path,
              receipt.linkPath == command.path,
              receipt.executableHash == cliSHA256(try Data(contentsOf: executable)) else { throw CLIInstallError.ownership }
        return receipt
    }

    func checkCommand(allowMissing: Bool) throws {
        guard let info = try Self.entry(command) else {
            if allowMissing { return }
            throw CLIInstallError.ownership
        }
        guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == geteuid(),
              try FileManager.default.destinationOfSymbolicLink(atPath: command.path) == commandTarget,
              let state = try readState(), state.active != nil else { throw CLIInstallError.collision }
    }

    private func checkCurrent(expected: String?) throws {
        guard let info = try Self.entry(current) else {
            if expected == nil { return }
            throw CLIInstallError.ownership
        }
        guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == geteuid(),
              let expected, try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == expected else {
            throw CLIInstallError.ownership
        }
    }

    private func switchCurrent(from old: String?, to next: String?) throws {
        try checkCurrent(expected: old)
        if old == next { return }
        if let next {
            _ = try receipt(next)
            let temporary = root.appendingPathComponent(".link-" + UUID().uuidString)
            guard symlink(next, temporary.path) == 0 else { throw CLIInstallError.filesystem }
            defer { unlink(temporary.path) }
            if old == nil {
                guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, current.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw CLIInstallError.filesystem
                }
            } else {
                guard rename(temporary.path, current.path) == 0 else { throw CLIInstallError.filesystem }
            }
        } else if old != nil {
            guard unlink(current.path) == 0 else { throw CLIInstallError.filesystem }
        }
        try syncRoot()
    }

    /// A pending activation is never trusted on a later launch. Restore the previous receipt,
    /// including the crash window between journaling and switching the private pointer.
    func recover() throws -> CLIManagedState? {
        guard var state = try readState() else { return nil }
        guard state.pending else {
            try checkCurrent(expected: state.active)
            try checkCommand(allowMissing: state.active == nil)
            return state
        }
        let actual = try Self.entry(current) == nil ? nil : FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        guard actual == state.active || actual == state.previous else { throw CLIInstallError.ownership }
        if state.previous == nil {
            if let info = try Self.entry(command), info.st_mode & S_IFMT == S_IFLNK,
               try FileManager.default.destinationOfSymbolicLink(atPath: command.path) == commandTarget {
                guard unlink(command.path) == 0 else { throw CLIInstallError.filesystem }
            }
        }
        try switchCurrent(from: actual, to: state.previous)
        if state.previous != nil, try Self.entry(command) == nil {
            guard symlink(commandTarget, command.path) == 0 else { throw CLIInstallError.collision }
        }
        if state.previous != nil {
            guard let info = try Self.entry(command), info.st_mode & S_IFMT == S_IFLNK,
                  info.st_uid == geteuid(),
                  try FileManager.default.destinationOfSymbolicLink(atPath: command.path) == commandTarget else {
                throw CLIInstallError.collision
            }
        }
        try Self.synchronizeDirectory(command.deletingLastPathComponent())
        let failed = state.active
        state.active = state.previous
        state.previous = failed
        state.pending = false
        try writeState(state)
        return state
    }

    func activate(_ name: String, automaticUpdates: Bool,
                  validate: (URL, CLIReleaseManifest) throws -> Void) throws -> CLIManagedState {
        let old = try recover()
        _ = try receipt(name)
        try Self.directory(command.deletingLastPathComponent(), create: true)
        try checkCommand(allowMissing: old?.active == nil)
        if old?.active == name {
            guard var state = old else { throw CLIInstallError.ownership }
            let installed = try receipt(name)
            try validate(URL(fileURLWithPath: installed.managedPath), installed.manifest)
            state.automaticUpdates = automaticUpdates
            try writeState(state)
            return state
        }
        var state = CLIManagedState(owner: owner, active: name, previous: old?.active,
                                    automaticUpdates: automaticUpdates, pending: true)
        try writeState(state)
        do {
            try switchCurrent(from: old?.active, to: name)
            if old?.active == nil {
                guard symlink(commandTarget, command.path) == 0 else { throw CLIInstallError.collision }
                try Self.synchronizeDirectory(command.deletingLastPathComponent())
            }
            let installed = try receipt(name)
            try validate(command, installed.manifest)
            state.pending = false
            try writeState(state)
            return state
        } catch {
            // Recovery itself may fail after external interference; keep the journal and report it.
            _ = try recover()
            throw error
        }
    }

    func remove() throws {
        guard let state = try recover() else { return }
        try checkCommand(allowMissing: state.active == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") && $0 != "current" && $0 != "lock" && $0 != "state.json" }
        // Validate every deletion before touching the public link.
        for name in names { _ = try receipt(name) }
        try writeState(CLIManagedState(owner: owner, active: nil, previous: state.active,
                                      automaticUpdates: state.automaticUpdates, pending: true))
        if state.active != nil {
            guard unlink(command.path) == 0 else { throw CLIInstallError.filesystem }
            try Self.synchronizeDirectory(command.deletingLastPathComponent())
        }
        try switchCurrent(from: state.active, to: nil)
        try writeState(CLIManagedState(owner: owner, active: nil, previous: nil,
                                      automaticUpdates: false, pending: false))
        for name in names { try deleteVersion(name) }
    }

    func deleteVersion(_ name: String) throws {
        _ = try receipt(name)
        let directory = root.appendingPathComponent(name)
        // Never use recursive deletion: unrecognized children and links are preserved.
        for file in ["mactools", "LICENSE", "receipt.json"] {
            guard unlink(directory.appendingPathComponent(file).path) == 0 else { throw CLIInstallError.filesystem }
        }
        guard rmdir(directory.path) == 0 else { throw CLIInstallError.filesystem }
    }

    func prune(keeping state: CLIManagedState, additionallyKeeping candidate: String? = nil) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            guard name != state.active, name != state.previous, name != candidate,
                  name.range(of: "^[0-9].*-[a-f0-9]{12}$", options: .regularExpression) != nil else { continue }
            try deleteVersion(name)
        }
    }

    func cleanStaging() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasPrefix(".stage-") {
            let stage = root.appendingPathComponent(name)
            try Self.directory(stage, create: false)
            let marker = stage.appendingPathComponent("owner")
            let files = try FileManager.default.contentsOfDirectory(atPath: stage.path)
            if files.isEmpty {
                // A crash immediately after mkdir has no user data to remove.
                guard rmdir(stage.path) == 0 else { throw CLIInstallError.filesystem }
                continue
            }
            if try Self.entry(marker) != nil {
                try Self.regular(marker, maximum: 64)
                guard try String(contentsOf: marker, encoding: .utf8) == owner else { throw CLIInstallError.ownership }
            } else {
                // A crash after removing the staging marker but before renaming the verified
                // version can instead be proven by the completed receipt and executable hash.
                guard Set(files) == ["mactools", "LICENSE", "receipt.json"] else { throw CLIInstallError.ownership }
                let receiptURL = stage.appendingPathComponent("receipt.json")
                try Self.regular(receiptURL, maximum: 16384)
                let receipt = try JSONDecoder().decode(CLIManagedReceipt.self, from: Data(contentsOf: receiptURL))
                let executable = stage.appendingPathComponent("mactools")
                try Self.regular(executable)
                guard receipt.owner == owner, Self.owner(for: receipt.manifest) == owner,
                      receipt.linkPath == command.path,
                      receipt.manifest.channel == "nightly",
                      receipt.managedPath == root.appendingPathComponent(receipt.manifest.directoryName)
                        .appendingPathComponent("mactools").path,
                      receipt.executableHash == cliSHA256(try Data(contentsOf: executable)) else {
                    throw CLIInstallError.ownership
                }
            }
            guard Set(files).isSubset(of: ["owner", "archive.zip", "mactools", "LICENSE", "receipt.json"]) else {
                throw CLIInstallError.ownership
            }
            for file in files { try Self.regular(stage.appendingPathComponent(file)) }
            for file in files where file != "owner" {
                guard unlink(stage.appendingPathComponent(file).path) == 0 else { throw CLIInstallError.filesystem }
            }
            if files.contains("owner"), unlink(marker.path) != 0 { throw CLIInstallError.filesystem }
            guard rmdir(stage.path) == 0 else { throw CLIInstallError.filesystem }
        }
    }

    private func syncRoot() throws {
        try Self.synchronizeDirectory(root)
    }

    static func synchronizeFile(_ url: URL) throws {
        try regular(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CLIInstallError.filesystem }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CLIInstallError.filesystem }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CLIInstallError.filesystem }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CLIInstallError.filesystem }
    }
}
