import SwiftUI

@main
struct DevWorkspaceApp: App {
    @NSApplicationDelegateAdaptor(DevWorkspaceApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
