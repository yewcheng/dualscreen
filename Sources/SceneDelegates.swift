import UIKit
import SwiftUI

/// The iPad's own screen. This is the only surface that receives input.
@objc(ControllerSceneDelegate)
final class ControllerSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let root = UIHostingController(rootView: ControllerView().environmentObject(Workspace.shared))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidEnterBackground(_ scene: UIScene) { Workspace.shared.save() }
}

/// The HDMI monitor. iPadOS delivers no touch, pointer or keyboard events here —
/// the role is literally named NonInteractive — so this scene is output only.
@objc(ExternalSceneDelegate)
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let size = windowScene.screen.bounds.size
        let scale = windowScene.screen.scale
        Workspace.shared.attachExternalDisplay(size: size, scale: scale)

        let root = UIHostingController(rootView: WorkspaceView().environmentObject(Workspace.shared))
        root.view.backgroundColor = .black
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.isHidden = false
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Workspace.shared.detachExternalDisplay()
    }
}
