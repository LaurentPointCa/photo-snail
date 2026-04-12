import SwiftUI
import AppKit

// MARK: - Spacing scale

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner radii

enum Radius {
    static let chip: CGFloat = 8
    static let thumbnail: CGFloat = 10
    static let card: CGFloat = 14
    static let hero: CGFloat = 14
}

// MARK: - Typography ramp

/// Centralized type scale. Replaces ad-hoc `.font(.caption)` calls scattered
/// throughout the GUI. Sizes were picked to give a real hierarchy on a Retina
/// display: 11 → 12 → 13 → 14 → 16 → 22, with weight + tracking carrying the
/// secondary distinction.
enum AppFont {
    /// 11pt semibold — uppercase tracked section eyebrows ("LAST COMPLETED").
    /// Always paired with `.tracking(0.5)` and `.uppercased()` at the call site,
    /// or use the `EyebrowLabel` component which bundles all three.
    static let eyebrow: Font        = .system(size: 11, weight: .semibold)

    /// 12pt regular — least-important secondary metadata.
    static let caption: Font        = .system(size: 12, weight: .regular)

    /// 13pt medium — form labels, identity row keys, sidebar rows.
    static let label: Font          = .system(size: 13, weight: .medium)

    /// 14pt regular — default body for values and descriptions.
    static let body: Font           = .system(size: 14, weight: .regular)

    /// 14pt semibold — emphasized body, button labels, selection counts.
    static let bodyEmphasized: Font = .system(size: 14, weight: .semibold)

    /// 16pt semibold — section headers in the inspector and settings sheet.
    static let sectionTitle: Font   = .system(size: 16, weight: .semibold)

    /// 22pt semibold — focal numbers (multi-selection count, runner stats).
    static let display: Font        = .system(size: 22, weight: .semibold)

    /// Monospaced 12pt — IDs, sentinels, models, hashes.
    static let monoCaption: Font    = .system(size: 12, weight: .regular, design: .monospaced)

    /// Monospaced 13pt — keyboard shortcut keys, code blocks.
    static let monoLabel: Font      = .system(size: 13, weight: .regular, design: .monospaced)
}

// MARK: - Color tokens

/// Semantic colors. All colors below adapt to dark/light mode via dynamic
/// `NSColor`, so the same token works regardless of system appearance.
enum AppColor {

    /// Slightly lighter than the window background — used for raised cards
    /// (inspector sections, runner dock, settings groups). In dark mode this
    /// produces the "elevated panel" look that gives sections visual weight
    /// without needing dividers.
    static let surfaceElevated = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            return NSColor(white: 0.18, alpha: 1.0)
        } else {
            return NSColor(white: 0.97, alpha: 1.0)
        }
    })

    /// Sunken, darker than the window — image placeholders, code blocks, OCR
    /// payloads. Visually reads as "this is a container, not content".
    static let surfaceSunken = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            return NSColor(white: 0.08, alpha: 1.0)
        } else {
            return NSColor(white: 0.93, alpha: 1.0)
        }
    })

    /// Even more elevated than `surfaceElevated` — for the runner dock card,
    /// which needs to read as a distinct affordance pinned to the bottom of
    /// the sidebar.
    static let surfaceHighlighted = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            return NSColor(white: 0.22, alpha: 1.0)
        } else {
            return NSColor(white: 0.99, alpha: 1.0)
        }
    })

    /// Subtle hairline border for card edges. Stays under 10% alpha so it
    /// reads as "edge" not "frame".
    static let borderSubtle = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            return NSColor(white: 1.0, alpha: 0.10)
        } else {
            return NSColor(white: 0.0, alpha: 0.10)
        }
    })

    /// Text colors — primary/secondary defer to system, tertiary fills the
    /// gap below `.secondary` for "barely there" hints.
    static let textPrimary   = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary  = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            return NSColor(white: 1.0, alpha: 0.45)
        } else {
            return NSColor(white: 0.0, alpha: 0.45)
        }
    })

    // Status colors — designed to read clearly in dark mode without being
    // garish. Used by status badges, inspector section icons, runner dock,
    // and the sidebar filter row dots.
    static let statusDone      = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let statusPending   = Color(red: 1.00, green: 0.78, blue: 0.30)
    static let statusFailed    = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let statusUntouched = Color(white: 0.55)

    /// Tag chip background palette. Eight muted hues spaced around the wheel,
    /// indexed by `tagTint(for:)` so a given tag always gets the same color.
    /// Saturation/brightness chosen to be visible in dark mode without
    /// fighting for attention with the photo grid.
    private static let tagPalette: [Color] = [
        Color(hue: 0.62, saturation: 0.45, brightness: 0.58), // indigo
        Color(hue: 0.50, saturation: 0.48, brightness: 0.55), // teal
        Color(hue: 0.35, saturation: 0.42, brightness: 0.52), // sage
        Color(hue: 0.18, saturation: 0.50, brightness: 0.55), // olive
        Color(hue: 0.08, saturation: 0.55, brightness: 0.60), // amber
        Color(hue: 0.00, saturation: 0.48, brightness: 0.58), // coral
        Color(hue: 0.92, saturation: 0.42, brightness: 0.58), // pink
        Color(hue: 0.78, saturation: 0.40, brightness: 0.56), // lavender
    ]

    /// Deterministic hash of a tag string → palette index. Uses djb2 since
    /// `String.hashValue` is randomized per app launch (a tag would change
    /// color every relaunch otherwise).
    static func tagTint(for tag: String) -> Color {
        var h: UInt64 = 5381
        for ch in tag.unicodeScalars {
            h = h &* 33 &+ UInt64(ch.value)
        }
        return tagPalette[Int(h % UInt64(tagPalette.count))]
    }
}

// MARK: - View modifiers

extension View {
    /// Wrap content in an elevated card: rounded background fill, hairline
    /// border, internal padding. Use for inspector sections, settings groups,
    /// and other "this is a discrete piece of information" containers.
    func surfaceCard(
        padding: CGFloat = Spacing.lg,
        radius: CGFloat = Radius.card,
        background: Color = AppColor.surfaceElevated
    ) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
            )
    }
}

// MARK: - Reusable text components

/// Small uppercase tracked label for section eyebrows ("LAST COMPLETED",
/// "PROCESSING"). Bundles font + tracking + uppercase + secondary color so
/// the call site is just `EyebrowLabel("Last Completed")`.
struct EyebrowLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(AppFont.eyebrow)
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
