import SwiftUI

/// Brand loading indicator: the Tesstats mark with speed streaks rushing past behind it, so a
/// slow server read reads as "the car is moving" instead of as a frozen screen.
///
/// Every layer animates exactly ONE property with an implicit `repeatForever` animation — no
/// `TimelineView`, no `Canvas`, no per-frame body evaluation — so it can sit on screen for the
/// whole duration of a multi-year history download without costing the main thread a frame.
struct BrandLoader: View {
    enum Size {
        /// Fills a whole screen or section.
        case section
        /// Sits inside one card-shaped placeholder.
        case card
        /// Small mark inside the badge shown while a background refresh runs.
        case inline
    }

    var size: Size = .section
    var label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: size.labelSpacing) {
            ZStack {
                SpeedStreaks(size: size, animated: !reduceMotion)
                RushingMark(size: size, animated: !reduceMotion)
            }
            .frame(width: size.laneWidth, height: size.frameHeight)
            if let label {
                Text(label)
                    .font(size.labelFont)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? L("Loading…"))
    }
}

// MARK: - Geometry

// The mark is a very wide, very flat car profile (about 5.7:1), so the streak lane is kept
// close to its own height — trails far above and below the roof read as noise, not as speed.
extension BrandLoader.Size {
    var logoWidth: CGFloat {
        switch self {
        case .section: 150
        case .card: 112
        case .inline: 42
        }
    }
    var laneWidth: CGFloat {
        switch self {
        case .section: 300
        case .card: 224
        case .inline: 64
        }
    }
    /// Vertical spread of the trails.
    var laneHeight: CGFloat {
        switch self {
        case .section: 62
        case .card: 46
        case .inline: 16
        }
    }
    /// Height of the whole indicator, so a surging mark never clips.
    var frameHeight: CGFloat {
        switch self {
        case .section: 88
        case .card: 66
        case .inline: 22
        }
    }
    /// The mark sits slightly ahead of centre, leaving more lane for the trails behind it.
    var markOffset: CGFloat {
        switch self {
        case .section: -14
        case .card: -10
        case .inline: -4
        }
    }
    /// How far the mark drifts forward and back while the trails rush past.
    var surge: CGFloat {
        switch self {
        case .section: 5
        case .card: 4
        case .inline: 2
        }
    }
    var glowRadius: CGFloat {
        switch self {
        case .section: 18
        case .card: 13
        case .inline: 5
        }
    }
    var labelSpacing: CGFloat {
        switch self {
        case .section: 14
        case .card: 10
        case .inline: 4
        }
    }
    var labelFont: Font {
        switch self {
        case .section: .subheadline
        case .card: .caption
        case .inline: .caption2
        }
    }
}

// MARK: - The mark

/// The logo itself: a slow forward/back surge, so the car looks like it is pulling against the
/// trails rather than sitting still in the middle of them.
private struct RushingMark: View {
    let size: BrandLoader.Size
    let animated: Bool
    @State private var surging = false

    var body: some View {
        LogoMark(width: size.logoWidth, color: Brand.crimson)
            .shadow(color: Brand.crimson.opacity(0.35), radius: size.glowRadius, x: -size.surge, y: 0)
            .scaleEffect(surging ? 1.03 : 0.98)
            // The mark points left, so "forward" is negative x.
            .offset(x: size.markOffset + (surging ? -size.surge : size.surge))
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    surging = true
                }
            }
    }
}

// MARK: - Speed streaks

/// One motion trail. A fixed table rather than randomness, so the layout is deterministic and
/// the body never has to recompute it.
private struct Streak: Identifiable {
    let id: Int
    /// Vertical position, −1…1 across the lane.
    let y: CGFloat
    /// Length as a fraction of the lane width.
    let length: CGFloat
    let thickness: CGFloat
    let opacity: Double
    let duration: Double
    let delay: Double
    /// Accent-colored trails carry the motion; neutral ones give the lane depth.
    let accent: Bool
}

