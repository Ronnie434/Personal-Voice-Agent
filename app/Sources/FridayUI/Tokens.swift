import AppKit
import SwiftUI

// Design tokens from docs/DESKTOP_APP_PLAN.md section 3.3. Views use these and
// nothing else for colour, type, radius and spacing.

private func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
    func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light)
    })
}

public extension Color {
    /// Primary text and the primary pill's fill.
    static let ink = dynamic(0x111827, 0xF3F4F6)
    /// Text on the primary pill.
    static let onInk = dynamic(0xFFFFFF, 0x0C0E12)
    static let ink2 = dynamic(0x1F2937, 0xD1D5DB)
    static let muted = dynamic(0x6B7280, 0x9CA3AF)
    /// Hairlines, input borders, chips.
    static let line = dynamic(0xE5E7EB, 0x1F2937)
    static let chip = dynamic(0xF3F4F6, 0x1F2937)
    static let surface = dynamic(0xFFFFFF, 0x0C0E12)
    static let fridayAccent = dynamic(0x007AFF, 0x0A84FF)
    static let alert = dynamic(0xFB4268, 0xFF5A7A)
    static let warn = Color(nsColor: .systemOrange)
    /// The HUD is dark in both appearances.
    static let hud = Color(red: 0x0C / 255, green: 0x0E / 255, blue: 0x12 / 255)
}

public enum Space {
    public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
    public static let xl: CGFloat = 24, xxl: CGFloat = 32
}

public enum Radius {
    public static let chip: CGFloat = 8, input: CGFloat = 10, panel: CGFloat = 16
}

public enum Motion {
    /// Calm and exact: no bounce.
    public static let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)
    public static let quick = Animation.easeOut(duration: 0.18)
}

public enum FridayFont {
    /// DM Mono ships inside the app (SIL OFL). Call once at launch.
    public static func register() {
        for name in ["DMMono-Regular", "DMMono-Medium"] {
            // In Friday.app the fonts are in Contents/Resources; under `swift run`
            // they are in the package's own resource bundle.
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Resources")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }

    public static let setupTitle = Font.system(size: 28, weight: .semibold)
    public static let heading = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let button = Font.system(size: 13, weight: .medium)
    public static func mono(_ size: CGFloat = 11, medium: Bool = false) -> Font {
        .custom(medium ? "DMMono-Medium" : "DMMono-Regular", fixedSize: size)
    }
}

public extension View {
    /// Small mono label: status, shortcuts, captions.
    func monoLabel(_ size: CGFloat = 11, medium: Bool = false) -> some View {
        font(FridayFont.mono(size, medium: medium)).tracking(size * 0.02)
    }

    /// Uppercase mono eyebrow above a title.
    func eyebrow() -> some View {
        font(FridayFont.mono(11, medium: true)).tracking(0.9).textCase(.uppercase)
            .foregroundStyle(Color.muted)
    }
}

/// Black pill (primary) or outlined pill (secondary).
public struct PillButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary }
    var kind: Kind
    var height: CGFloat
    @Environment(\.isEnabled) private var enabled

    public init(_ kind: Kind = .primary, height: CGFloat = 32) {
        self.kind = kind
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FridayFont.button)
            .foregroundStyle(kind == .primary ? Color.onInk : Color.ink)
            .padding(.horizontal, height / 2)
            .frame(height: height)
            .background {
                if kind == .primary {
                    Capsule().fill(Color.ink)
                } else {
                    Capsule().fill(Color.surface.opacity(0.6))
                    Capsule().strokeBorder(Color.line, lineWidth: 1)
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .contentShape(Capsule())
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// Round icon button used in the popover header.
public struct IconButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.ink2)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.chip.opacity(configuration.isPressed ? 1 : 0.7)))
            .contentShape(Circle())
    }
}

/// A glass panel: Liquid Glass on macOS 26+, a material before that, and a
/// solid fill when the user has Reduce Transparency on.
public struct GlassPanel<S: InsettableShape>: ViewModifier {
    var shape: S
    var dark: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.solidGlass) private var solidGlass

    public func body(content: Content) -> some View {
        if reduceTransparency || solidGlass {
            content.background(shape.fill(dark ? Color.hud.opacity(0.94) : Color.surface))
                .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.10) : Color.line, lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(dark ? .regular.tint(Color.hud.opacity(0.52)) : .regular, in: shape)
        } else {
            content
                .background(shape.fill(dark ? AnyShapeStyle(Color.hud.opacity(0.52)) : AnyShapeStyle(.clear)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.75), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                .shadow(color: .black.opacity(0.08), radius: 24, y: 8)
        }
    }
}

public extension View {
    func glass<S: InsettableShape>(_ shape: S, dark: Bool = false) -> some View {
        modifier(GlassPanel(shape: shape, dark: dark))
    }
}

private struct SolidGlassKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    /// Screenshots are drawn off screen, where materials have nothing behind them.
    var solidGlass: Bool {
        get { self[SolidGlassKey.self] }
        set { self[SolidGlassKey.self] = newValue }
    }
}
