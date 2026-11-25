import RabbitControlCore
import SwiftUI

@main
struct RabbitControlIOSApp: App {
    init() {
        _ = rc_apple_media_init()
        let target = AuthService.shared.serverTarget
        RuntimeService.shared.boot(serverHost: target.host, useHTTPS: target.useHTTPS)
        LANDiscoveryService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
