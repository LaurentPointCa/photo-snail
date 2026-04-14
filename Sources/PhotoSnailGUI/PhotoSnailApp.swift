import SwiftUI
import AppKit

@main
struct PhotoSnailApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryWindow()
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(Localizer.shared.t("button.about")) {
                    showAbout()
                }
            }
            CommandGroup(after: .appSettings) {
                Button(Localizer.shared.t("toolbar.settings") + "...") {
                    AppCommands.shared.pendingSettingsOpen = true
                }
                .keyboardShortcut(",", modifiers: .command)

                Menu("Language") {
                    ForEach(Localizer.Language.allCases) { lang in
                        Button {
                            Localizer.shared.pendingLanguageChange = lang
                        } label: {
                            HStack {
                                Text(lang.nativeName)
                                if Localizer.shared.language == lang {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            CommandGroup(after: .windowArrangement) {
                OpenLogsMenuButton()
            }
        }

        Window("Logs", id: "log-window") {
            LogWindow()
        }
        .defaultSize(width: 700, height: 500)
    }

    private func showAbout() {
        let credits = NSMutableAttributedString()

        let bodyFont = NSFont.systemFont(ofSize: 12)
        let linkFont = NSFont.systemFont(ofSize: 12)
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        credits.append(NSAttributedString(
            string: Localizer.shared.t("about.description") + "\n\n",
            attributes: bodyAttrs
        ))

        credits.append(NSAttributedString(
            string: Localizer.shared.t("about.author") + "\n\n",
            attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        ))

        credits.append(NSAttributedString(
            string: Localizer.shared.t("about.github"),
            attributes: [
                .font: linkFont,
                .link: URL(string: "https://github.com/LaurentPointCa/photo-snail")!,
            ]
        ))

        credits.append(NSAttributedString(
            string: " · \(Localizer.shared.t("about.license"))",
            attributes: bodyAttrs
        ))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: credits.length))

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }
}

/// Menu command that opens the Logs window. Wrapped as a View so it can use
/// `@Environment(\.openWindow)` — Environment values aren't accessible from a
/// CommandGroup's closure directly.
private struct OpenLogsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(Localizer.shared.t("toolbar.logs")) {
            openWindow(id: "log-window")
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}
