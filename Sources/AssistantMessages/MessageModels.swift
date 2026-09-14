import Foundation

public struct MessageIdentity: Codable, Equatable, Hashable, Sendable {
  public let id: String
  public let displayName: String?

  public init(id: String, displayName: String?) {
    self.id = id
    self.displayName = displayName
  }
}

public struct AttachmentMetadata: Codable, Equatable, Sendable {
  public let id: String
  public let fileName: String?
  public let mediaType: String?
  public let sizeBytes: Int64?

  public init(
    id: String,
    fileName: String? = nil,
    mediaType: String? = nil,
    sizeBytes: Int64? = nil
  ) {
    self.id = id
    self.fileName = fileName
    self.mediaType = mediaType
    self.sizeBytes = sizeBytes
  }
}

public struct MessageEnvelope: Codable, Equatable, Sendable {
  public let id: String
  public let sourceID: String
  public let conversationID: String
  public let sender: MessageIdentity
  public let sentAt: Date
  public let receivedAt: Date?
  public let subject: String?
  public let text: String?
  public let attachments: [AttachmentMetadata]

  public init(
    id: String,
    sourceID: String,
    conversationID: String,
    sender: MessageIdentity,
    sentAt: Date,
    receivedAt: Date?,
    subject: String?,
    text: String?,
    attachments: [AttachmentMetadata]
  ) {
    self.id = id
    self.sourceID = sourceID
    self.conversationID = conversationID
    self.sender = sender
    self.sentAt = sentAt
    self.receivedAt = receivedAt
    self.subject = subject
    self.text = text
    self.attachments = attachments
  }
}

public struct MessageConversation: Codable, Equatable, Sendable {
  public let id: String
  public let sourceID: String
  public let title: String

  public init(id: String, sourceID: String, title: String) {
    self.id = id
    self.sourceID = sourceID
    self.title = title
  }
}

public struct MessageCursor: Codable, Equatable, Sendable {
  public let value: String

  public init(_ value: String) {
    self.value = value
  }
}

public struct MessagePage: Codable, Equatable, Sendable {
  public let messages: [MessageEnvelope]
  public let nextCursor: MessageCursor?

  public init(messages: [MessageEnvelope], nextCursor: MessageCursor?) {
    self.messages = messages
    self.nextCursor = nextCursor
  }
}

public enum MessageUpdate: Equatable, Sendable {
  case message(MessageEnvelope)
  case removed(messageID: String, sourceID: String)
}
