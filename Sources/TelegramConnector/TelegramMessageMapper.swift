import AssistantMessages
import Foundation

public enum TelegramMessageMapper {
  public static func message(from data: Data) throws -> MessageEnvelope {
    let object = try jsonObject(from: data)
    return try message(from: object)
  }

  static func message(from object: [String: Any]) throws -> MessageEnvelope {
    let messageID = try int64(object["id"], field: "id")
    let chatID = try int64(object["chat_id"], field: "chat_id")
    let timestamp = try int64(object["date"], field: "date")
    let senderObject = try dictionary(object["sender_id"], field: "sender_id")
    let content = try dictionary(object["content"], field: "content")

    return MessageEnvelope(
      id: "telegram:\(chatID):\(messageID)",
      sourceID: "telegram",
      conversationID: "telegram:\(chatID)",
      sender: sender(from: senderObject),
      sentAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
      receivedAt: nil,
      subject: nil,
      text: text(from: content),
      attachments: attachments(from: content)
    )
  }

  static func jsonObject(from data: Data) throws -> [String: Any] {
    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw TelegramConnectorError.invalidResponse("Expected a JSON object")
    }
    return object
  }

  private static func sender(from object: [String: Any]) -> MessageIdentity {
    switch object["@type"] as? String {
    case "messageSenderUser":
      let id = (try? int64(object["user_id"], field: "user_id")) ?? 0
      return MessageIdentity(id: "telegram-user:\(id)", displayName: nil)
    case "messageSenderChat":
      let id = (try? int64(object["chat_id"], field: "chat_id")) ?? 0
      return MessageIdentity(id: "telegram-chat:\(id)", displayName: nil)
    default:
      return MessageIdentity(id: "telegram-unknown", displayName: nil)
    }
  }

  private static func text(from content: [String: Any]) -> String? {
    let type = content["@type"] as? String

    if type == "messageText",
      let formattedText = content["text"] as? [String: Any]
    {
      return formattedText["text"] as? String
    }

    if let caption = content["caption"] as? [String: Any],
      let text = caption["text"] as? String,
      !text.isEmpty
    {
      return text
    }

    return type.map { "[\($0)]" }
  }

  private static func attachments(from content: [String: Any]) -> [AttachmentMetadata] {
    guard let type = content["@type"] as? String, type != "messageText" else {
      return []
    }
    return [AttachmentMetadata(id: type, mediaType: "application/x-tdlib-\(type)")]
  }

  private static func dictionary(_ value: Any?, field: String) throws -> [String: Any] {
    guard let dictionary = value as? [String: Any] else {
      throw TelegramConnectorError.invalidResponse("Missing object field '\(field)'")
    }
    return dictionary
  }

  private static func int64(_ value: Any?, field: String) throws -> Int64 {
    if let number = value as? NSNumber {
      return number.int64Value
    }
    if let string = value as? String, let number = Int64(string) {
      return number
    }
    throw TelegramConnectorError.invalidResponse("Missing integer field '\(field)'")
  }
}
