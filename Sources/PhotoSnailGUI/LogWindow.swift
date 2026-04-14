import SwiftUI

struct LogWindow: View {
    private let store = LogStore.shared
    private let loc = Localizer.shared

    @State private var pinToBottom: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            logList

            Divider()
            HStack {
                Toggle(isOn: Bindable(store).detailed) {
                    Text(loc.t("log.detailed"))
                        .font(AppFont.label)
                }
                .toggleStyle(.switch)
                .controlSize(.regular)
                .help(loc.t("log.detailed_help"))

                Spacer()

                Button {
                    store.clear()
                } label: {
                    Label(loc.t("button.clear"), systemImage: "trash")
                        .font(AppFont.label)
                }
                .buttonStyle(.borderless)
                .help(loc.t("log.clear_help"))
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
        }
        .frame(minWidth: 500, minHeight: 300)
        .background(AppColor.surfaceSunken)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.filteredEntries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, Spacing.sm)
            }
            .onChange(of: store.entries.last?.id) { _, newId in
                guard pinToBottom, let id = newId else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

}

// MARK: - Log row

private struct LogRow: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(AppFont.monoCaption)
                .foregroundStyle(AppColor.textTertiary)
                .frame(width: 62, alignment: .trailing)

            Text(entry.level.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(levelColor)
                .frame(width: 14, alignment: .center)

            Text(entry.message)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 3)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:    return AppColor.textSecondary
        case .success: return AppColor.statusDone
        case .warning: return AppColor.statusPending
        case .error:   return AppColor.statusFailed
        }
    }
}
