import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RecordingsStore
    @StateObject private var recorder = Recorder()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            RecorderView(recorder: recorder)
                .tabItem { Label("Запись", systemImage: "mic.circle.fill") }
                .tag(0)

            RecordingsListView()
                .tabItem { Label("Записи", systemImage: "list.bullet.rectangle") }
                .tag(1)

            SettingsView(recorder: recorder)
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(2)

            HelpView()
                .tabItem { Label("Помощь", systemImage: "questionmark.circle.fill") }
                .tag(3)
        }
        .onAppear {
            recorder.onFinish = { rec in store.add(rec) }
        }
    }
}
