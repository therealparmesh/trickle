import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
  private let appGroup = "group.com.parmscript.trickle"
  private let incomingShareKey = "incomingShareText"

  override func isContentValid() -> Bool {
    let hasText = (contentText ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty == false
    return hasText || extensionContext?.inputItems.isEmpty == false
  }

  override func didSelectPost() {
    Task { @MainActor in
      var parts = [
        (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      ]
        .filter { $0.isEmpty == false }
      if let items = extensionContext?.inputItems as? [NSExtensionItem] {
        for attachment in items.compactMap({ $0.attachments }).flatMap({ $0 }) {
          if let value = await loadSharedValue(from: attachment) {
            parts.append(value)
          }
        }
      }
      let text = parts.joined(separator: "\n")
      if text.isEmpty == false {
        UserDefaults(suiteName: appGroup)?.set(text, forKey: incomingShareKey)
      }
      extensionContext?.completeRequest(returningItems: nil)
    }
  }

  override func configurationItems() -> [Any]! { [] }

  override func presentationAnimationDidFinish() {
    super.presentationAnimationDidFinish()
    placeholder = "Feed or website address"
  }

  private func loadSharedValue(from provider: NSItemProvider) async -> String? {
    let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
      ? UTType.url.identifier
      : UTType.plainText.identifier
    guard provider.hasItemConformingToTypeIdentifier(type) else { return nil }
    return await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type) { item, _ in
        let value: String? = switch item {
        case let url as URL: url.absoluteString
        case let text as String: text
        default: nil
        }
        continuation.resume(returning: value?.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
  }
}
