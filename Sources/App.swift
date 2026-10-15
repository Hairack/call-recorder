import SwiftUI

@main
struct CallRecApp: App {
    @StateObject private var store = RecordingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
