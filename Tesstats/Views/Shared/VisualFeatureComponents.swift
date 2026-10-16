import SwiftUI
import MapKit
import Charts

struct DemoDataBanner: View {
    let isDemo: Bool
    let action: () -> Void

    var body: some View {
        if isDemo {
            HStack(spacing: 12) {
                Image(systemName: "eye.fill")
                    .font(.title3)
                    .foregroundStyle(Brand.action)
                    .frame(width: 34, height: 34)
                    .background(Brand.action.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Sample data"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(L("Connect your TeslaMate server to see your car."))
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer()
                Button(action: action) {
                    Label(L("Connect"), systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
                .tint(Brand.action)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 10)
            .background(Brand.surface)
            .overlay(alignment: .bottom) { Divider().overlay(Brand.hairline) }
        }
    }
}

struct HeroMapCard: View {
    let state: VehicleState
    let units: Units

    var body: some View {
        ExpandableMapPreview(title: L("Location"), identifier: "vehicle") {
            ZStack(alignment: .bottomLeading) {
                vehicleMap

                LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("\(state.batteryLevel ?? state.usableBatteryLevel ?? 0)")
                            .font(.system(size: 76, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.7)
                        Text("%")
                            .font(.title.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(L("Range"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.62))
                                .textCase(.uppercase)
                            Text(units.range(km: state.range(for: units.range)))
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    ProgressView(value: Double(state.batteryLevel ?? 0), total: 100)
                        .tint(Brand.driving)
                }
                .padding(20)
            }
        } expanded: {
            vehicleMap
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var vehicleMap: some View {
        if let coordinate = state.coordinate {
            FollowingMap(coordinate: coordinate, span: 0.018) {
                ZStack {
                    Circle().fill(Brand.driving.opacity(0.25)).frame(width: 46, height: 46)
                    Circle().fill(Brand.driving).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        } else {
            LinearGradient(colors: [Brand.elevatedSurface, Brand.surface], startPoint: .top, endPoint: .bottom)
        }
    }

}

struct ActivityTimelineView: View {
    let segments: [DashboardActivitySegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(L("Last 48h"), systemImage: "clock.arrow.circlepath")
                legend(L("Driving"), Brand.danger)
                legend(L("Charging"), Brand.online)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.elevatedSurface)
                    ForEach(segments) { segment in
                        Capsule()
                            .fill(color(for: segment.kind))
                            .frame(width: width(segment, in: proxy.size.width), height: 26)
                            .offset(x: offset(segment, in: proxy.size.width))
                    }
                }
            }
            .frame(height: 26)
            HStack {
                Text("-48h")
                Spacer()
                Text("-24h")
                Spacer()
                Text(L("Now"))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Brand.textTertiary)
        }
        .card()
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(Brand.textTertiary)
        }
    }

    private func color(for kind: DashboardActivitySegment.Kind) -> Color {
        switch kind {
        case .driving: Brand.danger
        case .charging: Brand.online
        case .online: Brand.driving
        }
    }

    private func offset(_ segment: DashboardActivitySegment, in width: CGFloat) -> CGFloat {
        let now = Date()
        let start = now.addingTimeInterval(-48 * 3600)
        let t = max(0, min(1, segment.start.timeIntervalSince(start) / (48 * 3600)))
        return width * t
    }

    private func width(_ segment: DashboardActivitySegment, in width: CGFloat) -> CGFloat {
        let duration = max(600, segment.end.timeIntervalSince(segment.start))
        return max(4, width * duration / (48 * 3600))
    }
}

struct HistoryMapHeader: View {
    enum Content {
        case drives([DriveRecord])
        case charges([ChargeRecord])
        case parking([ParkingSession])
    }

    let title: String
    let subtitle: String
    let metric: String
    let content: Content
    var identifier: String = "history"

    var body: some View {
        ExpandableMapPreview(title: title, identifier: identifier) {
            ZStack(alignment: .bottomLeading) {
                map(maximumItems: previewItemLimit)
                LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    Text(subtitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .textCase(.uppercase)
                        .tracking(2)
                    Text(metric)
                        .font(.system(size: 62, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(20)
            }
        } expanded: {
            map(maximumItems: expandedItemLimit)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private func map(maximumItems: Int) -> some View {
        let coords = coordinates(maximumItems: maximumItems)
        if coords.isEmpty {
            Brand.elevatedSurface
        } else {
            FittingMap(coordinates: coords) {
                switch content {
                case .drives(let drives):
                    ForEach(drives.prefix(maximumItems)) { drive in
                        if drive.path.count >= 2 {
                            MapPolyline(coordinates: MapGeometry.sampled(drive.path, maximumCount: 500)
                                .map(\.clLocationCoordinate))
                                .stroke(Brand.driving, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }
                    }
                case .charges(let charges):
                    ForEach(charges.prefix(maximumItems)) { charge in
                        if let coord = charge.coord {
                            Annotation("", coordinate: coord.clLocationCoordinate) {
                                Circle().fill(charge.isFastCharger ? Brand.danger : Brand.online)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
                            }
                        }
                    }
                case .parking(let sessions):
                    ForEach(sessions.prefix(maximumItems)) { session in
                        if let coord = session.coordinate {
                            Annotation("", coordinate: coord.clLocationCoordinate) {
                                Circle().fill(session.isLive ? Brand.online : Brand.warning)
                                    .frame(width: session.isLive ? 18 : 14, height: session.isLive ? 18 : 14)
                                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
        }
    }

    private var previewItemLimit: Int {
        switch content {
        case .drives: 8
        case .charges, .parking: 40
        }
    }

    private var expandedItemLimit: Int {
        switch content {
        case .drives: 30
        case .charges, .parking: 250
        }
    }

    private func coordinates(maximumItems: Int) -> [Coordinate] {
        switch content {
        case .drives(let drives):
            return drives.prefix(maximumItems).flatMap {
                $0.path.isEmpty
                    ? [$0.startCoord, $0.endCoord].compactMap { $0 }
                    : MapGeometry.sampled($0.path, maximumCount: 500)
            }
        case .charges(let charges):
            return charges.prefix(maximumItems).compactMap(\.coord)
        case .parking(let sessions):
            return sessions.prefix(maximumItems).compactMap(\.coordinate)
        }
    }
}

struct TinyRoutePreview: View {
    let path: [Coordinate]

    var body: some View {
        GeometryReader { proxy in
            Path { p in
                let points = normalized(in: proxy.size)
                guard let first = points.first else { return }
                p.move(to: first)
                for point in points.dropFirst() { p.addLine(to: point) }
            }
            .stroke(Brand.textTertiary.opacity(0.42), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 130, height: 70)
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        let path = MapGeometry.sampled(path, maximumCount: 160)
        guard let first = path.first, path.count >= 2 else { return [] }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for coordinate in path.dropFirst() {
            minLat = min(minLat, coordinate.latitude); maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude); maxLon = max(maxLon, coordinate.longitude)
        }
        let latSpan = max(maxLat - minLat, 0.0001)
        let lonSpan = max(maxLon - minLon, 0.0001)
        return path.map { c in
            let x = (c.longitude - minLon) / lonSpan * size.width
            let y = (1 - (c.latitude - minLat) / latSpan) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

struct ScoreRing: View {
    let value: Double
    var color: Color = Brand.online
    /// Short label under the ring saying what the score measures (e.g. "Efficiency").
    /// Without it the bare 0–100 number is ambiguous.
    var caption: String?
    /// Ring size. Rows keep it small so the metrics beside it are not squeezed into wrapping.
    var diameter: CGFloat = 58

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Brand.elevatedSurface, lineWidth: diameter < 52 ? 5 : 7)
                Circle()
                    .trim(from: 0, to: min(1, max(0, value)))
                    .stroke(color, style: StrokeStyle(lineWidth: diameter < 52 ? 5 : 7, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Text((value * 100).formatted(.number.precision(.fractionLength(0)).locale(LanguageManager.locale)))
                    .font((diameter < 52 ? Font.subheadline : Font.headline).weight(.bold))
                    .foregroundStyle(Brand.textPrimary)
            }
            .frame(width: diameter, height: diameter)
            if let caption {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let pct = "\(Int((min(1, max(0, value)) * 100).rounded()))%"
        return caption.map { "\($0): \(pct)" } ?? pct
    }
}

struct FullScreenChartButton<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .tint(Brand.action)
        .sheet(isPresented: $show) {
            NavigationStack {
                ZStack {
                    Brand.background.ignoresSafeArea()
                    content.padding()
                }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Done")) { show = false }
                    }
                }
            }
        }
    }
}
