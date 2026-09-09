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
                Toggle("随 MacTools 更新 CLI", isOn: Binding(
                    get: { installer.automaticUpdates }, set: { installer.setAutomaticUpdates($0) }
                )).toggleStyle(.switch)
                HStack {
                    Button("更新") { installer.install(automaticUpdates: installer.automaticUpdates) }
                    if installer.canRollback {
                        Button("回退上一版本") {
                            installer.install(automaticUpdates: installer.automaticUpdates, rollback: true)
                        }
                    }
                    Button("移除") { installer.remove() }
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.managedPath)])
                    }
                    Button("复制 CLI 路径") { copy(receipt.linkPath) }
                }
            } else {
                Button("安装 CLI…") {
                    keepUpdated = true
                    enableIntegration = true
                    showingConfirmation = true
                }.disabled(installer.manifest == nil)
            }
            if case .failed = installer.phase {
                HStack {
                    Button("重试") {
                        if installer.manifest == nil { installer.refresh() }
                        else if installer.receipt != nil { installer.install(automaticUpdates: installer.automaticUpdates) }
                        else { showingConfirmation = true }
                    }
                    Button("复制诊断信息") {
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
                Text("应用环境的 PATH 中未找到 ~/.local/bin。若终端无法找到命令，可复制以下内容添加到 shell 配置；MacTools 不会修改配置。")
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                HStack {
                    Text("export PATH=\"$HOME/.local/bin:$PATH\"").textSelection(.enabled)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                    Button("复制") { copy("export PATH=\"$HOME/.local/bin:$PATH\"") }
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

    private var status: String {
        switch installer.phase {
        case .notInstalled: "CLI 未安装"
        case .downloading: "正在下载 CLI…"
        case .verifying: "正在验证 CLI…"
        case .installing: "正在安装 CLI…"
        case .installed: "CLI 已安装"
        case .updateAvailable: "CLI 有可用更新"
        case let .failed(message): "CLI 操作未完成：\(message)"
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("安装 Nightly CLI？").font(.title2)
            if let manifest = installer.manifest, let store = installer.store {
                Text("\(manifest.cliVersion) (\(manifest.cliBuild)) · \(ByteCountFormatter.string(fromByteCount: Int64(manifest.size), countStyle: .file))")
                Text("安装目录：\n\(store.root.appendingPathComponent(manifest.directoryName).path)\n\n命令路径：\n\(store.command.path)")
                    .font(.callout).textSelection(.enabled)
                Text("MacTools 不会覆盖已有的手动安装、Homebrew 命令或其他 Nightly 渠道的安装。无需管理员密码。")
                Toggle("启用命令行集成", isOn: $enableIntegration).toggleStyle(.switch)
                    .disabled(CLIBrokerServiceController.shared.isRegistered)
                Text(enableIntegration || CLIBrokerServiceController.shared.isRegistered
                    ? "安装后允许 CLI 连接此应用。macOS 可能要求在“系统设置 → 通用 → 登录项”中另行允许后台运行。"
                    : "保留 CLI 本机命令；启用命令行集成后才能访问应用操作。")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("随 MacTools 更新 CLI", isOn: $keepUpdated).toggleStyle(.switch)
                HStack {
                    Spacer()
                    Button("取消") { showingConfirmation = false }.keyboardShortcut(.cancelAction)
                    Button("安装") {
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
