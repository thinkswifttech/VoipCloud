import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var linphoneBridge: LinphoneFlutterBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    linphoneBridge = LinphoneFlutterBridge(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}
