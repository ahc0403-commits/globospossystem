import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private static let applicationGroup = "group.com.globosvn.globosPosSystem"
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttemptContent = content

    guard let amount = parseAmount(content.userInfo["amount"]),
          let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent(
            "bank_transfer_vi",
            isDirectory: true
          ),
          let sharedRoot = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.applicationGroup
          )
    else {
      contentHandler(content)
      return
    }

    do {
      let eventID = (content.userInfo["event_id"] as? String) ?? request.identifier
      let soundURL = try VietnameseBankTransferSoundComposer().compose(
        amount: amount,
        eventID: eventID,
        resourceDirectory: resourceRoot,
        outputDirectory: sharedRoot
          .appendingPathComponent("Library", isDirectory: true)
          .appendingPathComponent("Sounds",
          isDirectory: true
        )
      )
      content.sound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: soundURL.lastPathComponent)
      )
    } catch {
      content.sound = .default
    }
    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    guard let contentHandler, let bestAttemptContent else { return }
    contentHandler(bestAttemptContent)
  }

  private func parseAmount(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let text = value as? String { return Int64(text) }
    return nil
  }
}
