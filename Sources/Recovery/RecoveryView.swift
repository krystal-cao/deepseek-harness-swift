import SwiftUI

/// A native, coordinator-driven recovery surface. It only renders state from
/// `DshRecoveryViewModel`; lifecycle and runtime work stay outside the view.
public struct DshRecoveryView: View {
    @ObservedObject private var viewModel: DshRecoveryViewModel
    @State private var isDetailsExpanded = false

    public init(viewModel: DshRecoveryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusCard
            details
            actions
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620, maxWidth: 760, alignment: .topLeading)
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

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("重试") {
                    _ = viewModel.requestRetry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isActionInFlight)

                Button("打开设置") {
                    _ = viewModel.requestOpenSettings()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isActionInFlight)

                Button("安全模式") {
                    _ = viewModel.requestSafeMode()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isSafeModeAvailable || viewModel.isActionInFlight)
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
}
