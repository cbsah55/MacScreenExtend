import SwiftUI

@main
struct ScreenExtendApp: App {
    @StateObject private var receiver = Receiver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(receiver: receiver)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on
                    receiver.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // iOS suspends networking in the background; listen again on return.
                    if phase == .active { receiver.start() }
                    if phase == .background { receiver.didEnterBackground() }
                }
        }
    }
}
