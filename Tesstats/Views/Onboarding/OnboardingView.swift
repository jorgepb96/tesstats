import SwiftUI

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showingSetup = false

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()
                LogoMark(width: 190)
                    .shadow(color: Brand.crimson.opacity(0.35), radius: 22)

                VStack(spacing: 10) {
                    Text(L("Tesstats"))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(L("A beautiful companion for your self-hosted TeslaMate."))
                        .font(.headline)
                        .fontWeight(.regular)
                        .foregroundStyle(Brand.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(icon: "dot.radiowaves.left.and.right", title: L("Live & history"),
                               subtitle: L("Real-time MQTT plus drives, charges and battery health."))
                    FeatureRow(icon: "lock.shield", title: L("Private by design"),
                               subtitle: L("TLS only, credentials in the Keychain, zero telemetry."))
                    FeatureRow(icon: "eye", title: L("Read-only"),
                               subtitle: L("Tesstats never sends vehicle-control commands."))
                }
                .padding(.horizontal, 28)
                .padding(.top, 6)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showingSetup = true
                    } label: {
                        Label(L("Set up your server"), systemImage: "server.rack")
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)

                    Button {
                        env.enableDemoMode()
                    } label: {
                        Label(L("Explore demo mode"), systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)

                Text(L("Read-only · TLS only · No telemetry"))
                    .font(.caption)
                    .foregroundStyle(Brand.textTertiary)
                    .padding(.bottom, 8)
            }
            .padding()
        }
        .sheet(isPresented: $showingSetup) {
            NavigationStack { SettingsView(isOnboarding: true) }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Brand.crimson)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(Brand.textSecondary)
            }
            Spacer()
        }
    }
}
