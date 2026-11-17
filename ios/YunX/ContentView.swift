import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ResolveView()
                .tabItem {
                    Label("解析", systemImage: "link")
                }
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}
