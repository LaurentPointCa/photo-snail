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
                Button(Localizer.shared.t("update.check_menu")) {
                    Task { await UpdateChecker.shared.checkNow() }
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

        // Build stamp on its own line. Reading `PhotoSnailBuildDate` from
        // Info.plist (written by bundle-gui.sh) — the raw compact
        // `CFBundleVersion` form that macOS renders in parentheses after
        // the version line is hard to parse visually; the human-readable
        // "YYYY-MM-DD HH:MM:SS" form here is what the developer is
        // actually looking for when comparing which build is installed.
        if let buildDate = Bundle.main.object(forInfoDictionaryKey: "PhotoSnailBuildDate") as? String,
           !buildDate.isEmpty {
            let stampFont = NSFont.systemFont(ofSize: 10)
            credits.append(NSAttributedString(
                string: "\n\(Localizer.shared.t("about.build_prefix")) \(buildDate)",
                attributes: [.font: stampFont, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: credits.length))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: credits,
        ]
        if let displayVersion = prominentVersionString() {
            // Overrides CFBundleShortVersionString (still "1.0" in the
            // bundle). Clean tags drop the leading "v" so macOS doesn't
            // render "Version v0.1.5"; dev builds keep the full
            // `git describe` string so the developer sees what they're
            // actually running (e.g. "v0.1.5-3-gabc1234-dirty").
            options[.applicationVersion] = displayVersion
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)

        // The standard About panel auto-sizes to content, but some localized
        // descriptions wrap into a cramped box. Nudge the frame larger after
        // it's on screen so the text has breathing room.
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: {
                NSStringFromClass(type(of: $0)).contains("AboutPanel")
            }) else { return }
            var f = win.frame
            let dw: CGFloat = 120
            let dh: CGFloat = 30
            f.origin.x -= dw / 2
            f.origin.y -= dh / 2
            f.size.width += dw
            f.size.height += dh
            win.setFrame(f, display: true)
        }
    }

    /// Compute the string shown in the About panel's "Version" slot.
    /// - Clean release tag (`v0.1.5`) → `"0.1.5"` (leading `v` stripped so
    ///   macOS doesn't render "Version v0.1.5").
    /// - Dev build (`v0.1.5-3-gabc1234`, `v0.1.5-dirty`) → full string,
    ///   so the developer sees they're running past-the-tag code.
    /// - Missing / "unknown" → nil, letting the system fall back to
    ///   CFBundleShortVersionString.
    private func prominentVersionString() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PhotoSnailGitVersion") as? String,
              !raw.isEmpty, raw != "unknown" else { return nil }
        if raw.range(of: #"^v?\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            return raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        }
        return raw
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
