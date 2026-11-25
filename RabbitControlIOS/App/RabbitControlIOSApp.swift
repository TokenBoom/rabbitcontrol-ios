import SwiftUI

@main
struct RabbitControlIOSApp: App {
    init() {
        LANDiscoveryService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
