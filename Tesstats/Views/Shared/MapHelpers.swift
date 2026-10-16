import MapKit

extension MKCoordinateRegion {
    /// A region that comfortably fits all the given coordinates.
    init(fitting coordinates: [Coordinate]) {
        guard let first = coordinates.first else {
            self.init(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                      span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
            return
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.01))
        self.init(center: center, span: span)
    }
}

/// Small, stable map inputs. TeslaMate can return thousands of GPS samples per drive; MapKit
/// does not need every one of them for a 300-point card, and feeding the full history into the
/// SwiftUI diff engine can monopolise the main thread.
enum MapGeometry {
    static func sampled(_ coordinates: [Coordinate], maximumCount: Int) -> [Coordinate] {
        guard maximumCount > 1, coordinates.count > maximumCount else { return coordinates }
        let last = coordinates.count - 1
        return (0..<maximumCount).map { index in
            coordinates[index * last / (maximumCount - 1)]
        }
    }
}

import SwiftUI

/// Turns an embedded map into a calm, scroll-friendly preview and opens a second, fully
/// interactive map when anywhere on the preview is tapped. This avoids fighting the parent
/// ScrollView for pan gestures while still making zooming and inspecting markers one tap away.
struct ExpandableMapPreview<Preview: View, Expanded: View>: View {
    let title: String
    let identifier: String
    let preview: () -> Preview
    let expanded: () -> Expanded

    @State private var isExpanded = false

    init(title: String, identifier: String,
         @ViewBuilder preview: @escaping () -> Preview,
         @ViewBuilder expanded: @escaping () -> Expanded) {
        self.title = title
        self.identifier = identifier
        self.preview = preview
        self.expanded = expanded
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            preview().allowsHitTesting(false)
            Button { isExpanded = true } label: {
                Color.clear.contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Expand map"))
                .accessibilityIdentifier("expand-map-\(identifier)")
            Button { isExpanded = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .adaptiveGlass(in: Circle(), interactive: true)
            .foregroundStyle(Brand.textPrimary)
            .padding(12)
            .accessibilityLabel(L("Expand map"))
        }
        .expandedMapCover(isPresented: $isExpanded) {
            ExpandedMapScreen(title: title, content: expanded)
        }
    }
}

private struct ExpandedMapScreen<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let content: () -> Content

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                content().ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L("Close"))
                    .accessibilityIdentifier("close-expanded-map")
                }
            }
        }
    }
}

/// A map that keeps following the car.
///
/// `Map(initialPosition:)` applies its camera only on the first render, so a card built with it
/// keeps showing wherever the car was when the screen first appeared: the annotation moves with
/// the live position but the visible region never does, and the marker silently drifts
/// off-screen. Parking somewhere new then reads as "still at the previous place".
struct FollowingMap<Marker: View>: View {
    let coordinate: Coordinate
    /// Latitude/longitude delta of the visible region.
    var span: CLLocationDegrees
    @ViewBuilder var marker: () -> Marker

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            Annotation("", coordinate: coordinate.clLocationCoordinate) { marker() }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onAppear { camera = region }
        // Latitude and longitude arrive as separate MQTT messages. Debouncing prevents two
        // overlapping camera animations for every GPS update.
        .task(id: coordinate) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { camera = region }
        }
    }

    private var region: MapCameraPosition {
        .region(MKCoordinateRegion(center: coordinate.clLocationCoordinate,
                                   span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
}

/// A map that refits its camera whenever the coordinates it displays change.
///
/// Same trap as `FollowingMap`: with `Map(initialPosition:)` the region is set once, so
/// changing the date-range filter (or a trip's route arriving from the API after the screen
/// is already on-screen) redrew the overlays outside the visible region.
struct FittingMap<Content: MapContent>: View {
    let coordinates: [Coordinate]
    @MapContentBuilder var content: () -> Content

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let viewport = MapViewport(coordinates)
        Map(position: $camera) { content() }
            .onAppear { camera = .region(viewport.region) }
            // Compare four bounds and a count, not an entire multi-thousand-point trace.
            .onChange(of: viewport) { _, next in
                withAnimation(.easeInOut(duration: 0.6)) { camera = .region(next.region) }
            }
    }
}

private struct MapViewport: Equatable {
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double
    var count: Int

    init(_ coordinates: [Coordinate]) {
        guard let first = coordinates.first else {
            minLatitude = 0; maxLatitude = 0
            minLongitude = 0; maxLongitude = 0
            count = 0
            return
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        minLatitude = minLat; maxLatitude = maxLat
        minLongitude = minLon; maxLongitude = maxLon
        count = coordinates.count
    }

    var region: MKCoordinateRegion {
        let center = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                                            longitude: (minLongitude + maxLongitude) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLatitude - minLatitude) * 1.5, 0.01),
                                    longitudeDelta: max((maxLongitude - minLongitude) * 1.5, 0.01))
        return MKCoordinateRegion(center: center, span: span)
    }
}
