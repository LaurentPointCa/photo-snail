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
                Button("About Photo Snail") {
                    showAbout()
                }
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
            string: "Local-first photo tagging tool for macOS.\nGenerates descriptions and tags for your Photos library using Apple Vision and a local LLM, fully on-device.\n\n",
            attributes: bodyAttrs
        ))

        credits.append(NSAttributedString(
            string: "GitHub",
            attributes: [
                .font: linkFont,
                .link: URL(string: "https://github.com/LaurentPointCa/photo-snail")!,
            ]
        ))

        credits.append(NSAttributedString(string: "\n", attributes: bodyAttrs))

        credits.append(NSAttributedString(
            string: "MIT License",
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
