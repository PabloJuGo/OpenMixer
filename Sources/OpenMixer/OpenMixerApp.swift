import SwiftUI

@main
struct OpenMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }   // real settings live in AppDelegate's window; the menu-bar item is AppKit
    }
}
