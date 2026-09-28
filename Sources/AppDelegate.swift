import UIKit
import SwiftUI

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Workspace.shared.load()
        return true
    }

    /// Routes each connecting scene to the right delegate. The external-display
    /// role only ever arrives when a display is physically attached.
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External", sessionRole: session.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: "Controller", sessionRole: session.role)
        config.delegateClass = ControllerSceneDelegate.self
        return config
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Workspace.shared.save()
    }
}
