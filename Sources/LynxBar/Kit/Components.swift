import SwiftUI

/// 标签 + 值的等宽行。
struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(LocalizedStringKey(label)).foregroundStyle(Theme.secondaryInk)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
        }
        .font(Theme.Font.body)
    }
}

/// 各逻辑核心使用率网格。
struct PerCoreGrid: View {
    let usages: [Double]
    private let columns = [GridItem(.adaptive(minimum: 60), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(usages.enumerated()), id: \.offset) { index, usage in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Core \(index)")
                        .font(Theme.Font.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                    ProgressView(value: usage).tint(Theme.cpu)
                }
            }
        }
    }
}

/// 详情页统一使用的标题行，保持标题、实时值和辅助动作的基线稳定。
struct WorkspaceHeader<Trailing: View>: View {
    let title: String
    var value: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        value: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.value = value
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(Theme.Font.title2.weight(.semibold))
                .foregroundStyle(Theme.ink)

            if let value {
                Text(value)
                    .font(Theme.Font.statValue.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension WorkspaceHeader where Trailing == EmptyView {
    init(_ title: String, value: String? = nil) {
        self.init(title, value: value) { EmptyView() }
    }
}

/// Quiet Ledger 中的轻量区块标题；不使用额外卡片背景，保持单一表面。
struct QuietSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title))
                .font(Theme.Font.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(Theme.Font.subheadline)
                    .foregroundStyle(Theme.mutedInk)
                    .monospacedDigit()
            }
        }
    }
}
