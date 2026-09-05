import SwiftUI

/// A native, coordinator-driven recovery surface. It only renders state from
/// `DshRecoveryViewModel`; lifecycle and runtime work stay outside the view.
public struct DshRecoveryView: View {
    @ObservedObject private var viewModel: DshRecoveryViewModel
    @State private var isDetailsExpanded = false
    @State private var isDiagnosticPreviewExpanded = false
    @State private var isPluginRemovalConfirmationPresented = false

    public init(viewModel: DshRecoveryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusCard
            pluginFailureSection
            details
            diagnosticExport
            actions
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620, maxWidth: 760, alignment: .topLeading)
        .confirmationDialog(
            "确认移除并重试？",
            isPresented: $isPluginRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("移除所选插件并重试", role: .destructive) {
                _ = viewModel.requestRemovePluginAndRetry()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将修改原 desktop Profile。仅在唯一定位到非受管理插件且启动代次、Profile 路径仍有效时执行；恢复服务会先停止，无法确认归属的依赖不会被修改。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("无法完成启动")
                .font(.title2.weight(.semibold))
            Text("可以重试，或打开设置检查运行环境。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(viewModel.phaseTitle)
                    .font(.headline)
                Spacer()
                if viewModel.isActionInFlight {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(viewModel.failureSummary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let code = viewModel.failureCodeTitle {
                Text("错误码：\(code)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let actionMessage = viewModel.actionMessage {
                Text(actionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
    }

    private var details: some View {
        DisclosureGroup("查看诊断详情", isExpanded: $isDetailsExpanded) {
            ScrollView {
                Text(viewModel.redactedDetails)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 90, maxHeight: 220)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
        .font(.callout.weight(.semibold))
    }

    private var pluginFailureSection: some View {
        Group {
            if let analysis = viewModel.pluginFailureAnalysis {
                VStack(alignment: .leading, spacing: 10) {
                    Text("插件故障定位")
                        .font(.headline)
                    Text(analysis.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(analysis.candidates.enumerated()), id: \.offset) { _, candidate in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(candidate.resolution.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                Text(candidate.pluginName ?? "未识别插件")
                                    .font(.subheadline.monospaced())
                                Spacer()
                            }
                            ForEach(Array(candidate.evidence.prefix(3).enumerated()), id: \.offset) { _, evidence in
                                Text("· \(evidence.source.rawValue)：\(evidence.summary)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("移除计划：\(candidate.removalPlan.reason)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        }
                    }

                    if viewModel.canRequestPluginRemoval {
                        Button("移除所选插件并重试") {
                            isPluginRemovalConfirmationPresented = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.pluginRemovalInFlight || viewModel.isActionInFlight)
                    } else {
                        Text("当前仅提供只读定位；证据不唯一、共享依赖、web Profile、受管理组件或 patch 不完整时不会执行移除。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.07))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("重试") {
                    _ = viewModel.requestRetry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isActionInFlight || viewModel.pluginRemovalInFlight)

                Button("打开设置") {
                    _ = viewModel.requestOpenSettings()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isActionInFlight || viewModel.pluginRemovalInFlight)

                Button("安全模式") {
                    _ = viewModel.requestSafeMode()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isSafeModeAvailable || viewModel.isActionInFlight || viewModel.pluginRemovalInFlight)
                .help(viewModel.safeModeAvailabilityDescription)
            }

            if !viewModel.isSafeModeAvailable {
                Text(viewModel.safeModeAvailabilityDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnosticExport: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("生成预览") {
                    _ = viewModel.refreshDiagnosticPreview()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasDiagnosticSnapshot)

                Button("复制诊断摘要") {
                    _ = viewModel.requestCopyDiagnosticSummary()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasDiagnosticSnapshot)

                Button("保存 JSON") {
                    _ = viewModel.requestSaveDiagnosticExport()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasDiagnosticSnapshot)
            }

            if let preview = viewModel.diagnosticPreview {
                DisclosureGroup("诊断导出预览", isExpanded: $isDiagnosticPreviewExpanded) {
                    ScrollView {
                        Text(preview)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 90, maxHeight: 240)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    }
                    Text("\(viewModel.diagnosticPreviewByteCount) bytes · 仅包含脱敏诊断信息")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.semibold))
            }
        }
    }
}
