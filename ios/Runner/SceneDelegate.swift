import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )
    for context in connectionOptions.urlContexts {
      if ExternalCommunicationIntentBridge.shared.handle(url: context.url) {
        break
      }
    }
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    if URLContexts.contains(where: {
      ExternalCommunicationIntentBridge.shared.handle(url: $0.url)
    }) {
      return
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    LinphoneFlutterBridge.shared?.handleWillResignActive()
    super.sceneWillResignActive(scene)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    LinphoneFlutterBridge.shared?.handleEnterBackground()
    super.sceneDidEnterBackground(scene)
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    LinphoneFlutterBridge.shared?.handleEnterForeground()
    super.sceneWillEnterForeground(scene)
  }
}
