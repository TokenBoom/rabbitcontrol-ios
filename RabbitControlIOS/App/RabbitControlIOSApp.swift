import RabbitControlCore
import SwiftUI

@main
struct RabbitControlIOSApp: App {
    init() {
        _ = rc_apple_media_init()
        let target = AuthService.shared.serverTarget
        RuntimeService.shared.sync(AuthService.shared.session, target: target, rebuild: true)
        LANDiscoveryService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
