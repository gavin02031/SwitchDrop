import SwiftUI

@main
struct SwitchDropApp: App {
    @StateObject private var model = DropModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
