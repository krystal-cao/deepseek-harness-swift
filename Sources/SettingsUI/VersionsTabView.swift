import SwiftUI

public struct VersionsTabView: View {
    @ObservedObject var viewModel = SettingsViewModel.shared

    public init() {}

    private var currentVersion: String? {
        viewModel.selectedVersion
    }

    private var targetVersion: String? {
        viewModel.runtimeChannel == .next ? viewModel.nextVersion : viewModel.latestVersion
    }

    private var channelName: String {
        viewModel.runtimeChannel == .next ? "next" : "latest"
    }

    private var automaticUpdatesAllowed: Bool {
        viewModel.runtimeChannel == .latest
    }

    private var runtimeChannelSelection: Binding<DshRuntimeChannel> {
        Binding(
            get: { viewModel.runtimeChannel },
            set: {
                viewModel.runtimeChannel = $0
                if $0 == .next {
                    viewModel.autoFollowLatest = false
                }
                viewModel.saveGeneralSettings()
            }
        )
    }

    private var hasUpdate: Bool {
        guard let current = currentVersion,
              let targetVersion else { return false }
        return DshVersionManager.shared.isVersionNewer(targetVersion, than: current)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(
                "DSH Runtime",
                footer: "Runtime 只从当前 npm Registry 向允许通道中的更高版本更新；升级失败会自动恢复上一版本。"
            ) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentVersion ?? "未安装")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text("来源：npm Registry · 通道：\(channelName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if currentVersion != nil {
                        Text("运行中")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }
                .padding(14)
            }

            if viewModel.isInstallingVersion {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.installProgressPhase)
                            .font(.system(size: 12, weight: .medium))
                        if let detail = viewModel.installProgressDetail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            SettingsSection(
                "更新",
                footer: "GitHub Release、历史版本和任意降级不会参与更新流程。"
            ) {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: automaticUpdatesAllowed
                            ? (viewModel.autoFollowLatest ? "自动更新已开启" : "自动更新已关闭")
                            : "next 通道已禁用自动更新",
                        description: !automaticUpdatesAllowed
                            ? "next 通道不允许自动安装；切回 stable（latest）后才可以重新启用。"
                            : (viewModel.autoFollowLatest
                                ? "启动后自动安装并切换到 npm latest 的更高版本，完成服务和页面验证后重启 DSH。"
                                : "启动后只检查选定通道中的 npm 更新，不会自动安装。")
                    ) {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Toggle("", isOn: Binding(
                                get: { viewModel.autoFollowLatest },
                                set: {
                                    guard automaticUpdatesAllowed else { return }
                                    viewModel.autoFollowLatest = $0
                                    viewModel.saveGeneralSettings()
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(!automaticUpdatesAllowed)
                        }
                        .frame(width: 220, alignment: .trailing)
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: viewModel.runtimeChannel == .next ? "更新通道：next" : "更新通道：latest",
                        description: viewModel.runtimeChannel == .next
                            ? "只使用当前 npm Registry 的 next tag；仍禁止 Alpha、Beta、降级和 GitHub-only 版本。"
                            : "使用当前 npm Registry 的 latest tag；这是推荐的稳定更新通道。"
                    ) {
                        Picker("", selection: runtimeChannelSelection) {
                            Text("latest").tag(DshRuntimeChannel.latest)
                            Text("next").tag(DshRuntimeChannel.next)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 150, alignment: .trailing)
                    }

                    SettingsDivider()

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            if let target = targetVersion {
                                Text(hasUpdate ? "发现新版本 \(target)" : "当前已是最新版本")
                                    .font(.system(size: 12, weight: .medium))
                                Text("npm \(channelName)：\(target)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("尚未获取版本目录")
                                    .font(.system(size: 12, weight: .medium))
                                Text("版本信息来自当前配置的 npm Registry")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if hasUpdate {
                            Button("更新到 \(targetVersion ?? "目标版本")") {
                                viewModel.updateToSelectedChannel()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(viewModel.isUpdatingRuntime)
                        }

                        Button {
                            Task { await viewModel.refreshCatalog() }
                        } label: {
                            HStack(spacing: 5) {
                                if viewModel.isLoadingCatalog {
                                    ProgressView().controlSize(.small)
                                }
                                Text(viewModel.isLoadingCatalog ? "正在检查…" : "检查更新")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isLoadingCatalog || viewModel.isUpdatingRuntime)
                    }
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("版本兼容性说明")
                    .font(.footnote.weight(.semibold))
                Text("当前只接受 npm 中可验证的 stable/RC 版本。升级会保留本次升级前的 Runtime；新 Runtime 连续两次成功启动后自动清理旧副本。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
        }
        .task {
            if viewModel.availableVersions.isEmpty {
                await viewModel.refreshCatalog()
            }
        }
    }
}
