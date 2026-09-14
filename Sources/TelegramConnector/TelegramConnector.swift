import AssistantJSON
import AssistantMessages
import Foundation

public enum TelegramConnectorError: Error, LocalizedError, Sendable {
  case invalidResponse(String)
  case requestBlocked(String)
  case tdlib(code: Int, message: String)
  case unexpectedAuthorizationState(String)
  case invalidMessageID(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let message): message
    case .requestBlocked(let type): "TDLib request '\(type)' is blocked by read-only policy"
    case .tdlib(let code, let message): "TDLib \(code): \(message)"
    case .unexpectedAuthorizationState(let state):
      "Unsupported Telegram authorization state: \(state)"
    case .invalidMessageID(let id): "Invalid Telegram message ID: \(id)"
    }
  }
}

public struct TelegramConfiguration: Sendable {
  public let apiID: Int
  public let apiHash: String
  public let databaseDirectory: URL
  public let filesDirectory: URL
  public let databaseEncryptionKey: String

  public init(
    apiID: Int,
    apiHash: String,
    databaseDirectory: URL,
    filesDirectory: URL,
    databaseEncryptionKey: String
  ) {
    self.apiID = apiID
    self.apiHash = apiHash
    self.databaseDirectory = databaseDirectory
    self.filesDirectory = filesDirectory
    self.databaseEncryptionKey = databaseEncryptionKey
  }
}

public struct TelegramAuthentication: Sendable {
  public let phoneNumber: String
  public let code: @Sendable () async throws -> String
  public let password: @Sendable () async throws -> String

  public init(
    phoneNumber: String,
    code: @escaping @Sendable () async throws -> String,
    password: @escaping @Sendable () async throws -> String
  ) {
    self.phoneNumber = phoneNumber
    self.code = code
    self.password = password
  }
}

public final class TelegramMessageConnector: MessageConnector, Sendable {
  public let source = MessageSource(
    id: "telegram",
    kind: .telegram,
    displayName: "Telegram"
  )

  private let configuration: TelegramConfiguration
  private let client = TDLibJSONClient()

  public init(configuration: TelegramConfiguration) {
    self.configuration = configuration
  }

  public func authorize(using authentication: TelegramAuthentication) async throws {
    try FileManager.default.createDirectory(
      at: configuration.databaseDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: configuration.filesDirectory,
      withIntermediateDirectories: true
    )

    while true {
      let stateData = try await client.request(type: "getAuthorizationState")
      let state = try authorizationState(from: stateData)

      switch state {
      case "authorizationStateWaitTdlibParameters":
        let parameters: JSONValue = .object([
          "@type": .string("tdlibParameters"),
          "api_hash": .string(configuration.apiHash),
          "api_id": .integer(Int64(configuration.apiID)),
          "application_version": .string("0.1.0"),
          "database_directory": .string(configuration.databaseDirectory.path),
          "device_model": .string("Mac"),
          "enable_storage_optimizer": .boolean(true),
          "files_directory": .string(configuration.filesDirectory.path),
          "ignore_file_names": .boolean(false),
          "system_language_code": .string("en"),
          "system_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
          "use_chat_info_database": .boolean(true),
          "use_file_database": .boolean(true),
          "use_message_database": .boolean(true),
          "use_secret_chats": .boolean(false),
          "use_test_dc": .boolean(false),
        ])
        _ = try await client.request(
          type: "setTdlibParameters",
          fields: ["parameters": parameters]
        )
      case "authorizationStateWaitEncryptionKey":
        _ = try await client.request(
          type: "checkDatabaseEncryptionKey",
          fields: ["encryption_key": .string(configuration.databaseEncryptionKey)]
        )
      case "authorizationStateWaitPhoneNumber":
        _ = try await client.request(
          type: "setAuthenticationPhoneNumber",
          fields: [
            "phone_number": .string(authentication.phoneNumber),
            "settings": .object([
              "@type": .string("phoneNumberAuthenticationSettings"),
              "allow_flash_call": .boolean(false),
              "allow_missed_call": .boolean(false),
              "allow_sms_retriever_api": .boolean(false),
              "authentication_tokens": .array([]),
              "is_current_phone_number": .boolean(false),
            ]),
          ]
        )
      case "authorizationStateWaitCode":
        _ = try await client.request(
          type: "checkAuthenticationCode",
          fields: ["code": .string(try await authentication.code())]
        )
      case "authorizationStateWaitPassword":
        _ = try await client.request(
          type: "checkAuthenticationPassword",
          fields: ["password": .string(try await authentication.password())]
        )
      case "authorizationStateReady":
        return
      case "authorizationStateClosing", "authorizationStateClosed", "authorizationStateLoggingOut":
        throw TelegramConnectorError.unexpectedAuthorizationState(state)
      default:
        throw TelegramConnectorError.unexpectedAuthorizationState(state)
      }
    }
  }

