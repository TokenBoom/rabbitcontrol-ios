import RabbitControlCore
import SwiftUI

@main
struct RabbitControlIOSApp: App {
    init() {
        _ = rc_apple_media_init()
        LANDiscoveryService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
