import AppKit
import SwiftUI

/// Friday's mark: five voice bars, one colour, no gloss. Hearing: the bars
/// follow the microphone. Thinking: a slow wave passes along them. Speaking:
/// they follow Friday's voice. With Reduce Motion the bars keep their shape and
/// only their opacity changes.
public struct Orb: View {
    var state: FridayState
    var level: Double
    var size: CGFloat
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Resting shape, as a share of the full height: a small arch.
    private static let rest: [Double] = [0.30, 0.55, 0.80, 0.55, 0.30]
    /// How strongly each bar follows the sound, so they don't move as one block.
    private static let reach: [Double] = [0.55, 0.85, 1.0, 0.8, 0.5]

    public init(state: FridayState, level: Double = 0, size: CGFloat = 20, color: Color = .white) {
        self.state = state
        self.level = level
        self.size = size
        self.color = color
    }

    public var body: some View {
        let moving = state == .thinking || state == .speaking || state == .hearing
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let width = size * 0.13
            HStack(alignment: .center, spacing: size * 0.085) {
                ForEach(0..<5, id: \.self) { bar in
                    Capsule()
                        .fill(color)
                        .frame(width: width, height: max(width, size * height(of: bar, at: t)))
                        .opacity(opacity(of: bar, at: t))
                }
            }
            .frame(width: size, height: size)
            .animation(Motion.quick, value: level)
        }
        .accessibilityHidden(true)
    }

    private func height(of bar: Int, at t: TimeInterval) -> Double {
        guard !reduceMotion else { return Self.rest[bar] }
        switch state {
        case .hearing, .speaking:
            // A little life of its own on top of the real level, so a steady
            // sound doesn't freeze the bars.
            let flutter = 0.12 * sin(t * (state == .speaking ? 11 : 8) + Double(bar) * 1.7)
            return min(1, max(0.16, 0.2 + (level + flutter * level) * Self.reach[bar] * 0.9))
        case .thinking:
            // One wave along the bars every 1.6 s.
            let phase = (t / 1.6).truncatingRemainder(dividingBy: 1) * 2 * .pi
            return 0.28 + 0.3 * (0.5 + 0.5 * sin(phase - Double(bar) * 0.9))
        case .paused, .error:
            return 0.16
        default:
            return Self.rest[bar]
        }
    }

    private func opacity(of bar: Int, at t: TimeInterval) -> Double {
        switch state {
        case .paused, .error: return 0.45
        case .thinking where reduceMotion:
            return 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 3 - Double(bar)))
        case .hearing where reduceMotion, .speaking where reduceMotion:
            return 0.5 + 0.5 * min(1, level * 1.4)
        default: return 1
        }
    }
}

/// The menu bar glyph: the same bars, three of them, changed by state rather
/// than colour.
public struct MenuBarGlyph: View {
    var state: FridayState
    var warning: FridayWarning?

    public init(state: FridayState, warning: FridayWarning? = nil) {
        self.state = state
        self.warning = warning
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let ink = GraphicsContext.Shading.color(.primary)
            let midX = canvasSize.width / 2, midY = canvasSize.height / 2
            func bars(_ heights: [CGFloat], width: CGFloat = 2.2, gap: CGFloat = 2.0) {
                let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
                for (index, height) in heights.enumerated() {
                    let x = midX - total / 2 + CGFloat(index) * (width + gap)
                    let rect = CGRect(x: x, y: midY - height / 2, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: ink)
                }
            }
            switch state {
            case .hearing:
                bars([7, 12, 9, 13, 6])
            case .speaking:
                bars([10, 6, 13, 6, 10])
            case .thinking:
                bars([2.2, 2.2, 2.2], gap: 2.6)
            case .paused, .error:
                bars([2.2, 2.2, 2.2, 2.2, 2.2])
                var slash = Path()
                slash.move(to: CGPoint(x: midX - 5.5, y: midY + 5.5))
                slash.addLine(to: CGPoint(x: midX + 5.5, y: midY - 5.5))
                context.stroke(slash, with: ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            default:
                bars([4, 8, 12, 8, 4])
            }
        }
        .frame(width: 22, height: 18)
        .overlay(alignment: .topTrailing) {
            if let warning {
                Circle().fill(warning.isError ? Color.alert : Color.warn).frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Friday, \(state.label)")
    }
}

public extension MenuBarGlyph {
    /// The glyph as a template image. The menu bar only draws images and text
    /// in a MenuBarExtra label, so the SwiftUI drawing above can't be used there.
    @MainActor
    static func image(state: FridayState, warning: FridayWarning? = nil) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let midX = rect.midX, midY = rect.midY
            func bars(_ heights: [CGFloat], width: CGFloat = 2.2, gap: CGFloat = 2.0) {
                let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
                for (index, height) in heights.enumerated() {
                    let x = midX - total / 2 + CGFloat(index) * (width + gap)
                    NSBezierPath(roundedRect: NSRect(x: x, y: midY - height / 2, width: width, height: height),
                                 xRadius: width / 2, yRadius: width / 2).fill()
                }
            }
            switch state {
            case .hearing: bars([7, 12, 9, 13, 6])
            case .speaking: bars([10, 6, 13, 6, 10])
            case .thinking: bars([2.2, 2.2, 2.2], gap: 2.6)
            case .paused, .error:
                bars([2.2, 2.2, 2.2, 2.2, 2.2])
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: midX - 5.5, y: midY - 5.5))
                slash.line(to: NSPoint(x: midX + 5.5, y: midY + 5.5))
                slash.lineWidth = 1.4
                slash.lineCapStyle = .round
                slash.stroke()
            default: bars([4, 8, 12, 8, 4])
            }
            if warning != nil {
                // Template images are one colour, so a problem is a dot, not amber or red.
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Friday, \(state.label)"
        return image
    }
}
