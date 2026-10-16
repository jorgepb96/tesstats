import SwiftUI

/// Large battery ring — the hero element of the dashboard. Crimson by default, shifting
/// to amber/red at low charge for at-a-glance clarity.
struct BatteryRing: View {
    let level: Int
    var usableLevel: Int?
    var charging: Bool
    var limitSoc: Int?
    var centerTitle: String
    var centerSubtitle: String
    var lineWidth: CGFloat = 16
    var size: CGFloat = 184

    private var fraction: CGFloat { CGFloat(min(max(level, 0), 100)) / 100 }

    private var ringColor: Color {
        if level <= 10 { return Brand.danger }
        if level <= 20 { return Brand.warning }
        return Brand.crimson
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Brand.elevatedSurface, lineWidth: lineWidth)

            // Charge limit marker
            if let limit = limitSoc, limit < 100 {
                Circle()
                    .trim(from: CGFloat(limit) / 100 - 0.002, to: CGFloat(limit) / 100 + 0.002)
                    .stroke(Brand.textSecondary, style: StrokeStyle(lineWidth: lineWidth + 6, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(0.6)
            }

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [ringColor.opacity(0.55), ringColor]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + Double(fraction) * 360)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: ringColor.opacity(0.5), radius: 8)
                .animation(.smooth(duration: 0.6), value: level)

            VStack(spacing: 2) {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.crimson)
                        .symbolEffect(.pulse, options: .repeating)
                }
                Text(centerTitle)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: centerTitle)
                Text(centerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery \(level) percent"))
        .accessibilityValue(Text(centerSubtitle))
    }
}
