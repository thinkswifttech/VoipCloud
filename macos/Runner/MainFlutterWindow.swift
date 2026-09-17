import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var linphoneBridge: LinphoneFlutterBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame
    windowFrame.size.width = max(windowFrame.size.width, 480)
    windowFrame.size.height = max(windowFrame.size.height, 640)
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 480, height: 640)
    self.collectionBehavior.insert(.fullScreenNone)
    self.standardWindowButton(.zoomButton)?.isEnabled = false
    let frameName = NSWindow.FrameAutosaveName("VoipCloudMainWindow")
    if !self.setFrameUsingName(frameName) {
      self.setFrame(windowFrame, display: true)
    }
    self.setFrameAutosaveName(frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)
    linphoneBridge = LinphoneFlutterBridge(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}
