import ImageIO
import UIKit
import UniformTypeIdentifiers

/// "Share to VoipCloud" extension. It has no screen of its own: it copies what
/// was shared (links, text, photos) into the App Group folder shared with the
/// app, then opens VoipCloud, which asks who to send it to.
///
/// Photos are re-encoded as <= 1600 px JPEGs (HEIC/PNG/WebP -> JPEG, location
/// data dropped) using ImageIO, which decodes without loading the full bitmap
/// (extensions have a small memory limit).
final class ShareViewController: UIViewController {
  private let appGroup = "group.com.thinkswift.softphoneapp"
  private let openURLString = "voipcloudshare://open"
  private let maxFiles = 10
  private let maxPixelSize = 1600

  private let lock = NSLock()
  private var texts: [String] = []
  private var urls: [String] = []
  private var files: [[String: String]] = []

  private var shareDirectory: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent("share", isDirectory: true)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    collect()
  }

  private func collect() {
    guard let directory = shareDirectory else { return cancel() }
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let group = DispatchGroup()
    for provider in items.flatMap({ $0.attachments ?? [] }) {
      if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.image.identifier) { [self] item, _ in
          defer { group.leave() }
          lock.lock()
          let full = files.count >= maxFiles
          lock.unlock()
          guard !full, let file = saveJPEG(from: item, in: directory) else { return }
          lock.lock()
          files.append(file)
          lock.unlock()
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [self] item, _ in
          defer { group.leave() }
          guard let url = item as? URL, !url.isFileURL else { return }
          lock.lock()
          urls.append(url.absoluteString)
          lock.unlock()
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [self] item, _ in
          defer { group.leave() }
          guard let text = item as? String else { return }
          lock.lock()
          texts.append(text)
          lock.unlock()
        }
      }
    }
    group.notify(queue: .main) { [self] in finish(directory: directory) }
  }

  private func finish(directory: URL) {
    // Apps like Amazon share the link twice (as text and as a URL): keep each once.
    var text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    for url in urls where !text.contains(url) {
      text = text.isEmpty ? url : text + "\n" + url
    }
    guard !text.isEmpty || !files.isEmpty else { return cancel() }

    let payload: [String: Any] = [
      "id": UUID().uuidString,
      "text": text,
      "files": files,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          (try? data.write(to: directory.appendingPathComponent("share.json"), options: .atomic)) != nil
    else { return cancel() }

    openHostApp()
    extensionContext?.completeRequest(returningItems: nil)
  }

  private func cancel() {
    extensionContext?.cancelRequest(
      withError: NSError(domain: "com.thinkswift.softphoneapp.share", code: 1)
    )
  }

  private func saveJPEG(from item: NSSecureCoding?, in directory: URL) -> [String: String]? {
    let source: CGImageSource?
    if let url = item as? URL {
      source = CGImageSourceCreateWithURL(url as CFURL, nil)
    } else if let data = item as? Data {
      source = CGImageSourceCreateWithData(data as CFData, nil)
    } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
      source = CGImageSourceCreateWithData(data as CFData, nil)
    } else {
      source = nil
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let source,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    else { return nil }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }

    let name = "shared-\(UUID().uuidString).jpg"
    let url = directory.appendingPathComponent(name)
    guard (try? (output as Data).write(to: url, options: .atomic)) != nil else { return nil }
    return ["path": url.path, "mimeType": "image/jpeg", "name": name]
  }

  /// Share extensions cannot call UIApplication.open directly, so find the
  /// hosting UIApplication in the responder chain and call it dynamically.
  private func openHostApp() {
    guard let url = URL(string: openURLString) else { return }
    var responder: UIResponder? = self
    while let current = responder {
      if current is UIApplication {
        let modern = NSSelectorFromString("open:options:completionHandler:")
        if let implementation = current.method(for: modern) {
          typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
          unsafeBitCast(implementation, to: Open.self)(current, modern, url as NSURL, [:], nil)
        } else {
          _ = current.perform(NSSelectorFromString("openURL:"), with: url)
        }
        return
      }
      responder = current.next
    }
  }
}
