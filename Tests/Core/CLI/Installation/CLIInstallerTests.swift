import Foundation
import XCTest
@testable import MacTools

final class CLIInstallerTests: XCTestCase, @unchecked Sendable {
    private var home: URL!
    override func setUpWithError() throws {
        home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("cli-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func manifest(_ build: String) -> CLIReleaseManifest {
        CLIReleaseManifest(schema: 1, channel: "nightly", appVersion: "1.3.0", appBuild: build,
            cliVersion: "1.3.0", cliBuild: build, sourceCommit: String(repeating: "a", count: 40),
            sourceRelease: URL(string: "https://example.invalid/releases/\(build)")!,
            assetURL: URL(string: "https://example.invalid/releases/\(build)/mactools-cli-1.3.0-\(build)-macos-arm64.zip")!,
            sha256: cliSHA256(CLIArchiveTests.fixture), size: CLIArchiveTests.fixture.count,
            architecture: "arm64", signingIdentifier: "test.mactools.nightly.cli", teamIdentifier: "TESTTEAM00",
            protocolMinimum: 1, protocolMaximum: 3)
    }

    private var fixtureDependencies: CLIInstaller.Dependencies {
        CLIInstaller.Dependencies(download: { _, url in try CLIArchiveTests.fixture.write(to: url) },
                                  verify: { _, _ in }, execute: { _, _, _ in })
    }

    private func install(_ build: String, dependencies: CLIInstaller.Dependencies) async throws -> CLIManagedReceipt {
        try await CLIInstaller.install(manifest: manifest(build), automaticUpdates: true, doctor: true,
            rollback: false, home: home, dependencies: dependencies, progress: { _ in }).0
    }

    func testCompletePipelineAndRetainedDowngradeUseVerifiedReceipts() async throws {
        let first = try await install("123.1", dependencies: fixtureDependencies)
        _ = try await install("124.1", dependencies: fixtureDependencies)
        var offline = fixtureDependencies
        offline.download = { _, _ in throw CLIInstallError.download }
        let restored = try await install("123.1", dependencies: offline)
        XCTAssertEqual(restored, first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.linkPath)), Data("fixture-executable".utf8))
    }

    func testEveryVerificationFailurePreservesActiveReceiptAndCommand() async throws {
        let first = try await install("123.1", dependencies: fixtureDependencies)
        let store = CLIManagedStore(manifest: manifest("123.1"), home: home)
        let inode = try CLIManagedStore.entry(store.command)?.st_ino
        for failure in [CLIInstallError.download, .archive, .signature, .identity, .version, .incompatible, .validation] {
            var dependencies = fixtureDependencies
            switch failure {
            case .download:
                dependencies.download = { _, _ in throw CLIInstallError.download }
            case .archive:
                dependencies.download = { _, url in try CLIArchiveTests.fixture.prefix(30).write(to: url) }
            case .validation:
                dependencies.execute = { _, _, doctor in if doctor { throw CLIInstallError.validation } }
            default:
                dependencies.verify = { _, _ in throw failure }
            }
            do {
                _ = try await install("124.1", dependencies: dependencies)
                XCTFail("Expected \(failure)")
            } catch { }
            XCTAssertEqual(try store.readState()?.active, first.manifest.directoryName, "\(failure)")
            XCTAssertEqual(try CLIManagedStore.entry(store.command)?.st_ino, inode)
            XCTAssertEqual(try Data(contentsOf: store.command), Data("fixture-executable".utf8))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".stage-") })
        }
    }

    func testProgressReportsVerificationBeforeActivation() async throws {
        actor Events {
            var phases: [CLIInstallPhase] = []
            func append(_ phase: CLIInstallPhase) { phases.append(phase) }
        }
        let events = Events()
        _ = try await CLIInstaller.install(manifest: manifest("123.1"), automaticUpdates: false,
            doctor: false, rollback: false, home: home, dependencies: fixtureDependencies,
            progress: { await events.append($0) })
        let phases = await events.phases
        XCTAssertEqual(phases, [.verifying, .verifying, .installing])
    }

    func testUnmanagedCollisionIsDetectedBeforeNetworkRequest() async throws {
        let store = CLIManagedStore(manifest: manifest("123.1"), home: home)
        try CLIManagedStore.directory(store.command.deletingLastPathComponent(), create: true)
        try Data("manual".utf8).write(to: store.command)
        var dependencies = fixtureDependencies
        dependencies.download = { _, _ in XCTFail("Must not download during a command collision") }
        do {
            _ = try await install("123.1", dependencies: dependencies)
            XCTFail("Expected collision")
        } catch { XCTAssertEqual(error as? CLIInstallError, .collision) }
        XCTAssertEqual(try Data(contentsOf: store.command), Data("manual".utf8))
    }

    func testRetentionFailureCannotReportFailureAfterChangingActiveCLI() async throws {
        let first = try await install("123.1", dependencies: fixtureDependencies)
        let store = CLIManagedStore(manifest: manifest("123.1"), home: home)
        let orphan = store.root.appendingPathComponent(manifest("122.1").directoryName)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let foreign = orphan.appendingPathComponent("user-file")
        try Data("preserve".utf8).write(to: foreign)
        do {
            _ = try await install("124.1", dependencies: fixtureDependencies)
            XCTFail("Expected retention ownership failure")
        } catch { XCTAssertEqual(error as? CLIInstallError, .ownership) }
        XCTAssertEqual(try store.readState()?.active, first.manifest.directoryName)
        XCTAssertEqual(try Data(contentsOf: foreign), Data("preserve".utf8))
    }

    func testRepeatedUpdatesBoundRetentionWithoutDeletingJournalReferences() async throws {
        for build in ["120.1", "121.1", "122.1", "123.1", "124.1"] {
            _ = try await install(build, dependencies: fixtureDependencies)
        }
        let store = CLIManagedStore(manifest: manifest("124.1"), home: home)
        let versions = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix("1.3.0-") }
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(try store.readState()?.active, manifest("124.1").directoryName)
        XCTAssertEqual(try store.readState()?.previous, manifest("123.1").directoryName)
    }
}