private let streaks: [Streak] = [
    Streak(id:  0, y: -0.95, length: 0.30, thickness: 2.5, opacity: 0.34, duration: 1.15, delay: 0.05, accent: false),
    Streak(id:  1, y: -0.72, length: 0.46, thickness: 3.0, opacity: 0.72, duration: 0.92, delay: 0.44, accent: true),
    Streak(id:  2, y: -0.48, length: 0.24, thickness: 2.5, opacity: 0.30, duration: 1.28, delay: 0.16, accent: false),
    Streak(id:  3, y: -0.24, length: 0.56, thickness: 3.5, opacity: 0.85, duration: 0.78, delay: 0.60, accent: true),
    Streak(id:  4, y:  0.00, length: 0.34, thickness: 2.5, opacity: 0.40, duration: 1.06, delay: 0.28, accent: false),
    Streak(id:  5, y:  0.22, length: 0.62, thickness: 4.0, opacity: 0.95, duration: 0.70, delay: 0.00, accent: true),
    Streak(id:  6, y:  0.44, length: 0.28, thickness: 2.5, opacity: 0.32, duration: 1.34, delay: 0.52, accent: false),
    Streak(id:  7, y:  0.66, length: 0.48, thickness: 3.0, opacity: 0.68, duration: 0.88, delay: 0.22, accent: true),
    Streak(id:  8, y:  0.88, length: 0.22, thickness: 2.5, opacity: 0.28, duration: 1.42, delay: 0.68, accent: false),
    Streak(id:  9, y: -0.60, length: 0.20, thickness: 2.0, opacity: 0.26, duration: 1.50, delay: 0.86, accent: false)
]

private struct SpeedStreaks: View {
    let size: BrandLoader.Size
    let animated: Bool

    var body: some View {
        ZStack {
            ForEach(streaks) { streak in
                StreakView(streak: streak, size: size, animated: animated)
                    .offset(y: streak.y * size.laneHeight / 2)
            }
        }
        .frame(width: size.laneWidth, height: size.laneHeight)
        // Trails appear and dissolve inside the lane instead of hard-clipping at its edges.
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1.00)
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

private struct StreakView: View {
    let streak: Streak
    let size: BrandLoader.Size
    let animated: Bool
    @State private var passing = false

    private var length: CGFloat { size.laneWidth * streak.length }
    /// Off-lane on either side, so a trail is fully hidden before it wraps around.
    private var travel: CGFloat { size.laneWidth / 2 + length }

    private var tint: Color { streak.accent ? Brand.crimson : Brand.textSecondary }

    var body: some View {
        Capsule()
            // The mark faces left, so the world streams to the right: each trail is brightest
            // at its right-hand tip and fades out behind it — a motion blur, not a bar.
            .fill(LinearGradient(stops: [
                .init(color: tint.opacity(0), location: 0.00),
                .init(color: tint.opacity(streak.opacity * 0.5), location: 0.55),
                .init(color: tint.opacity(streak.opacity), location: 1.00)
            ], startPoint: .leading, endPoint: .trailing))
            .frame(width: length, height: streak.thickness)
            .offset(x: animated ? (passing ? travel : -travel) : restingOffset)
            .onAppear {
                guard animated else { return }
                withAnimation(.linear(duration: streak.duration)
                    .repeatForever(autoreverses: false)
                    .delay(streak.delay)) {
                    passing = true
                }
            }
    }

    /// Reduce Motion: the trails stay put, spread across the lane, so the mark still reads as
    /// "in motion" without anything actually moving.
    private var restingOffset: CGFloat {
        (CGFloat(streak.id) / CGFloat(max(1, streaks.count - 1)) - 0.5) * size.laneWidth * 0.5
    }
}

// MARK: - Placeholders built on the loader

/// Card-shaped placeholder: the brand loader centered inside a section's own card, so a block
/// that is still being derived shows where its content will land instead of collapsing the page.
struct LoadingCard: View {
    let title: String
    var systemImage: String?
    var message: String?
    var minHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title, systemImage: systemImage)
            BrandLoader(size: .card, label: message)
                .frame(maxWidth: .infinity, minHeight: minHeight)
        }
        .card()
    }
}

/// Non-blocking "there is fresher data on the way" badge. It floats over content that is
/// already on screen — nothing is hidden and nothing is disabled while it shows.
struct RefreshingBadge: View {
    var label: String = L("Updating…")

    var body: some View {
        HStack(spacing: 8) {
            BrandLoader(size: .inline)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(Brand.elevatedSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
        .accessibilityLabel(label)
    }
}

extension View {
    /// Float the refreshing badge over the bottom of a screen while `isActive`. It sits clear
    /// of the filter bars at the top, pushes nothing down, and intercepts no touch — the
    /// content underneath stays fully usable while the load runs.
    func refreshingBadge(_ isActive: Bool, label: String = L("Updating…")) -> some View {
        overlay(alignment: .bottom) {
            if isActive {
                RefreshingBadge(label: label)
                    .padding(.bottom, 12)
            }
        }
        .animation(.snappy, value: isActive)
    }
}
