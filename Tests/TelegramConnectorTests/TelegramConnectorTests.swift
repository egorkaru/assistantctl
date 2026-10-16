import AssistantJSON
import Foundation
@testable import TelegramConnector
import Testing

@Suite("Telegram read-only connector")
struct TelegramConnectorTests {
  @Test("Embedded Telegram app credentials load as a complete pair")
  func embeddedAppConfiguration() throws {
    let loader = TelegramAppConfigurationLoader(
      embeddedBase64: embeddedConfiguration(apiID: 123456, apiHash: "hash-value")
    )

    #expect(try loader.loadEmbedded() == TelegramAppConfiguration(apiID: 123456, apiHash: "hash-value"))
    #expect(try loader.resolve(externalAPIID: nil, externalAPIHash: nil)
            == TelegramAppConfiguration(apiID: 123456, apiHash: "hash-value"))
  }

  @Test("A build without Telegram app credentials remains valid")
  func missingEmbeddedAppConfiguration() throws {
    let loader = TelegramAppConfigurationLoader(embeddedBase64: nil)
    #expect(try loader.loadEmbedded() == nil)
    #expect(throws: TelegramAppConfigurationError.self) {
      try loader.resolve(externalAPIID: nil, externalAPIHash: nil)
    }
  }

  @Test("External Telegram app credentials override embedded values")
  func externalAppConfiguration() throws {
    let loader = TelegramAppConfigurationLoader(embeddedBase64: "invalid-base64")
    #expect(try loader.resolve(externalAPIID: "654321", externalAPIHash: "external")
            == TelegramAppConfiguration(apiID: 654321, apiHash: "external"))
  }

  @Test("Partial external credentials never mix with an embedded pair")
  func partialExternalAppConfiguration() {
    let loader = TelegramAppConfigurationLoader(
      embeddedBase64: embeddedConfiguration(apiID: 123456, apiHash: "embedded")
    )
    #expect(throws: TelegramAppConfigurationError.self) {
      try loader.resolve(externalAPIID: "654321", externalAPIHash: nil)
    }
    #expect(throws: TelegramAppConfigurationError.self) {
      try loader.resolve(externalAPIID: nil, externalAPIHash: "external")
    }
  }

  @Test("Malformed embedded Telegram data fails without exposing the hash")
  func malformedEmbeddedAppConfiguration() throws {
    let cases: [(String, String)] = [
      ("not-base64", "Base64"),
      (Data("not-json".utf8).base64EncodedString(), "JSON"),
      (embeddedConfiguration(version: 2), "version"),
      (embeddedConfiguration(apiID: 0), "apiId"),
      (Data(#"{"version":1,"apiId":1.5,"apiHash":"secret-hash"}"#.utf8)
        .base64EncodedString(), "apiId"),
      (embeddedConfiguration(apiHash: "  "), "apiHash"),
    ]

    for (encoded, expectedField) in cases {
      do {
        _ = try TelegramAppConfigurationLoader(embeddedBase64: encoded).loadEmbedded()
        Issue.record("Expected invalid embedded configuration")
      } catch {
        #expect(error.localizedDescription.contains(expectedField))
        #expect(!error.localizedDescription.contains("secret-hash"))
      }
    }
  }

  @Test("Telegram login sends the current TDLib initialization request")
  func modernAuthorizationRequest() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = StubTelegramClient()
    let connector = TelegramMessageConnector(
      configuration: TelegramConfiguration(
        apiID: 123456,
        apiHash: "test-hash",
        databaseDirectory: directory.appending(path: "database"),
        filesDirectory: directory.appending(path: "files"),
        databaseEncryptionKey: "test-key"
      ),
      client: client
    )

    try await connector.authorize(using: TelegramAuthentication(
      phoneNumber: "+10000000000",
      code: { "unused" },
      password: { "unused" }
    ))

    let parameters = try #require(await client.parameters())
    #expect(parameters["api_id"] == .integer(123456))
    #expect(parameters["database_encryption_key"] == .string("dGVzdC1rZXk="))
    #expect(parameters["parameters"] == nil)
    #expect(parameters["enable_storage_optimizer"] == nil)
    #expect(await client.requestTypes() == [
      "getAuthorizationState", "setTdlibParameters",
      "getAuthorizationState", "setAuthenticationPhoneNumber",
      "getAuthorizationState",
    ])
  }

  @Test("Telegram requires an international phone number before sending a request")
  func validatesPhoneNumber() async throws {
    for phoneNumber in ["995555000000", "+0", "+12 345", "+１２３４", "+1234567890123456"] {
      let client = StubTelegramClient()
      let connector = TelegramMessageConnector(
        configuration: TelegramConfiguration(
          apiID: 123456,
          apiHash: "test-hash",
          databaseDirectory: FileManager.default.temporaryDirectory,
          filesDirectory: FileManager.default.temporaryDirectory,
          databaseEncryptionKey: "test-key"
        ),
        client: client
      )
      await #expect(throws: TelegramConnectorError.self) {
        try await connector.authorize(using: TelegramAuthentication(
          phoneNumber: phoneNumber,
          code: { "unused" },
          password: { "unused" }
        ))
      }
      #expect(await client.requestTypes().isEmpty)
    }
  }

  @Test("Telegram login reports where TDLib sent the code")
  func reportsCodeDelivery() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = StubTelegramClient(states: [
      .object([
        "@type": .string("authorizationStateWaitCode"),
        "code_info": .object([
          "type": .object(["@type": .string("authenticationCodeTypeTelegramMessage")]),
        ]),
      ]),
      .object([
        "@type": .string("authorizationStateWaitCode"),
        "code_info": .object([
          "type": .object(["@type": .string("authenticationCodeTypeTelegramMessage")]),
        ]),
      ]),
      .object(["@type": .string("authorizationStateReady")]),
    ])
    let delivery = CodeDeliveryCapture()
    let connector = TelegramMessageConnector(
      configuration: TelegramConfiguration(
        apiID: 123456,
        apiHash: "test-hash",
        databaseDirectory: directory.appending(path: "database"),
        filesDirectory: directory.appending(path: "files"),
        databaseEncryptionKey: "test-key"
      ),
      client: client
    )

    try await connector.authorize(using: TelegramAuthentication(
      phoneNumber: "+10000000000",
      onCodeDelivery: { await delivery.record($0) },
      code: { "12345" },
      password: { "unused" }
    ))

    #expect(await delivery.value() == TelegramCodeDelivery(
      method: "another Telegram app", nextMethod: nil, timeout: 0
    ))
    #expect(await client.requestTypes() == [
      "getAuthorizationState", "setAuthenticationPhoneNumber", "getAuthorizationState",
      "checkAuthenticationCode", "getAuthorizationState",
    ])
  }

  @Test("Telegram can resend through TDLib's next offered delivery method")
  func resendsAuthenticationCode() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = StubTelegramClient(states: [
      .object([
        "@type": .string("authorizationStateWaitCode"),
        "code_info": .object([
          "type": .object(["@type": .string("authenticationCodeTypeTelegramMessage")]),
          "next_type": .object(["@type": .string("authenticationCodeTypeSms")]),
          "timeout": .integer(0),
        ]),
      ]),
      .object([
        "@type": .string("authorizationStateWaitCode"),
        "code_info": .object([
          "type": .object(["@type": .string("authenticationCodeTypeTelegramMessage")]),
          "next_type": .object(["@type": .string("authenticationCodeTypeSms")]),
          "timeout": .integer(0),
        ]),
      ]),
      .object([
        "@type": .string("authorizationStateWaitCode"),
        "code_info": .object([
          "type": .object(["@type": .string("authenticationCodeTypeSms")]),
        ]),
      ]),
      .object(["@type": .string("authorizationStateReady")]),
    ])
    let delivery = CodeDeliveryCapture()
    let input = CodeInputCapture(["/resend", "12345"])
    let connector = TelegramMessageConnector(
      configuration: TelegramConfiguration(
        apiID: 123456,
        apiHash: "test-hash",
        databaseDirectory: directory.appending(path: "database"),
        filesDirectory: directory.appending(path: "files"),
        databaseEncryptionKey: "test-key"
      ),
      client: client
    )

    try await connector.authorize(using: TelegramAuthentication(
      phoneNumber: "+10000000000",
      onCodeDelivery: { await delivery.record($0) },
      code: { await input.next() },
      password: { "unused" }
    ))

    #expect(await delivery.value() == TelegramCodeDelivery(
      method: "SMS", nextMethod: nil, timeout: 0
    ))
    #expect(await client.requestTypes() == [
      "getAuthorizationState", "setAuthenticationPhoneNumber", "getAuthorizationState",
      "resendAuthenticationCode", "getAuthorizationState",
      "checkAuthenticationCode", "getAuthorizationState",
    ])
  }

  @Test("An existing authorized session does not request a new code")
  func alreadyAuthorized() async throws {
    let client = StubTelegramClient(states: [.object(["@type": .string("authorizationStateReady")])])
    let connector = TelegramMessageConnector(configuration: testConfiguration(), client: client)

    try await connector.authorize(using: TelegramAuthentication(
      phoneNumber: "", code: { "unused" }, password: { "unused" }
    ))

    #expect(await client.requestTypes() == ["getAuthorizationState"])
  }

  @Test("A failed fresh request never prompts for an old code")
  func failedFreshCodeRequest() async throws {
    let client = StubTelegramClient(
      states: [.object(["@type": .string("authorizationStateWaitCode")])],
      phoneRequestError: .tdlib(code: 429, message: "FLOOD_WAIT")
    )
    let connector = TelegramMessageConnector(configuration: testConfiguration(), client: client)
    let input = CodeInputCapture(["unused"])

    await #expect(throws: TelegramConnectorError.self) {
      try await connector.authorize(using: TelegramAuthentication(
        phoneNumber: "+10000000000", code: { await input.next() }, password: { "unused" }
      ))
    }
    #expect(await client.requestTypes() == ["getAuthorizationState", "setAuthenticationPhoneNumber"])
    #expect(await input.remaining() == 1)
  }

  @Test("Read commands never request a login code")
  func requiresExistingAuthorization() async throws {
    let pending = StubTelegramClient(states: [.object(["@type": .string("authorizationStateWaitCode")])])
    let connector = TelegramMessageConnector(configuration: testConfiguration(), client: pending)

    await #expect(throws: TelegramConnectorError.self) {
      try await connector.requireAuthorization()
    }
    #expect(await pending.requestTypes() == ["getAuthorizationState"])

    let ready = StubTelegramClient(states: [.object(["@type": .string("authorizationStateReady")])])
    try await TelegramMessageConnector(configuration: testConfiguration(), client: ready)
      .requireAuthorization()
    #expect(await ready.requestTypes() == ["getAuthorizationState"])
  }

  @Test("QR login shows refreshed links and completes after 2FA")
  func qrAuthorization() async throws {
    let first = "tg://login?token=first"
    let second = "tg://login?token=second"
    let client = StubTelegramClient(
      states: [
        .object(["@type": .string("authorizationStateWaitPhoneNumber")]),
      ],
      updateValues: [
        qrUpdate(first), qrUpdate(second),
        qrUpdateState("authorizationStateWaitPassword"),
        qrUpdateState("authorizationStateReady"),
      ]
    )
    let links = QRLinkCapture()
    let passwords = CodeInputCapture(["password"])
    let connector = TelegramMessageConnector(configuration: testConfiguration(), client: client)

    try await connector.authorizeWithQRCode(
      onLink: { await links.record($0) },
      password: { await passwords.next() }
    )

    #expect(await links.values() == [first, second])
    #expect(await passwords.remaining() == 0)
    #expect(await client.requestTypes() == [
      "getAuthorizationState", "requestQrCodeAuthentication", "checkAuthenticationPassword",
    ])
  }

  @Test("QR login skips a session that is already authorized")
  func qrAlreadyAuthorized() async throws {
    let client = StubTelegramClient(states: [.object(["@type": .string("authorizationStateReady")])])
    let connector = TelegramMessageConnector(configuration: testConfiguration(), client: client)

    try await connector.authorizeWithQRCode(onLink: { _ in }, password: { "unused" })

    #expect(await client.requestTypes() == ["getAuthorizationState"])
  }

  @Test("TDLib request IDs retain 64-bit integer precision")
  func largeRequestIDIsExact() throws {
    let request: JSONValue = ["chat_id": .integer(9_007_199_254_740_993)]
    let data = try JSONEncoder().encode(request)

    #expect(String(decoding: data, as: UTF8.self).contains("9007199254740993"))
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == request)
  }

  @Test("TDLib database encryption key is encoded as bytes")
  func databaseEncryptionKeyUsesBase64() {
    let configuration = TelegramConfiguration(
      apiID: 1,
      apiHash: "hash",
      databaseDirectory: URL(fileURLWithPath: "/tmp/database"),
      filesDirectory: URL(fileURLWithPath: "/tmp/files"),
      databaseEncryptionKey: "key+/é"
    )

    #expect(configuration.encodedDatabaseEncryptionKey == "a2V5Ky/DqQ==")
  }

  @Test("Request policy allows reads and rejects message mutation")
  func requestPolicyAllowsReadsAndRejectsMessageMutation() {
    #expect(TelegramRequestPolicy.isAllowed("getChats"))
    #expect(TelegramRequestPolicy.isAllowed("getChatHistory"))
    #expect(TelegramRequestPolicy.isAllowed("getMessage"))
    #expect(!TelegramRequestPolicy.isAllowed("sendMessage"))
    #expect(!TelegramRequestPolicy.isAllowed("deleteMessages"))
    #expect(!TelegramRequestPolicy.isAllowed("editMessageText"))
  }

  @Test("Maps a TDLib text message into a normalized envelope")
  func mapsTDLibTextMessageIntoNormalizedEnvelope() throws {
    let data = Data(
      """
      {
        "@type": "message",
        "id": 99,
        "chat_id": -100123,
        "date": 1700000000,
        "sender_id": {
          "@type": "messageSenderUser",
          "user_id": 42
        },
        "content": {
          "@type": "messageText",
          "text": {
            "@type": "formattedText",
            "text": "Dinner Friday at 8",
            "entities": []
          }
        }
      }
      """.utf8
    )

    let message = try TelegramMessageMapper.message(from: data)

    #expect(message.id == "telegram:-100123:99")
    #expect(message.sourceID == "telegram")
    #expect(message.conversationID == "telegram:-100123")
    #expect(message.sender.id == "telegram-user:42")
    #expect(message.text == "Dinner Friday at 8")
    #expect(message.sentAt == Date(timeIntervalSince1970: 1_700_000_000))
  }
}

