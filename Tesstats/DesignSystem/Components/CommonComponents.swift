import SwiftUI

// MARK: - Card surface (solid — dense reading content never sits on glass)

struct CardBackground: ViewModifier {
    var padding: CGFloat = Metrics.cardPadding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = Metrics.cardPadding) -> some View { modifier(CardBackground(padding: padding)) }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    var accent: Color = Brand.action

    init(_ title: String, systemImage: String? = nil, accent: Color = Brand.action) {
        self.title = title; self.systemImage = systemImage; self.accent = accent
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(accent)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
            Spacer()
        }
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = Brand.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption).foregroundStyle(Brand.textTertiary)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Brand.textTertiary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Key/value row

struct KeyValueRow: View {
    let label: String
    let value: String
    var valueColor: Color = Brand.textPrimary
    var systemImage: String?
    var copyValue: String?
    @State private var copied = false

    @ViewBuilder
    var body: some View {
        if let copyValue, !copyValue.isEmpty {
            Button {
                PlatformClipboard.copy(copyValue)
                withAnimation(.easeInOut(duration: 0.2)) { copied = true }
            } label: {
                row(showsCopyAction: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label), \(value)")
            .accessibilityHint(L("Copy to clipboard"))
            .accessibilityIdentifier("copyable-\(label.lowercased())")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            }
        } else {
            row(showsCopyAction: false)
        }
    }

    private func row(showsCopyAction: Bool) -> some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textTertiary)
                    .frame(width: 22, alignment: .center)
            }
            Text(label).font(.subheadline).foregroundStyle(Brand.textSecondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
            if showsCopyAction {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copied ? Brand.online : Brand.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Chip / badge

struct Chip: View {
    let text: String
    var systemImage: String?
    var color: Color = Brand.action
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.weight(.bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(filled ? Color.white : color)
        .background(filled ? color : color.opacity(0.16), in: Capsule())
    }
}

// MARK: - Status pill (connection)

struct ConnectionPill: View {
    let status: ConnectionStatus
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 7, height: 7)
                .shadow(color: status.color.opacity(0.8), radius: status.isLive ? 4 : 0)
            Text(status.label).font(.caption2.weight(.semibold)).foregroundStyle(Brand.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Brand.elevatedSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }
}

/// Compact connection dot for toolbars.
struct ConnectionDot: View {
    let status: ConnectionStatus
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 9, height: 9)
            .shadow(color: status.color.opacity(0.8), radius: status.isLive ? 4 : 0)
            .accessibilityLabel(Text(status.label))
    }
}

// MARK: - State views

struct LoadingStateView: View {
    var label: String = L("Loading…")
    var body: some View {
        BrandLoader(size: .section, label: label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    var systemImage: String = "tray"
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Brand.textTertiary)
            Text(title).font(.headline).foregroundStyle(Brand.textPrimary).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).glassProminentButtonStyle().padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Brand.warning)
            Text(L("Something went wrong")).font(.headline).foregroundStyle(Brand.textPrimary)
            Text(message).font(.subheadline).foregroundStyle(Brand.textSecondary).multilineTextAlignment(.center)
            if let retry {
                Button(L("Try again"), action: retry).glassButtonStyle()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Brand logo mark

struct LogoMark: View {
    var width: CGFloat = 120
    var color: Color = Brand.signature
    var body: some View {
        Image("Logo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .foregroundStyle(color)
            .accessibilityLabel("Tesstats")
    }
}

/// Small brand mark for tab toolbars.
struct ToolbarLogo: View {
    var body: some View {
        Image("Logo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: 17)
            .foregroundStyle(Brand.signature)
            .accessibilityHidden(true)
    }
}

// MARK: - Tappable unit values

/// Flips a display unit that lives in `ServerConfig`, so tapping any consumption or pressure
/// value anywhere in the app switches all of them at once and the choice survives a relaunch.
enum UnitToggle {
    @MainActor
    static func consumption(_ env: AppEnvironment) {
        env.settings.config.consumptionUnit = env.settings.config.consumptionUnit.next
        env.settings.save()
    }

    @MainActor
    static func pressure(_ env: AppEnvironment) {
        env.settings.config.pressureIsPsi.toggle()
        env.settings.save()
    }
}

/// Small "these units are tappable" affordance.
struct UnitSwapHint: View {
    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 8))
            .foregroundStyle(Brand.textTertiary)
            .accessibilityHidden(true)
    }
}

/// A `StatTile` whose value flips units on tap.
struct UnitStatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = Brand.textPrimary
    let onTap: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy) { onTap() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.caption).foregroundStyle(Brand.textTertiary)
                    }
                    Text(title).font(.caption).foregroundStyle(Brand.textTertiary).lineLimit(1)
                    UnitSwapHint()
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("\(title): \(value). Tap to change unit."))
    }
}

/// Consumption value that flips between Wh/km and kWh/100 km on tap.
struct ConsumptionStat: View {
    let title: String
    let whPerKm: Double?
    let units: Units
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        UnitStatTile(title: title,
                     value: units.consumption(whPerKm: whPerKm),
                     systemImage: "bolt",
                     tint: Brand.crimson) { UnitToggle.consumption(env) }
    }
}
