import SwiftUI

@main
struct NoScrollApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(state)
                // Widgets deep-link straight into a service: noscroll://open/instagram
                .onOpenURL { state.handle(url: $0) }
        }
    }
}

/// One stable root view for the whole app. The first-run onboarding and the tabs are content
/// inside it: no window or root view controller swap, and no modal presentation for the onboarding, so
/// each screen gets its safe area from the window.
struct AppRoot: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if state.needsOnboarding {
                OnboardingFlow(isPresented: $state.needsOnboarding)
                    .transition(.opacity)
            } else {
                RootView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.needsOnboarding)
    }
}

/// Shell: three tabs (what's blocked, home, settings). The first-run onboarding comes before it (AppRoot).
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView(selection: $state.tab) {
            AllSettingsTab().tag(AppState.Tab.adjust)
                .tabItem { Label("Blocks", systemImage: "slider.horizontal.3") }
            HomeView().tag(AppState.Tab.home)
                .tabItem { Label("Home", systemImage: "house.fill") }
            ProfileTab().tag(AppState.Tab.profile)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Theme.ink)
    }
}