private actor StubTelegramClient: TelegramClient {
  private var states: [JSONValue]
  private let phoneRequestError: TelegramConnectorError?
  private let updateValues: [JSONValue]
  private var types: [String] = []
  private var initializationParameters: [String: JSONValue]?

  init(states: [JSONValue] = [
    .object(["@type": .string("authorizationStateWaitTdlibParameters")]),
    .object(["@type": .string("authorizationStateWaitPhoneNumber")]),
    .object(["@type": .string("authorizationStateReady")]),
  ], phoneRequestError: TelegramConnectorError? = nil, updateValues: [JSONValue] = []) {
    self.states = states
    self.phoneRequestError = phoneRequestError
    self.updateValues = updateValues
  }

  func request(type: String, fields: [String: JSONValue]) async throws -> Data {
    types.append(type)
    if type == "getAuthorizationState" {
      return try JSONEncoder().encode(states.removeFirst())
    }
    if type == "setTdlibParameters" {
      initializationParameters = fields
    }
    if type == "setAuthenticationPhoneNumber", let phoneRequestError {
      throw phoneRequestError
    }
    return Data(#"{"@type":"ok"}"#.utf8)
  }

  func updates() async -> AsyncThrowingStream<Data, any Error> {
    let values = updateValues
    return AsyncThrowingStream { continuation in
      for value in values {
        if let data = try? JSONEncoder().encode(value) { continuation.yield(data) }
      }
      continuation.finish()
    }
  }

  func close() async {}

  func parameters() -> [String: JSONValue]? { initializationParameters }
  func requestTypes() -> [String] { types }
}

private actor CodeDeliveryCapture {
  private var delivery: TelegramCodeDelivery?

  func record(_ value: TelegramCodeDelivery) { delivery = value }
  func value() -> TelegramCodeDelivery? { delivery }
}

private actor CodeInputCapture {
  private var inputs: [String]

  init(_ inputs: [String]) { self.inputs = inputs }
  func next() -> String { inputs.removeFirst() }
  func remaining() -> Int { inputs.count }
}

private actor QRLinkCapture {
  private var links: [String] = []

  func record(_ link: String) { links.append(link) }
  func values() -> [String] { links }
}

private func qrState(_ link: String) -> JSONValue {
  .object([
    "@type": .string("authorizationStateWaitOtherDeviceConfirmation"),
    "link": .string(link),
  ])
}

private func qrUpdate(_ link: String) -> JSONValue {
  .object([
    "@type": .string("updateAuthorizationState"),
    "authorization_state": qrState(link),
  ])
}

private func qrUpdateState(_ type: String) -> JSONValue {
  .object([
    "@type": .string("updateAuthorizationState"),
    "authorization_state": .object(["@type": .string(type)]),
  ])
}

private func testConfiguration() -> TelegramConfiguration {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  return TelegramConfiguration(
    apiID: 123456, apiHash: "test-hash",
    databaseDirectory: directory.appending(path: "database"),
    filesDirectory: directory.appending(path: "files"),
    databaseEncryptionKey: "test-key"
  )
}

private func embeddedConfiguration(
  version: Int = 1,
  apiID: Int = 123456,
  apiHash: String = "secret-hash"
) -> String {
  Data(
    #"{"version":\#(version),"apiId":\#(apiID),"apiHash":"\#(apiHash)"}"#.utf8
  ).base64EncodedString()
}
