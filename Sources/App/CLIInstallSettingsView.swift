import AppKit
import MacToolsPluginKit
import SwiftUI

struct CLIInstallSettingsView: View {
    @ObservedObject private var installer = CLIInstallController.shared
    @State private var showingConfirmation = false
    @State private var keepUpdated = true
    @State private var enableIntegration = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status).font(PluginSettingsTheme.Typography.rowDescription)
                .textSelection(.enabled)
            if let receipt = installer.receipt {
                Text("\(receipt.manifest.cliVersion) (\(receipt.manifest.cliBuild))\n\(receipt.linkPath)")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Toggle(CLIInstallCopy.keepUpdated.text, isOn: Binding(
                    get: { installer.automaticUpdates }, set: { installer.setAutomaticUpdates($0) }
                )).toggleStyle(.switch)
                HStack {
                    Button(CLIInstallCopy.update.text) { installer.install(automaticUpdates: installer.automaticUpdates) }
                    if installer.canRollback {
                        Button(CLIInstallCopy.rollback.text) {
                            installer.install(automaticUpdates: installer.automaticUpdates, rollback: true)
                        }
                    }
                    Button(CLIInstallCopy.remove.text) { installer.remove() }
                    Button(CLIInstallCopy.reveal.text) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.managedPath)])
                    }
                    Button(CLIInstallCopy.copyPath.text) { copy(receipt.linkPath) }
                }
            } else {
                Button(CLIInstallCopy.installPrompt.text) {
                    keepUpdated = true
                    enableIntegration = true
                    showingConfirmation = true
                }.disabled(installer.manifest == nil)
            }
            if case .failed = installer.phase {
                HStack {
                    Button(CLIInstallCopy.retry.text) {
                        installer.retry()
                    }
                    Button(CLIInstallCopy.copyDiagnostics.text) {
                        copy([status,
                              "App/target: \(installer.manifest?.appVersion ?? "unknown") (\(installer.manifest?.appBuild ?? "unknown"))",
                              "Installed: \(installer.receipt?.manifest.cliBuild ?? "none")",
                              "Managed updates: \(installer.automaticUpdates)",
                              "Command: \(installer.store?.command.path ?? "unavailable")",
                              "Broker: \(CLIBrokerServiceController.shared.status.rawValue)"].joined(separator: "\n"))
                    }
                }
            }
            if let directory = installer.store?.command.deletingLastPathComponent().path,
               !(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(directory)) {
                Text(CLIInstallCopy.pathHelp.text)
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                HStack {
                    Text("export PATH=\"$HOME/.local/bin:$PATH\"").textSelection(.enabled)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                    Button(CLIInstallCopy.copy.text) { copy("export PATH=\"$HOME/.local/bin:$PATH\"") }
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(installer.busy)
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .onAppear { installer.start() }
        .sheet(isPresented: $showingConfirmation) { confirmation }
    }

    private var status: String { CLIInstallCopy.status(installer.phase, error: installer.lastError) }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(CLIInstallCopy.confirmTitle.text).font(.title2)
            if let manifest = installer.manifest, let store = installer.store {
                Text("\(manifest.cliVersion) (\(manifest.cliBuild)) · \(ByteCountFormatter.string(fromByteCount: Int64(manifest.size), countStyle: .file))")
                Text(CLIInstallCopy.paths.format(
                    store.root.appendingPathComponent(manifest.directoryName).path, store.command.path))
                    .font(.callout).textSelection(.enabled)
                Text(CLIInstallCopy.ownershipHelp.text)
                Toggle(CLIInstallCopy.enableIntegration.text, isOn: $enableIntegration).toggleStyle(.switch)
                    .disabled(CLIBrokerServiceController.shared.isRegistered)
                Text(enableIntegration || CLIBrokerServiceController.shared.isRegistered
                    ? CLIInstallCopy.integrationOn.text
                    : CLIInstallCopy.integrationOff.text)
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(CLIInstallCopy.keepUpdated.text, isOn: $keepUpdated).toggleStyle(.switch)
                HStack {
                    Spacer()
                    Button(CLIInstallCopy.cancel.text) { showingConfirmation = false }.keyboardShortcut(.cancelAction)
                    Button(CLIInstallCopy.install.text) {
                        showingConfirmation = false
                        installer.install(automaticUpdates: keepUpdated, enableIntegration: enableIntegration)
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 540)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
