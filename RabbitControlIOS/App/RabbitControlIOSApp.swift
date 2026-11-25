import RabbitControlCore
import SwiftUI
import UIKit

final class RabbitControlAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        SessionOrientationLock.currentMask
    }
}

@main
struct RabbitControlIOSApp: App {
    @UIApplicationDelegateAdaptor(RabbitControlAppDelegate.self) private var appDelegate

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
