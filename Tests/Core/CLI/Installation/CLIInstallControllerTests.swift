import Foundation
import XCTest
@testable import MacTools

@MainActor
final class CLIInstallControllerTests: XCTestCase {
    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var error: CLIInstallError?
        func set(_ value: CLIInstallError?) { lock.withLock { error = value } }
        func check() throws { if let error = lock.withLock({ error }) { throw error } }
    }

    private func manifest(_ build: String) -> CLIReleaseManifest {
        CLIReleaseManifest(schema: 1, channel: "nightly", appVersion: "1.3.0", appBuild: build,
            cliVersion: "1.3.0", cliBuild: build, sourceCommit: String(repeating: "a", count: 40),
            sourceRelease: URL(string: "https://example.invalid/releases/\(build)")!,
            assetURL: URL(string: "https://example.invalid/releases/\(build)/mactools-cli-1.3.0-\(build)-macos-arm64.zip")!,
            sha256: cliSHA256(CLIArchiveTests.fixture), size: CLIArchiveTests.fixture.count,
            architecture: "arm64", signingIdentifier: "test.mactools.nightly.cli", teamIdentifier: "TESTTEAM00",
            protocolMinimum: 1, protocolMaximum: 3)
    }

    private func home() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/cli-controller-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func dependencies(_ failure: Failure) -> CLIInstaller.Dependencies {
        .init(download: { _, url in try CLIArchiveTests.fixture.write(to: url) },
              verify: { _, _ in try failure.check() }, execute: { _, _, _ in })
    }

    private func idle(_ controller: CLIInstallController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.busy)
    }

    func testRetryRemovalAfterCleanupFailureDoesNotReinstall() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = manifest("123.1")
        let controller = CLIInstallController(home: home, authenticate: { target },
            dependencies: dependencies(Failure()), prepareIntegration: { _ in false })
        controller.refresh()
        try await idle(controller)
        controller.install(automaticUpdates: true)
        try await idle(controller)
        let store = try XCTUnwrap(controller.store)
        let directory = store.root.appendingPathComponent(target.directoryName)
        let retired = store.root.appendingPathComponent(".delete-" + target.directoryName)
        defer { chmod(directory.path, 0o700); chmod(retired.path, 0o700) }
        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        controller.remove()
        try await idle(controller)
        XCTAssertEqual(controller.failedOperation, .remove)
        XCTAssertNil(controller.receipt)
        XCTAssertNil(try CLIManagedStore.entry(store.command))
        XCTAssertEqual(chmod(retired.path, 0o700), 0)
        controller.retry()
        try await idle(controller)
        XCTAssertEqual(controller.phase, .notInstalled)
        XCTAssertNil(controller.failedOperation)
        XCTAssertNil(try CLIManagedStore.entry(store.command))
        XCTAssertNil(try CLIManagedStore.entry(retired))
    }

    func testRetryRollbackKeepsPreviousVersionAsTarget() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let failure = Failure()
        let dependencies = dependencies(failure)
        let old = manifest("123.1")
        _ = try await CLIInstaller.install(manifest: old, automaticUpdates: false, doctor: false,
            rollback: false, home: home, dependencies: dependencies, progress: { _ in })
        let target = manifest("124.1")
        let controller = CLIInstallController(home: home, authenticate: { target },
            dependencies: dependencies, prepareIntegration: { _ in false })
        controller.refresh()
        try await idle(controller)
        controller.install(automaticUpdates: false)
        try await idle(controller)
        failure.set(.notarization)
        controller.install(automaticUpdates: false, rollback: true)
        try await idle(controller)
        XCTAssertEqual(controller.receipt?.manifest, target)
        XCTAssertEqual(controller.failedOperation, .install(automaticUpdates: false, enableIntegration: false, rollback: true))
        failure.set(nil)
        controller.retry()
        try await idle(controller)
        XCTAssertEqual(controller.receipt?.manifest, old)
        XCTAssertFalse(controller.automaticUpdates)
        XCTAssertNil(controller.failedOperation)
    }

    func testRetryFirstInstallPreservesConfirmationChoices() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = manifest("123.1")
        let failure = Failure()
        var integrationRequests: [Bool] = []
        let controller = CLIInstallController(home: home, authenticate: { target },
            dependencies: dependencies(failure), prepareIntegration: { integrationRequests.append($0); return false })
        controller.refresh()
        try await idle(controller)
        failure.set(.signature)
        controller.install(automaticUpdates: false, enableIntegration: false)
        try await idle(controller)
        XCTAssertNil(controller.receipt)
        failure.set(nil)
        controller.retry()
        try await idle(controller)
        XCTAssertEqual(controller.receipt?.manifest, target)
        XCTAssertFalse(controller.automaticUpdates)
        XCTAssertEqual(integrationRequests, [false, false])
    }

    func testRetryPreferenceChangeDoesNotInstallAvailableUpdate() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = manifest("123.1")
        let dependencies = dependencies(Failure())
        _ = try await CLIInstaller.install(manifest: old, automaticUpdates: true, doctor: false,
            rollback: false, home: home, dependencies: dependencies, progress: { _ in })
        let target = manifest("124.1")
        let controller = CLIInstallController(home: home, authenticate: { target },
            dependencies: dependencies, prepareIntegration: { _ in false })
        controller.refresh()
        try await idle(controller)
        let store = try XCTUnwrap(controller.store)
        let lock = try store.lock(create: false)
        controller.setAutomaticUpdates(false)
        try await idle(controller)
        XCTAssertEqual(controller.failedOperation, .setAutomaticUpdates(false))
        close(lock)
        controller.retry()
        try await idle(controller)
        XCTAssertEqual(controller.receipt?.manifest, old)
        XCTAssertFalse(controller.automaticUpdates)
        XCTAssertNil(controller.failedOperation)
    }

    func testRetryMetadataFailureRefreshesWithoutInstalling() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = manifest("123.1")
        let failure = Failure()
        failure.set(.metadata)
        let controller = CLIInstallController(home: home, authenticate: { try failure.check(); return target },
            dependencies: dependencies(Failure()), prepareIntegration: { _ in XCTFail("Must not install"); return false })
        controller.refresh(updateOnLaunch: true)
        try await idle(controller)
        XCTAssertEqual(controller.failedOperation, .refresh(updateOnLaunch: true))
        failure.set(nil)
        controller.retry()
        try await idle(controller)
        XCTAssertEqual(controller.manifest, target)
        XCTAssertEqual(controller.phase, .notInstalled)
        XCTAssertNil(controller.receipt)
    }
}
