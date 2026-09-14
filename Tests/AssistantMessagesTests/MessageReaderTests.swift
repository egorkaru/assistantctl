import AssistantMessages
import AssistantStorage
import Foundation
import GRDB
import Testing

@Suite("Read-only message pipeline")
struct MessageReaderTests {
  @Test("Message envelope round-trips through JSON")
  func messageEnvelopeRoundTripsThroughJSON() throws {
    let message = MessageEnvelope(
      id: "telegram:42",
      sourceID: "telegram",
      conversationID: "chat:7",
      sender: MessageIdentity(id: "user:1", displayName: "Alice"),
      sentAt: Date(timeIntervalSince1970: 1_700_000_000),
      receivedAt: nil,
      subject: nil,
      text: "Meet tomorrow at 10",
      attachments: []
    )

    let encoded = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: encoded)

    #expect(decoded == message)
  }

  @Test("Database upsert deduplicates by stable message ID")
  func databaseUpsertDeduplicatesByStableMessageID() async throws {
    let database = try MessageDatabase.inMemory()
    let first = makeMessage(text: "first")
    let updated = makeMessage(text: "updated")

    try await database.upsert(first)
    try await database.upsert(updated)

    let messages = try await database.list(
      sourceID: "telegram",
      conversationID: nil,
      limit: 50
    )
    #expect(messages.count == 1)
    #expect(messages.first?.text == "updated")
  }

  @Test("Database search returns matching message text")
  func databaseSearchReturnsMatchingMessageText() async throws {
    let database = try MessageDatabase.inMemory()
    try await database.upsert(makeMessage(text: "Dinner on Friday"))
    try await database.upsert(
      MessageEnvelope(
        id: "telegram:43",
        sourceID: "telegram",
        conversationID: "chat:8",
        sender: MessageIdentity(id: "user:2", displayName: "Bob"),
        sentAt: Date(timeIntervalSince1970: 1_700_000_001),
        receivedAt: nil,
        subject: nil,
        text: "Unrelated",
        attachments: []
      )
    )

    let matches = try await database.search(query: "Friday", limit: 20)

    #expect(matches.map(\.id) == ["telegram:42"])
  }

  @Test("Existing email messages move into their Inbox conversation")
  func migratesEmailConversationIDs() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "assistantctl-migration-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let database = try MessageDatabase(path: path)
    let oldMessage = MessageEnvelope(
      id: "gmail:message-1", sourceID: "gmail", conversationID: "gmail:thread-1",
      sender: MessageIdentity(id: "sender@example.com", displayName: nil),
      sentAt: Date(timeIntervalSince1970: 1_700_000_000), receivedAt: nil,
      subject: "Message", text: "Body", attachments: []
    )
    try await database.upsert(oldMessage)

    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'email-inbox-v1'")
    }
    let reopened = try MessageDatabase(path: path)

    #expect(try await reopened.message(id: oldMessage.id)?.conversationID == "gmail:inbox")
    #expect(try await reopened.list(sourceID: "gmail", conversationID: "gmail:inbox", limit: 10).count == 1)
  }

  private func makeMessage(text: String) -> MessageEnvelope {
    MessageEnvelope(
      id: "telegram:42",
      sourceID: "telegram",
      conversationID: "chat:7",
      sender: MessageIdentity(id: "user:1", displayName: "Alice"),
      sentAt: Date(timeIntervalSince1970: 1_700_000_000),
      receivedAt: nil,
      subject: nil,
      text: text,
      attachments: []
    )
  }
}
