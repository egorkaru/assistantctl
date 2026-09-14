import Foundation

public struct MessageSource: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case telegram
    case gmail
    case microsoft
    case imap
  }

  public let id: String
  public let kind: Kind
  public let displayName: String

  public init(id: String, kind: Kind, displayName: String) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
  }
}

public protocol MessageConnector: Sendable {
  var source: MessageSource { get }

  func conversations() async throws -> [MessageConversation]
  func messages(
    in conversationID: String,
    cursor: MessageCursor?,
    limit: Int
  ) async throws -> MessagePage
  func message(id: String) async throws -> MessageEnvelope
  func updates() async -> AsyncThrowingStream<MessageUpdate, any Error>
}
