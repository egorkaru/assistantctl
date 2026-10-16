import AssistantJSON
import AssistantMessages
import Foundation

public enum TelegramConnectorError: Error, LocalizedError, Sendable {
  case invalidResponse(String)
  case invalidPhoneNumber
  case missingPhoneNumber
  case authorizationRequired
  case requestBlocked(String)
  case resendUnavailable
  case tdlib(code: Int, message: String)
  case unexpectedAuthorizationState(String)
  case invalidMessageID(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let message): message
    case .invalidPhoneNumber: "Telegram phone number must be + followed by 2–15 ASCII digits, starting with a nonzero country code"
    case .missingPhoneNumber: "Telegram phone number is required; pass --phone or set ASSISTANTCTL_TELEGRAM_PHONE"
    case .authorizationRequired: "Telegram is not authorized; run assistantctl telegram login"
    case .requestBlocked(let type): "TDLib request '\(type)' is blocked by read-only policy"
    case .resendUnavailable: "Telegram has not offered another code delivery method"
    case .tdlib(let code, let message): "TDLib \(code): \(message)"
    case .unexpectedAuthorizationState(let state):
      "Unsupported Telegram authorization state: \(state)"
    case .invalidMessageID(let id): "Invalid Telegram message ID: \(id)"
    }
  }
}

public struct TelegramCodeDelivery: Sendable, Equatable {
  public let method: String
  public let nextMethod: String?
  public let timeout: Int

  public init(method: String, nextMethod: String?, timeout: Int) {
    self.method = method
    self.nextMethod = nextMethod
    self.timeout = timeout
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

  var encodedDatabaseEncryptionKey: String {
    Data(databaseEncryptionKey.utf8).base64EncodedString()
  }
}

public struct TelegramAuthentication: Sendable {
  public let phoneNumber: String
  public let onCodeDelivery: @Sendable (TelegramCodeDelivery) async -> Void
  public let code: @Sendable () async throws -> String
  public let password: @Sendable () async throws -> String

