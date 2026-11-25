import SwiftUI

struct DiskCleanupView: View {
    @ObservedObject var viewModel: DiskCleanupViewModel
    @State private var candidateFilter: CandidateFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            content
            Divider().overlay(Theme.divider)
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 500, idealHeight: 560)
        .background(Theme.surface)
        .foregroundStyle(Theme.ink)
        .confirmationDialog(
            "Move selected files to Trash?",
            isPresented: Binding(
                get: { viewModel.isConfirmationPresented },
                set: { presented in
                    if !presented {
                        viewModel.cancelConfirmation()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                viewModel.confirmAndExecute()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelConfirmation()
            }
        } message: {
            Text(String(
                format: NSLocalizedString(
                    "%lld files · %@. Files remain recoverable in Trash and space is not freed until Trash is emptied.",
                    comment: ""
                ),
                viewModel.selectedCandidates.count,
                Formatters.bytes(viewModel.selectedEstimatedBytes)
            ))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if viewModel.canReturnToStart {
                Button {
                    viewModel.startOver()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(NSLocalizedString(
                    "Back to folder selection",
                    comment: ""
                ))
            }
            Image(systemName: "trash.slash")
                .font(Theme.Font.title.weight(.semibold))
                .foregroundStyle(Theme.disk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Free Up Space Safely")
                    .font(Theme.Font.title2.weight(.bold))
                Text("Review ordinary files before moving anything to Trash.")
                    .font(Theme.Font.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Cleanup operation in progress")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            startContent
        case .scanning:
            scanningContent
        case .review, .awaitingConfirmation:
            reviewContent
        case .executing:
            executingContent
        case .result:
            resultContent
        case .cancelled:
            messageContent(
                systemName: "xmark.circle",
                title: NSLocalizedString("Operation cancelled", comment: ""),
                detail: cancellationDetail
            )
        case .failed:
            messageContent(
                systemName: "exclamationmark.triangle.fill",
                title: NSLocalizedString(
                    "Cleanup could not continue",
                    comment: ""
                ),
                detail: viewModel.errorMessage
                    ?? NSLocalizedString(
                        "Refresh the scan and try again.",
                        comment: ""
                    )
            )
        }
    }

    private var startContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.questionmark")
                .font(Theme.Font.largeTitle.weight(.light))
                .foregroundStyle(Theme.disk)
            VStack(spacing: 6) {
                Text("Choose a narrow folder")
                    .font(Theme.Font.title3.weight(.semibold))
                Text(
                    "LynxBar skips hidden items, apps, packages, symbolic links, cloud placeholders, shared hard links, and application-owned Library data."
                )
                .font(Theme.Font.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            }
            HStack(spacing: 10) {
                Button("Scan Downloads") {
                    viewModel.scanDownloads()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.disk)
                Button("Choose Folder…") {
                    viewModel.chooseFolderAndScan()
                }
                .buttonStyle(.bordered)
            }
            VStack(spacing: 4) {
                Text(
                    "You can also review Apple storage recommendations in System Settings → General → Storage."
                )
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.mutedInk)
                Button("Open System Settings") {
                    viewModel.openSystemSettings()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var scanningContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning selected folder…")
                .font(Theme.Font.title3.weight(.semibold))
            if let rootURL = viewModel.rootURL {
                Text(rootURL.path)
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityLabel(String(
                        format: NSLocalizedString(
                            "Scanning folder %@",
                            comment: ""
                        ),
                        rootURL.path
                    ))
            }
            HStack(spacing: 18) {
                scanMetric(
                    value: "\(viewModel.progress.observedEntries)",
                    label: "Observed"
                )
                scanMetric(
                    value: "\(viewModel.progress.candidateCount)",
                    label: "Candidates"
                )
                scanMetric(
                    value: Formatters.bytes(
                        viewModel.progress.estimatedCandidateBytes
                    ),
                    label: "Estimated"
                )
            }
            Button("Cancel Scan") {
                viewModel.cancelActiveWork()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var reviewContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reviewTitle)
                        .font(Theme.Font.body.weight(.semibold))
                    Text(reviewSubtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryInk)
                    if !exclusionSummary.isEmpty {
                        Text(String(
                            format: NSLocalizedString(
                                "Excluded: %@",
                                comment: ""
                            ),
                            exclusionSummary
                        ))
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.mutedInk)
                        .lineLimit(1)
                        .help(exclusionSummary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(String(
                        format: NSLocalizedString(
                            "%lld selected · %@",
                            comment: ""
                        ),
                        viewModel.selectedCandidateIDs.count,
                        Formatters.bytes(viewModel.selectedEstimatedBytes)
                    ))
                    .font(Theme.Font.captionMono.weight(.semibold))
                    .foregroundStyle(Theme.disk)
                    Picker(
                        NSLocalizedString("Candidate filter", comment: ""),
                        selection: $candidateFilter
                    ) {
                        ForEach(CandidateFilter.allCases) { filter in
                            Text(LocalizedStringKey(filter.localizationKey))
                                .tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 68)

            Divider().overlay(Theme.divider)
            if viewModel.candidates.isEmpty {
                messageContent(
                    systemName: "checkmark.circle.fill",
                    title: NSLocalizedString("No matching files", comment: ""),
                    detail: NSLocalizedString(
                        "Nothing was selected automatically. Choose another folder or adjust the scan scope.",
                        comment: ""
                    )
                )
            } else if filteredCandidates.isEmpty {
                messageContent(
                    systemName: "line.3.horizontal.decrease.circle",
                    title: NSLocalizedString(
                        "No files match this filter",
                        comment: ""
                    ),
                    detail: NSLocalizedString(
                        "Choose another candidate filter to continue reviewing.",
                        comment: ""
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredCandidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var executingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Moving selected files to Trash…")
                .font(Theme.Font.title3.weight(.semibold))
            Text("Each file is revalidated immediately before the system Trash operation.")
                .font(Theme.Font.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
            Button("Stop After Current File") {
                viewModel.cancelActiveWork()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var resultContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(resultTitle)
                        .font(Theme.Font.body.weight(.semibold))
                    Text(
                        "Items in Trash still occupy disk space until you empty Trash in Finder."
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                }
                Spacer()
                Text(
                    Formatters.bytes(viewModel.batchResult?.stagedBytes ?? 0)
                )
                .font(Theme.Font.title3Rounded.weight(.bold))
                .foregroundStyle(Theme.disk)
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
            Divider().overlay(Theme.divider)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(viewModel.batchResult?.items ?? []) { item in
                        resultRow(item)
                    }
                }
                .padding(10)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(footerStatus)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
            Spacer()
            switch viewModel.phase {
            case .review:
                Button("Move Selected to Trash") {
                    viewModel.prepareConfirmation()
                }
                .disabled(viewModel.selectedCandidateIDs.isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(Theme.warning)
            case .result:
                Button("Reveal in Finder") {
                    viewModel.revealFirstStagedItem()
                }
                .disabled(
                    viewModel.batchResult?.items.contains {
                        $0.status == .staged
                    } != true
                )
                Button("Recheck Capacity") {
                    viewModel.recheckCapacity()
                }
                Button("New Scan") {
                    viewModel.startOver()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.disk)
            case .cancelled, .failed:
                Button("Start Over") {
                    viewModel.startOver()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.disk)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private func candidateRow(
        _ candidate: DiskCleanupCandidate
    ) -> some View {
        let selected = viewModel.selectedCandidateIDs.contains(candidate.id)
        return HStack(spacing: 8) {
            Button {
                viewModel.toggleSelection(candidate.id)
            } label: {
                HStack(spacing: 10) {
                    Image(
                        systemName: selected
                            ? "checkmark.square.fill"
                            : "square"
                    )
                    .foregroundStyle(
                        selected ? Theme.disk : Theme.secondaryInk
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.sourceURL.lastPathComponent)
                            .font(Theme.Font.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(
                            candidate.sourceURL
                                .deletingLastPathComponent()
                                .path
                        )
                        .font(Theme.Font.microMono)
                        .foregroundStyle(Theme.mutedInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(
                            format: NSLocalizedString(
                                "Est. %@",
                                comment: ""
                            ),
                            Formatters.bytes(
                                candidate.allocatedBytesEstimate
                            )
                        ))
                        // 语义字阶里没有现成的 subheadline + monospaced 组合，
                        // 这里按原始 11pt semibold 等宽的角色现场拼一个。
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Text(candidateRuleLabel(candidate.rule))
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(candidate.sourceURL.lastPathComponent)
            .accessibilityValue(String(
                format: NSLocalizedString("%@, %@", comment: ""),
                Formatters.bytes(candidate.allocatedBytesEstimate),
                NSLocalizedString(
                    selected ? "selected" : "not selected",
                    comment: ""
                )
            ))

            Button {
                viewModel.revealCandidate(candidate.id)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help(NSLocalizedString("Show in Finder", comment: ""))
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(selected ? Theme.selectionSoft : Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func resultRow(_ item: DiskCleanupItemResult) -> some View {
        HStack(spacing: 9) {
            Image(systemName: resultIcon(item.status))
                .foregroundStyle(resultColor(item.status))
            Text(item.displayName)
                .font(Theme.Font.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Text(resultLabel(item))
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(resultColor(item.status))
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func messageContent(
        systemName: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemName)
                .font(Theme.Font.largeTitle.weight(.light))
                .foregroundStyle(Theme.disk)
            Text(title)
                .font(Theme.Font.title3.weight(.semibold))
            Text(detail)
                .font(Theme.Font.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func scanMetric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(Theme.Font.bodyRounded.weight(.semibold))
                .monospacedDigit()
            Text(LocalizedStringKey(label))
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.secondaryInk)
        }
        .frame(minWidth: 92)
    }

    private var reviewTitle: String {
        switch viewModel.scanResult?.status {
        case .partialDeadline:
            return NSLocalizedString(
                "Partial scan · time limit reached",
                comment: ""
            )
        case .partialEntryLimit:
            return NSLocalizedString(
                "Partial scan · entry limit reached",
                comment: ""
            )
        default:
            return NSLocalizedString("Review exact files", comment: "")
        }
    }

    private var cancellationDetail: String {
        switch viewModel.cancellationContext {
        case .scan(let observedEntries):
            return String(
                format: NSLocalizedString(
                    "Stopped after observing %lld entries. No file action was started.",
                    comment: ""
                ),
                observedEntries
            )
        case .execution:
            return NSLocalizedString(
                "Stopping after the current file. Results already returned by the system will be preserved.",
                comment: ""
            )
        case .none:
            return NSLocalizedString(
                "No additional files will be processed.",
                comment: ""
            )
        }
    }

    private var filteredCandidates: [DiskCleanupCandidate] {
        switch candidateFilter {
        case .all:
            return viewModel.candidates
        case .large:
            return viewModel.candidates.filter { $0.rule == .large }
        case .oldAndLarge:
            return viewModel.candidates.filter { $0.rule == .oldAndLarge }
        }
    }

    private var exclusionSummary: String {
        guard let counts = viewModel.scanResult?.exclusionCounts else {
            return ""
        }
        return DiskExclusionReason.allCases.compactMap { reason in
            guard let count = counts[reason], count > 0 else { return nil }
            return String(
                format: NSLocalizedString("%@ %lld", comment: ""),
                exclusionLabel(reason),
                count
            )
        }
        .joined(separator: " · ")
    }

    private var reviewSubtitle: String {
        String(
            format: NSLocalizedString(
                "%lld observed · %lld excluded · no files preselected",
                comment: ""
            ),
            viewModel.progress.observedEntries,
            viewModel.progress.excludedEntries
        )
    }

    private var resultTitle: String {
        let staged = viewModel.batchResult?.items.filter {
            $0.status == .staged
        }.count ?? 0
        return String(
            format: NSLocalizedString(
                "%lld files moved to Trash",
                comment: ""
            ),
            staged
        )
    }

    private var footerStatus: String {
        if let verification = viewModel.capacityVerification,
           let delta = verification.observedDelta {
            return String(
                format: NSLocalizedString(
                    "Observed available-capacity change: %@ · not solely attributed to this action",
                    comment: ""
                ),
                Formatters.bytes(UInt64(abs(delta)))
            )
        }
        if let rootURL = viewModel.rootURL {
            return rootURL.path
        }
        return NSLocalizedString(
            "No background cleanup · Trash only",
            comment: ""
        )
    }

    private func resultIcon(_ status: DiskCleanupItemStatus) -> String {
        switch status {
        case .staged: return "trash.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .cancelled: return "minus.circle.fill"
        }
    }

    private func resultColor(_ status: DiskCleanupItemStatus) -> Color {
        switch status {
        case .staged: return Theme.health
        case .failed: return Theme.critical
        case .stale, .cancelled: return Theme.warning
        }
    }

    private func resultLabel(_ item: DiskCleanupItemResult) -> String {
        switch item.status {
        case .staged:
            return String(
                format: NSLocalizedString("In Trash · %@", comment: ""),
                Formatters.bytes(item.stagedBytes)
            )
        case .failed:
            return resultErrorLabel(item.errorCategory)
        case .stale:
            return NSLocalizedString("Changed · skipped", comment: "")
        case .cancelled:
            return NSLocalizedString("Not processed", comment: "")
        }
    }

    private func candidateRuleLabel(_ rule: DiskCleanupRule) -> String {
        switch rule {
        case .large:
            return NSLocalizedString("Large file", comment: "")
        case .oldAndLarge:
            return NSLocalizedString("Old large file", comment: "")
        }
    }

    private func exclusionLabel(_ reason: DiskExclusionReason) -> String {
        switch reason {
        case .directory:
            return NSLocalizedString("folders", comment: "")
        case .symbolicLink:
            return NSLocalizedString("symbolic links", comment: "")
        case .package:
            return NSLocalizedString("packages", comment: "")
        case .application:
            return NSLocalizedString("applications", comment: "")
        case .hidden:
            return NSLocalizedString("hidden", comment: "")
        case .cloudPlaceholder:
            return NSLocalizedString("cloud placeholders", comment: "")
        case .inaccessible:
            return NSLocalizedString("inaccessible", comment: "")
        case .hardLinked:
            return NSLocalizedString("shared hard links", comment: "")
        case .nonLocal:
            return NSLocalizedString("non-local", comment: "")
        case .notRegular:
            return NSLocalizedString("other file types", comment: "")
        case .outsideRoot:
            return NSLocalizedString("outside root", comment: "")
        case .belowThreshold:
            return NSLocalizedString("below threshold", comment: "")
        case .metadataUnavailable:
            return NSLocalizedString("metadata unavailable", comment: "")
        }
    }

    private func resultErrorLabel(
        _ category: DiskActionErrorCategory?
    ) -> String {
        switch category {
        case .notFound:
            return NSLocalizedString("Not found", comment: "")
        case .permissionDenied:
            return NSLocalizedString("Permission denied", comment: "")
        case .readOnlyVolume:
            return NSLocalizedString("Read-only volume", comment: "")
        case .busy:
            return NSLocalizedString("File is busy", comment: "")
        case .unavailable:
            return NSLocalizedString("Unavailable", comment: "")
        case .unknown, .none:
            return NSLocalizedString("Failed", comment: "")
        }
    }
}

private enum CandidateFilter: String, CaseIterable, Identifiable {
    case all
    case large
    case oldAndLarge

    var id: Self { self }

    var localizationKey: String {
        switch self {
        case .all: return "All"
        case .large: return "Large"
        case .oldAndLarge: return "Old"
        }
    }
}
