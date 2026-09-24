import SwiftUI
import AppKit

/// Calm green surfaces that follow the Mac’s light or dark appearance.
enum Hub {
    static func dynamic(light: Int, dark: Int, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
        })
    }
    static func dynamicAlpha(light: Double, dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        })
    }

    static var green: Color { dynamic(light: 0x055D4F, dark: 0x68D6B9) }
    static let buttonGreen = Color(red: 0x05 / 255, green: 0x5D / 255, blue: 0x4F / 255)
    static let greenHover = Color(red: 0x04 / 255, green: 0x41 / 255, blue: 0x37 / 255)
    static let mint = Color(red: 0, green: 0xD0 / 255, blue: 0xAF / 255)
    static var flag: Color { dynamic(light: 0xB3261E, dark: 0xFF9187) }
    static var amber: Color { dynamic(light: 0x8A5A00, dark: 0xEFC275) }

    static var cream: Color { dynamic(light: 0xFAF8F5, dark: 0x131416) }
    static var card: Color { dynamic(light: 0xFFFFFF, dark: 0x1B1D20) }
    static var ink: Color { dynamic(light: 0x0C0C0C, dark: 0xF4F4F3) }
    static var body: Color { dynamic(light: 0x1F1D1B, dark: 0xD7D8DA) }
    static var helper: Color { dynamic(light: 0x6E7176, dark: 0x9B9EA3) }
    static var eyebrow: Color { dynamic(light: 0x6E6558, dark: 0x9B9EA3) }
    static var line: Color { dynamicAlpha(light: 0.05, dark: 0.09) }
    static var line2: Color { dynamicAlpha(light: 0.12, dark: 0.20) }
    static var field: Color { dynamicAlpha(light: 0.42, dark: 0.34) }
    static var greenSoft: Color { green.opacity(0.06) }
    static var greenLine: Color { green.opacity(0.22) }

    static let radius: CGFloat = 8
    static let cardRadius: CGFloat = 12

    // Legacy names used by the overlay.
    static var blue: Color { green }
    static var pageFill: Color { cream }
    static var cardFill: Color { card }
}

struct HubCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Hub.cardRadius, style: .continuous).fill(Hub.card))
            .overlay(RoundedRectangle(cornerRadius: Hub.cardRadius, style: .continuous).strokeBorder(Hub.line, lineWidth: 1).allowsHitTesting(false))
    }
}

/// `.btn` from the design system: 36 pt, 4 pt radius; primary is green, secondary white with a border.
struct PillButtonStyleHub: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .primary
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = {
            switch kind {
            case .primary: return .white
            case .secondary: return Hub.body
            case .ghost: return Hub.green
            case .danger: return Hub.flag
            }
        }()
        let bg: Color = {
            switch kind {
            case .primary: return configuration.isPressed ? Hub.greenHover : Hub.buttonGreen
            case .secondary: return configuration.isPressed ? Hub.cream : Hub.card
            case .ghost: return configuration.isPressed ? Hub.greenSoft : .clear
            case .danger: return configuration.isPressed ? Hub.flag.opacity(0.08) : Hub.card
            }
        }()
        let border: Color = {
            switch kind {
            case .primary: return Hub.buttonGreen
            case .secondary: return Hub.line2
            case .ghost: return .clear
            case .danger: return Hub.flag.opacity(0.25)
            }
        }()
        configuration.label
            .font(.hub(small ? 12 : 14, kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(fg)
            .padding(.horizontal, small ? 10 : 14)
            .frame(height: small ? 32 : 36)
            .background(RoundedRectangle(cornerRadius: Hub.radius).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: Hub.radius).strokeBorder(border, lineWidth: 1).allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: Hub.radius))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.hub(24, .semibold)).foregroundColor(Hub.ink).tracking(-0.4)
            Text(subtitle).font(.hub(14)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

struct CardTitle: View {
    let text: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.hub(14, .semibold)).foregroundColor(Hub.ink)
            if let subtitle { Text(subtitle).font(.hub(12)).foregroundColor(Hub.helper) }
        }
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.hub(11, .semibold)).tracking(0.7).foregroundColor(Hub.eyebrow)
    }
}

/// One setting: title and optional one-line help on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hub(14)).foregroundColor(Hub.body)
                if let help { Text(help).font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control().accessibilityLabel(title)
        }
        .padding(.vertical, 6)
    }
}

struct StatusBadge: View {
    let ok: Bool
    var body: some View {
        ZStack {
            Circle().fill(ok ? Hub.buttonGreen : Hub.line2).frame(width: 20, height: 20)
            if ok { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white) }
        }
    }
}

struct KeyBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.hub(16, .semibold))
            .foregroundColor(Hub.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Hub.radius).fill(Hub.cream))
            .overlay(RoundedRectangle(cornerRadius: Hub.radius).strokeBorder(Hub.line2).allowsHitTesting(false))
    }
}

/// Segmented control from the design system: bordered container, selected segment filled green.
struct HubSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(.hub(13, selection == value ? .semibold : .medium))
                        .foregroundColor(selection == value ? .white : Hub.helper)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 3).fill(selection == value ? Hub.buttonGreen : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Hub.radius).fill(Hub.card))
        .overlay(RoundedRectangle(cornerRadius: Hub.radius).strokeBorder(Hub.line2).allowsHitTesting(false))
    }
}

/// `.inp`: 36 pt field with the 42 % border.
struct HubFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.roundedBorder)
            .font(.hub(14))
            .controlSize(.large)
            .frame(minHeight: 36)
    }
}

extension View {
    func hubField() -> some View { modifier(HubFieldStyle()) }
    func hubSwitch() -> some View { toggleStyle(.switch).labelsHidden().tint(Hub.green) }
}

/// Level meter like Typeless's microphone test, in the brand green.
struct LevelMeter: View {
    let level: Float
    let bars = 22
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Float(i) / Float(bars)
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > threshold ? Hub.green : Hub.line2)
                    .frame(width: 6, height: 22)
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }
}

/// `.tiles`: one bordered container, values 24/600, labels 12 helper.
struct StatTiles: View {
    let tiles: [(value: String, label: String)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tiles.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tiles[i].label).font(.hub(12)).foregroundColor(Hub.helper)
                    Text(tiles[i].value).font(.hub(24, .semibold)).foregroundColor(Hub.ink).tracking(-0.4).monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                if i < tiles.count - 1 { Rectangle().fill(Hub.line).frame(width: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: Hub.cardRadius, style: .continuous).fill(Hub.card))
        .overlay(RoundedRectangle(cornerRadius: Hub.cardRadius, style: .continuous).strokeBorder(Hub.line))
    }
}