  public init(
    phoneNumber: String,
    onCodeDelivery: @escaping @Sendable (TelegramCodeDelivery) async -> Void = { _ in },
    code: @escaping @Sendable () async throws -> String,
    password: @escaping @Sendable () async throws -> String
  ) {
    self.phoneNumber = phoneNumber
    self.onCodeDelivery = onCodeDelivery
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
  private let client: any TelegramClient

  public init(configuration: TelegramConfiguration) {
    self.configuration = configuration
    client = TDLibJSONClient()
  }

  init(configuration: TelegramConfiguration, client: any TelegramClient) {
    self.configuration = configuration
    self.client = client
  }

  public func authorize(using authentication: TelegramAuthentication) async throws {
    let phoneNumber = authentication.phoneNumber
    let digits = phoneNumber.dropFirst()
    guard phoneNumber.isEmpty || (phoneNumber.first == "+" && (2...15).contains(digits.count)
          && digits.first != "0" && digits.utf8.allSatisfy({ (48...57).contains($0) }))
    else { throw TelegramConnectorError.invalidPhoneNumber }

    try prepareDirectories()

    do {
      try await authorizeStateMachine(using: authentication)
    } catch {
      await client.close()
      throw error
    }
  }

  public func requireAuthorization() async throws {
    try prepareDirectories()
    do {
      while true {
        let state = try authorizationState(from: await client.request(type: "getAuthorizationState"))
        switch state {
        case "authorizationStateWaitTdlibParameters":
          try await setTdlibParameters()
        case "authorizationStateReady":
          return
        default:
          throw TelegramConnectorError.authorizationRequired
        }
      }
    } catch {
      await client.close()
      throw error
    }
  }

  public func authorizeWithQRCode(
    onLink: @escaping @Sendable (String) async throws -> Void,
    password: @escaping @Sendable () async throws -> String
  ) async throws {
    try prepareDirectories()
    do {
      while true {
        let state = try authorizationState(from: await client.request(type: "getAuthorizationState"))
        switch state {
        case "authorizationStateWaitTdlibParameters":
          try await setTdlibParameters()
        case "authorizationStateReady":
          return
        default:
          let updates = await client.updates()
          _ = try await client.request(
            type: "requestQrCodeAuthentication",
            fields: ["other_user_ids": .array([])]
          )
          var lastLink: String?
          var passwordSubmitted = false
          for try await update in updates {
            guard let object = try? TelegramMessageMapper.jsonObject(from: update),
                  object["@type"] as? String == "updateAuthorizationState"
            else { continue }
            if try authorizationState(from: update) == "authorizationStateReady" { return }
            try await handleQRState(
              update, lastLink: &lastLink, passwordSubmitted: &passwordSubmitted,
              onLink: onLink, password: password
            )
          }
          throw TelegramConnectorError.invalidResponse("TDLib stopped sending QR authorization updates")
        }
      }
    } catch {
      await client.close()
      throw error
    }
  }

  private func handleQRState(
    _ data: Data,
    lastLink: inout String?,
    passwordSubmitted: inout Bool,
    onLink: @Sendable (String) async throws -> Void,
    password: @Sendable () async throws -> String
  ) async throws {
    let state = try authorizationState(from: data)
    if state == "authorizationStateWaitOtherDeviceConfirmation" {
      let object = try TelegramMessageMapper.jsonObject(from: data)
      let details = object["authorization_state"] as? [String: Any] ?? object
      guard let link = details["link"] as? String, link.hasPrefix("tg://login?token=") else {
        throw TelegramConnectorError.invalidResponse("TDLib returned an invalid QR login link")
      }
      if link != lastLink {
        lastLink = link
        try await onLink(link)
      }
    } else if state == "authorizationStateWaitPassword" && !passwordSubmitted {
      passwordSubmitted = true
      _ = try await client.request(
        type: "checkAuthenticationPassword",
        fields: ["password": .string(try await password())]
      )
    } else if state == "authorizationStateClosing" || state == "authorizationStateClosed" {
      throw TelegramConnectorError.unexpectedAuthorizationState(state)
    }
  }

  public func close() async {
    await client.close()
  }

  private func authorizeStateMachine(using authentication: TelegramAuthentication) async throws {
    var requestedCode = false
    while true {
      let stateData = try await client.request(type: "getAuthorizationState")
      let state = try authorizationState(from: stateData)

      switch state {
      case "authorizationStateWaitTdlibParameters":
        try await setTdlibParameters()
      case "authorizationStateWaitPhoneNumber":
        guard !requestedCode else {
          throw TelegramConnectorError.invalidResponse("TDLib did not advance after requesting a Telegram code")
        }
        requestedCode = true
        try await requestAuthenticationCode(for: authentication.phoneNumber)
      case "authorizationStateWaitCode":
        if !requestedCode {
          requestedCode = true
          try await requestAuthenticationCode(for: authentication.phoneNumber)
          continue
        }
        let delivery = codeDelivery(from: stateData)
        let receivedAt = ContinuousClock.now
        await authentication.onCodeDelivery(delivery)
        let input = try await authentication.code()
        if input == "/resend" {
          guard delivery.nextMethod != nil else {
            throw TelegramConnectorError.resendUnavailable
          }
          let remaining = Duration.seconds(delivery.timeout) - receivedAt.duration(to: .now)
          if remaining > .zero { try await Task.sleep(for: remaining) }
          _ = try await client.request(
            type: "resendAuthenticationCode",
            fields: ["reason": .null]
          )
          continue
        }
        _ = try await client.request(
          type: "checkAuthenticationCode",
          fields: ["code": .string(input)]
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

  private func prepareDirectories() throws {
    try FileManager.default.createDirectory(
      at: configuration.databaseDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: configuration.filesDirectory,
      withIntermediateDirectories: true
    )
  }

  private func setTdlibParameters() async throws {
    _ = try await client.request(
      type: "setTdlibParameters",
      fields: [
        "api_hash": .string(configuration.apiHash),
        "api_id": .integer(Int64(configuration.apiID)),
        "application_version": .string(AssistantVersion.current),
        "database_directory": .string(configuration.databaseDirectory.path),
        "database_encryption_key": .string(configuration.encodedDatabaseEncryptionKey),
        "device_model": .string("Mac"),
        "files_directory": .string(configuration.filesDirectory.path),
        "system_language_code": .string("en"),
        "system_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
        "use_chat_info_database": .boolean(true),
        "use_file_database": .boolean(true),
        "use_message_database": .boolean(true),
        "use_secret_chats": .boolean(false),
        "use_test_dc": .boolean(false),
      ]
    )
  }

  private func requestAuthenticationCode(for phoneNumber: String) async throws {
    guard !phoneNumber.isEmpty else { throw TelegramConnectorError.missingPhoneNumber }
    _ = try await client.request(
      type: "setAuthenticationPhoneNumber",
      fields: [
        "phone_number": .string(phoneNumber),
        "settings": .object([
          "@type": .string("phoneNumberAuthenticationSettings"),
          "allow_flash_call": .boolean(false),
          "allow_missed_call": .boolean(false),
          "allow_sms_retriever_api": .boolean(false),
          "authentication_tokens": .array([]),
          "firebase_authentication_settings": .null,
          "has_unknown_phone_number": .boolean(false),
          "is_current_phone_number": .boolean(false),
        ]),
      ]
    )
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

  private func codeDelivery(from data: Data) -> TelegramCodeDelivery {
    guard let object = try? TelegramMessageMapper.jsonObject(from: data) else {
      return TelegramCodeDelivery(method: "an unspecified channel", nextMethod: nil, timeout: 0)
    }
    let state = object["authorization_state"] as? [String: Any] ?? object
    guard let info = state["code_info"] as? [String: Any] else {
      return TelegramCodeDelivery(method: "an unspecified channel", nextMethod: nil, timeout: 0)
    }
    let type = (info["type"] as? [String: Any])?["@type"] as? String
    let nextType = (info["next_type"] as? [String: Any])?["@type"] as? String
    return TelegramCodeDelivery(
      method: codeDeliveryName(type),
      nextMethod: nextType.map(codeDeliveryName),
      timeout: max(0, (info["timeout"] as? NSNumber)?.intValue ?? 0)
    )
  }

  private func codeDeliveryName(_ type: String?) -> String {
    switch type {
    case "authenticationCodeTypeTelegramMessage": "another Telegram app"
    case "authenticationCodeTypeSms", "authenticationCodeTypeSmsWord",
         "authenticationCodeTypeSmsPhrase": "SMS"
    case "authenticationCodeTypeCall": "a phone call"
    case "authenticationCodeTypeFlashCall": "a flash call"
    case "authenticationCodeTypeMissedCall": "a missed call"
    case "authenticationCodeTypeFragment": "Fragment"
    case "authenticationCodeTypeFirebaseAndroid", "authenticationCodeTypeFirebaseIos":
      "the Telegram mobile app"
    default: "an unspecified channel"
    }
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
