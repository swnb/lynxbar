import SwiftUI

private struct ProcessRemediationCoordinatorKey: EnvironmentKey {
    static let defaultValue: RemediationCoordinator? = nil
}
extension EnvironmentValues {
    /// 正式应用由长生命周期宿主注入已接入 demand bridge 的 coordinator。
    /// Preview/test 不注入时会话只使用普通状态机，不创建第二套全局采样 owner。
    var processRemediationCoordinator: RemediationCoordinator? {
        get { self[ProcessRemediationCoordinatorKey.self] }
        set { self[ProcessRemediationCoordinatorKey.self] = newValue }
    }
}

/// 环境包装层推迟创建 StateObject，直到能取得正式应用注入的 coordinator。
struct ProcessRemediationSheet: View {
    let process: DisplayProcess
    let contextProvider: @MainActor () -> ProcessRemediationContext
    @Environment(\.processRemediationCoordinator) private var coordinator
    var body: some View {
        ProcessRemediationView(process: process, contextProvider: contextProvider,
                               coordinator: coordinator ?? RemediationCoordinator())
    }
}

private struct ProcessRemediationView: View {
    @StateObject private var viewModel: ProcessRemediationViewModel
    @Environment(\.dismiss) private var dismiss
    @MainActor init(process: DisplayProcess, contextProvider: @escaping @MainActor () -> ProcessRemediationContext,
                    coordinator: RemediationCoordinator) {
        _viewModel = StateObject(wrappedValue: ProcessRemediationViewModel(process: process,
            initialContext: contextProvider(), contextProvider: contextProvider, coordinator: coordinator))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProcessIconView(process: viewModel.process, size: 28)
                Text(viewModel.process.name).font(Theme.Font.title3.weight(.semibold)).lineLimit(2)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider().overlay(Theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    evidenceCard
                    actionCard
                    fallbackCard
                }.padding(16)
            }
        }
        .frame(width: 480, height: 460)
        .background(Theme.surface)
        .foregroundStyle(Theme.ink)
        .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible) {
            if viewModel.pendingConfirmation == .forceQuit {
                Button("Force Quit", role: .destructive) { viewModel.confirmPendingAction() }
            } else { Button("Quit Application") { viewModel.confirmPendingAction() } }
            Button("Cancel", role: .cancel) { viewModel.cancelConfirmation() }
        } message: { Text(confirmationMessage) }
        .onDisappear { viewModel.sheetClosed() }
    }
    private var evidenceCard: some View {
        V2Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Evidence").font(Theme.Font.subheadline.weight(.semibold))
                HStack {
                    metric("CPU", ProcessRowFormatter.cpuText(for: viewModel.process))
                    metric("Memory", Formatters.bytes(viewModel.process.memoryBytes))
                    metric("PID", String(viewModel.process.pid))
                }
                Text(evidenceExplanation).font(Theme.Font.caption).foregroundStyle(Theme.secondaryInk)
                Text(identityExplanation).font(Theme.Font.microMono).foregroundStyle(Theme.mutedInk).textSelection(.enabled)
                Text(String(format: NSLocalizedString("Memory pressure %@ · swap %@", comment: ""),
                    memoryPressureLabel, Formatters.bytes(viewModel.initialContext.swapUsedBytes)))
                    .font(Theme.Font.caption).foregroundStyle(Theme.secondaryInk)
            }.padding(12)
        }
    }
    private var memoryPressureLabel: String {
        switch viewModel.initialContext.memoryPressure {
        case .unknown: return NSLocalizedString("Unknown", comment: "")
        case .normal: return NSLocalizedString("Normal", comment: "")
        case .warning: return NSLocalizedString("Warning", comment: "")
        case .critical: return NSLocalizedString("Critical", comment: "")
        }
    }
    private var actionCard: some View {
        V2Card {
            VStack(alignment: .leading, spacing: 8) {
                switch viewModel.phase {
                case .evidence, .awaitingNormalConfirmation:
                    if viewModel.canOfferNormalQuit || viewModel.phase == .awaitingNormalConfirmation {
                        Text("Repeated contribution and current system pressure support a normal quit. LynxBar will verify this exact process instance exits.")
                        Button("Review Normal Quit…") { viewModel.requestNormalQuitConfirmation() }
                            .disabled(viewModel.phase != .evidence)
                    } else {
                        Text("Current evidence supports inspection only. A single high CPU or memory sample never becomes urgent termination guidance.")
                        if case let .ineligible(reason) = viewModel.eligibility { Text(LocalizedStringKey(reason.localizationKey)) }
                    }
                case .normalQuitFailed, .awaitingForceConfirmation:
                    Text("The application did not exit normally").font(Theme.Font.subheadline.weight(.semibold)).foregroundStyle(Theme.warning)
                    Text("Force Quit can discard unsaved data and interrupt dependent work. Eligibility is checked again before the separate request.")
                    Button("Review Force Quit…", role: .destructive) { viewModel.requestForceQuitConfirmation() }
                        .disabled(!viewModel.canOfferForceQuit)
                case .executingNormalQuit, .executingForceQuit, .verifying:
                    HStack { ProgressView(); Text("Remeasuring process and system evidence…") }
                case .result:
                    Text("Verification result").font(Theme.Font.subheadline.weight(.semibold))
                    if let result = viewModel.actionResult { Text(LocalizedStringKey(result.outcome.localizationKey)) }
                    if let report = viewModel.postActionReport {
                        Text(report.applicationExited ? "Application exit verified." : "Application exit could not be verified.")
                        Text(report.systemIssueResolved ? "The original system issue is no longer present in current evidence." : "The original system issue remains open. Inspect current CPU and memory pressure in Activity Monitor.")
                        Text(String(format: NSLocalizedString("Fresh memory %@ · swap %@ · CPU %@", comment: ""),
                            Formatters.percent(report.resources.memoryUsage), Formatters.bytes(report.resources.swapUsedBytes),
                            report.resources.cpuUsage.map(Formatters.percent) ?? "—"))
                            .font(Theme.Font.microMono).foregroundStyle(Theme.mutedInk)
                    }
                }
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(Theme.warning) }
            }.font(Theme.Font.caption).foregroundStyle(Theme.secondaryInk).padding(12)
        }
    }
    private var fallbackCard: some View {
        V2Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Inspect without changing the application").font(Theme.Font.subheadline.weight(.semibold))
                HStack {
                    Button("Copy Name") { _ = ClipboardAction.copyToPasteboard(viewModel.process.name) }
                    Button("Copy PID") { _ = ClipboardAction.copyToPasteboard(String(viewModel.process.pid)) }
                    Button("Open Activity Monitor") { ActivityMonitor.open() }
                }
            }.font(Theme.Font.caption).padding(12)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(Theme.Font.micro).foregroundStyle(Theme.mutedInk)
            Text(value).font(Theme.Font.subheadlineRounded.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var evidenceExplanation: String {
        guard let c = viewModel.process.contribution else { return NSLocalizedString("Only one observation is available. Inspection remains the safe next step.", comment: "") }
        return String(format: NSLocalizedString("Ranking observation set: %lld process(es) · repeated CPU leader %lld · repeated memory leader %lld", comment: ""),
                      c.processCount, c.repeatedLeadingCPUCount, c.repeatedLeadingMemoryCount)
    }
    private var identityExplanation: String {
        guard let p = viewModel.process.actionTarget?.process else { return NSLocalizedString("The application identity is incomplete.", comment: "") }
        return "PID \(p.pid) · start \(p.startTime.seconds).\(p.startTime.microseconds) · UID \(p.ownerUID) · parent \(p.parentPID)"
    }
    private var confirmationTitle: String {
        String(format: NSLocalizedString(viewModel.pendingConfirmation == .forceQuit ? "Force Quit %@?" : "Quit %@ normally?", comment: ""), viewModel.process.name)
    }
    private var confirmationMessage: String {
        NSLocalizedString(viewModel.pendingConfirmation == .forceQuit
            ? "Unsaved data may be lost and dependent processes may be interrupted. Eligibility is checked again immediately before the request."
            : "LynxBar will ask the application to quit normally, then wait for this exact PID and start-time identity to disappear.", comment: "")
    }
    private var confirmationBinding: Binding<Bool> {
        Binding(get: { viewModel.pendingConfirmation != nil }, set: { if !$0 && viewModel.pendingConfirmation != nil { viewModel.cancelConfirmation() } })
    }
}

private extension ProcessActionIneligibilityReason {
    var localizationKey: String {
        switch self {
        case .selfProcess: return "LynxBar cannot quit itself from remediation."
        case .rootOwned: return "Root-owned processes are inspection-only."
        case .otherUser: return "Processes owned by another user are inspection-only."
        case .commandLineOnly: return "Command-line-only processes are inspection-only."
        case .identityIncomplete: return "The application identity is incomplete."
        case .protectedSystemRole: return "Protected system interface roles are inspection-only."
        case .applicationTerminated: return "The application has already exited."
        case .applicationIdentityChanged: return "The application identity changed."
        }
    }
}
private extension ProcessActionOutcome {
    var localizationKey: String {
        switch self {
        case .exited: return "The prepared application instance exited."
        case .refused: return "The application refused the request."
        case .timedOut: return "The application remained running after the bounded wait."
        case .stale: return "The process identity changed; no action was sent."
        case .unknown: return "Process identity could not be read. Exit is unverified."
        case .ineligible: return "Fresh eligibility checks rejected the action."
        case .forceNotAuthorized: return "Force Quit was not authorized by a fresh normal-quit failure."
        }
    }
}
