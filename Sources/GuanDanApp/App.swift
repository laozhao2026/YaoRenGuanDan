import SwiftUI

@main
struct GuanDanApp: App {
    @StateObject private var serverVM = ServerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverVM)
        }
    }
}
