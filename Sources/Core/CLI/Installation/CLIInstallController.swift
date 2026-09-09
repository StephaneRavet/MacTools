import Foundation

enum CLIInstallPhase: Equatable, Sendable {
    case notInstalled, downloading, verifying, installing, installed, updateAvailable
    case failed(String)
}

enum CLIInstallLaunchPolicy {
    static func shouldUpdate(receipt: CLIManagedReceipt?, target: CLIReleaseManifest, optedIn: Bool) -> Bool {
        guard let receipt, optedIn else { return false }
        return receipt.manifest != target
    }
}

@MainActor
final class CLIInstallController: ObservableObject {
    static let shared = CLIInstallController()
    @Published private(set) var manifest: CLIReleaseManifest?
    @Published private(set) var receipt: CLIManagedReceipt?
    @Published private(set) var phase: CLIInstallPhase = .notInstalled
    @Published private(set) var automaticUpdates = true
    @Published private(set) var busy = false
    @Published private(set) var canRollback = false
    private var didStart = false

    static var isSupportedChannel: Bool {
        #if arch(arm64)
        Bundle.main.object(forInfoDictionaryKey: "MTReleaseChannel") as? String == "nightly"
        #else
        false
        #endif
    }

    var store: CLIManagedStore? { manifest.map { CLIManagedStore(manifest: $0) } }

    func start() {
        guard Self.isSupportedChannel, !didStart else { return }
        didStart = true
        refresh(updateOnLaunch: true)
    }

    func refresh(updateOnLaunch: Bool = false) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    let manifest = try CLIReleaseManifest.authenticated()
                    let store = CLIManagedStore(manifest: manifest)
                    guard try CLIManagedStore.entry(store.root) != nil else {
                        return (manifest, nil as CLIManagedState?, nil as CLIManagedReceipt?)
                    }
                    let lock = try store.lock(create: false)
                    defer { close(lock) }
                    let state = try store.recover()
                    let receipt = try state?.active.map { try store.receipt($0) }
                    return (manifest, state, receipt)
                }.value
                manifest = snapshot.0
                receipt = snapshot.2
                automaticUpdates = snapshot.1?.automaticUpdates ?? true
                canRollback = snapshot.1?.previous != nil && receipt != nil
                if let receipt {
                    phase = receipt.manifest == manifest ? .installed : .updateAvailable
                    if !receipt.manifest.isCompatible { phase = .failed(CLIInstallError.incompatible.localizedDescription) }
                } else { phase = .notInstalled }
                busy = false
                if updateOnLaunch, CLIInstallLaunchPolicy.shouldUpdate(receipt: receipt, target: snapshot.0, optedIn: automaticUpdates) {
                    install(automaticUpdates: true)
                }
            } catch {
                phase = .failed(error.localizedDescription)
                busy = false
            }
        }
    }

    func install(automaticUpdates: Bool, enableIntegration: Bool = false, rollback: Bool = false) {
        guard !busy, let manifest else { return }
        busy = true
        phase = .downloading
        if enableIntegration { CLIBrokerServiceController.shared.ensureRegistered() }
        let doctor = CLIBrokerServiceController.shared.status == .enabled
        let progress: @Sendable (CLIInstallPhase) async -> Void = { [weak self] phase in
            await MainActor.run { self?.phase = phase }
        }
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try await CLIInstaller.install(manifest: manifest, automaticUpdates: automaticUpdates,
                                                   doctor: doctor, rollback: rollback, progress: progress)
                }.value
                receipt = result.0
                canRollback = result.1.previous != nil
                self.automaticUpdates = result.1.automaticUpdates
                phase = receipt?.manifest == manifest ? .installed : .updateAvailable
            } catch {
                phase = .failed(error.localizedDescription)
            }
            busy = false
        }
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        mutate { store in
            guard var state = try store.recover(), state.active != nil else { throw CLIInstallError.ownership }
            state.automaticUpdates = enabled
            try store.writeState(state)
        }
    }

    func remove() { mutate { try $0.remove() } }

    private func mutate(_ action: @escaping @Sendable (CLIManagedStore) throws -> Void) {
        guard !busy, let store else { return }
        busy = true
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    let lock = try store.lock(create: false)
                    defer { close(lock) }
                    try action(store)
                }.value
                busy = false
                refresh()
            } catch {
                phase = .failed(error.localizedDescription)
                busy = false
            }
        }
    }
}