  public func conversations() async throws -> [MessageConversation] {
    let data = try await client.request(
      type: "getChats",
      fields: [
        "chat_list": .object(["@type": .string("chatListMain")]),
        "limit": .integer(100),
      ]
    )
    let object = try TelegramMessageMapper.jsonObject(from: data)
    let chatIDs = (object["chat_ids"] as? [Any]) ?? []

    var conversations: [MessageConversation] = []
    for rawID in chatIDs {
      let chatID = try integer(rawID, field: "chat_ids")
      let chatData = try await client.request(
        type: "getChat",
        fields: ["chat_id": .integer(chatID)]
      )
      let chat = try TelegramMessageMapper.jsonObject(from: chatData)
      conversations.append(
        MessageConversation(
          id: "telegram:\(chatID)",
          sourceID: source.id,
          title: chat["title"] as? String ?? "Chat \(chatID)"
        )
      )
    }
    return conversations
  }

  public func messages(
    in conversationID: String,
    cursor: MessageCursor?,
    limit: Int
  ) async throws -> MessagePage {
    let chatID = try parseConversationID(conversationID)
    let fromMessageID = cursor.flatMap { Int64($0.value) } ?? 0
    let boundedLimit = max(1, min(limit + (cursor == nil ? 0 : 1), 100))
    let data = try await client.request(
      type: "getChatHistory",
      fields: [
        "chat_id": .integer(chatID),
        "from_message_id": .integer(fromMessageID),
        "limit": .integer(Int64(boundedLimit)),
        "offset": .integer(0),
        "only_local": .boolean(false),
      ]
    )
    let object = try TelegramMessageMapper.jsonObject(from: data)
    let received = (object["messages"] as? [[String: Any]]) ?? []
    let rawMessages = received.filter { object in
      guard let id = try? integer(object["id"], field: "id") else { return true }
      return cursor == nil || id != fromMessageID
    }
    let messages = try rawMessages.map(TelegramMessageMapper.message(from:))
    let nextCursor = rawMessages.last.flatMap { object -> MessageCursor? in
      guard let id = try? integer(object["id"], field: "id") else { return nil }
      return MessageCursor(String(id))
    }
    return MessagePage(messages: messages, nextCursor: nextCursor)
  }

  public func message(id: String) async throws -> MessageEnvelope {
    let parts = id.split(separator: ":")
    guard
      parts.count == 3,
      parts[0] == "telegram",
      let chatID = Int64(parts[1]),
      let messageID = Int64(parts[2])
    else {
      throw TelegramConnectorError.invalidMessageID(id)
    }
    let data = try await client.request(
      type: "getMessage",
      fields: [
        "chat_id": .integer(chatID),
        "message_id": .integer(messageID),
      ]
    )
    return try TelegramMessageMapper.message(from: data)
  }

  public func updates() async -> AsyncThrowingStream<MessageUpdate, any Error> {
    let rawUpdates = await client.updates()
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await data in rawUpdates {
            let object = try TelegramMessageMapper.jsonObject(from: data)
            guard
              object["@type"] as? String == "updateNewMessage",
              let messageObject = object["message"] as? [String: Any]
            else {
              continue
            }
            continuation.yield(
              .message(try TelegramMessageMapper.message(from: messageObject))
            )
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func authorizationState(from data: Data) throws -> String {
    let object = try TelegramMessageMapper.jsonObject(from: data)
    let state = object["authorization_state"] as? [String: Any] ?? object
    guard let type = state["@type"] as? String else {
      throw TelegramConnectorError.invalidResponse("Missing authorization state")
    }
    return type
  }

  private func parseConversationID(_ id: String) throws -> Int64 {
    let parts = id.split(separator: ":")
    guard parts.count == 2, parts[0] == "telegram", let chatID = Int64(parts[1]) else {
      throw TelegramConnectorError.invalidResponse("Invalid conversation ID '\(id)'")
    }
    return chatID
  }

  private func integer(_ value: Any?, field: String) throws -> Int64 {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String, let number = Int64(string) { return number }
    throw TelegramConnectorError.invalidResponse("Missing integer field '\(field)'")
  }
}
