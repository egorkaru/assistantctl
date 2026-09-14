import AssistantJSON
import Foundation
import TelegramConnector
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

  @Test("TDLib request IDs retain 64-bit integer precision")
  func largeRequestIDIsExact() throws {
    let request: JSONValue = ["chat_id": .integer(9_007_199_254_740_993)]
    let data = try JSONEncoder().encode(request)

    #expect(String(decoding: data, as: UTF8.self).contains("9007199254740993"))
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == request)
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

private func embeddedConfiguration(
  version: Int = 1,
  apiID: Int = 123456,
  apiHash: String = "secret-hash"
) -> String {
  Data(
    #"{"version":\#(version),"apiId":\#(apiID),"apiHash":"\#(apiHash)"}"#.utf8
  ).base64EncodedString()
}