enum CLIInstaller {
    struct Dependencies: Sendable {
        var download: @Sendable (CLIReleaseManifest, URL) async throws -> Void
        var verify: @Sendable (URL, CLIReleaseManifest) throws -> Void
        var execute: @Sendable (URL, CLIReleaseManifest, Bool) throws -> Void
        static let live = Dependencies(download: { try await CLIBoundedDownload.fetch($0, to: $1) },
            verify: { try CLIArtifactVerifier.verifyExecutable($0, manifest: $1) },
            execute: { try CLIArtifactVerifier.validateExecution($0, manifest: $1, doctor: $2) })
    }

    static func install(manifest: CLIReleaseManifest, automaticUpdates: Bool, doctor: Bool,
                        rollback: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        dependencies: Dependencies = .live,
                        progress: @Sendable (CLIInstallPhase) async -> Void) async throws
        -> (CLIManagedReceipt, CLIManagedState) {
        let store = CLIManagedStore(manifest: manifest, home: home)
        let lock = try store.lock(create: true)
        defer { close(lock) }
        let state = try store.recover()
        try store.cleanStaging()
        try store.checkCommand(allowMissing: state?.active == nil)
        let name: String
        if rollback {
            guard let previous = state?.previous else { throw CLIInstallError.ownership }
            name = previous
            guard try store.receipt(name).manifest.isCompatible else { throw CLIInstallError.incompatible }
        } else { name = manifest.directoryName }

        let destination = store.root.appendingPathComponent(name)
        if try CLIManagedStore.entry(destination) == nil {
            guard !rollback else { throw CLIInstallError.ownership }
            let stage = store.root.appendingPathComponent(".stage-" + UUID().uuidString)
            guard mkdir(stage.path, 0o700) == 0 else { throw CLIInstallError.filesystem }
            try Data(store.owner.utf8).write(to: stage.appendingPathComponent("owner"), options: .withoutOverwriting)
            defer {
                // Only our own staging names; no recursive traversal or symlink following.
                for file in ["archive.zip", "mactools", "LICENSE", "receipt.json", "owner"] {
                    unlink(stage.appendingPathComponent(file).path)
                }
                rmdir(stage.path)
            }
            let archiveURL = stage.appendingPathComponent("archive.zip")
            try await dependencies.download(manifest, archiveURL)
            await progress(.verifying)
            try CLIManagedStore.regular(archiveURL)
            let archive = try Data(contentsOf: archiveURL)
            guard archive.count == manifest.size, cliSHA256(archive) == manifest.sha256 else { throw CLIInstallError.archive }
            try CLIArchive.validate(archive)
            try CLIArtifactVerifier.quarantine(archiveURL)
            for file in ["mactools", "LICENSE"] {
                let data = try CLIProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                    ["-p", archiveURL.path, file],
                    limit: file == "mactools" ? CLIReleaseManifest.maximumArchiveSize : 65536)
                let url = stage.appendingPathComponent(file)
                try data.write(to: url, options: .withoutOverwriting)
                guard chmod(url.path, file == "mactools" ? 0o755 : 0o644) == 0 else { throw CLIInstallError.filesystem }
                try CLIArtifactVerifier.quarantine(url)
            }
            let executable = stage.appendingPathComponent("mactools")
            try dependencies.verify(executable, manifest)
            try dependencies.execute(executable, manifest, false)
            let receipt = CLIManagedReceipt(owner: store.owner, manifest: manifest,
                executableHash: cliSHA256(try Data(contentsOf: executable)),
                managedPath: destination.appendingPathComponent("mactools").path, linkPath: store.command.path)
            try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
            for file in ["mactools", "LICENSE", "receipt.json"] {
                try CLIManagedStore.synchronizeFile(stage.appendingPathComponent(file))
            }
            guard unlink(archiveURL.path) == 0, unlink(stage.appendingPathComponent("owner").path) == 0,
                  renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw CLIInstallError.filesystem
            }
        }
        await progress(.verifying)
        let candidate = try store.receipt(name)
        guard rollback || candidate.manifest == manifest else { throw CLIInstallError.ownership }
        try dependencies.verify(URL(fileURLWithPath: candidate.managedPath), candidate.manifest)
        await progress(.installing)
        let active = try store.activate(name, automaticUpdates: automaticUpdates) { executable, release in
            try dependencies.execute(executable, release, false)
            if doctor { try dependencies.execute(executable, manifest, true) }
        }
        try store.prune(keeping: active)
        return (try store.receipt(name), active)
    }
}
