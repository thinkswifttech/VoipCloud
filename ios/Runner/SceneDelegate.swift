import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Capture a cold-start system action before Flutter processes the scene.
    // The bridge buffers it until the Dart method channel is attached.
    var handledExternalIntent = false
    for context in connectionOptions.urlContexts where !handledExternalIntent {
      handledExternalIntent = ExternalCommunicationIntentBridge.shared.handle(
        url: context.url
      )
    }
    for userActivity in connectionOptions.userActivities
      where !handledExternalIntent {
      handledExternalIntent = ExternalCommunicationIntentBridge.shared.handle(
        userActivity: userActivity
      )
    }

    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )
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

  override func scene(
    _ scene: UIScene,
    continue userActivity: NSUserActivity
  ) {
    if ExternalCommunicationIntentBridge.shared.handle(
      userActivity: userActivity
    ) {
      return
    }
    super.scene(scene, continue: userActivity)
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
