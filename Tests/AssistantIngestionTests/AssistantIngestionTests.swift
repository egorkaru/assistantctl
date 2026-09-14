import AssistantIngestion
import AssistantMessages
import AssistantStorage
import EmailConnector
import Foundation
import Testing

@Suite("Message ingestion")
struct AssistantIngestionTests {
  @Test("First sync stores messages and saves older-history progress")
  func syncStoresMessagesAndCursor() async throws {
    let database = try MessageDatabase.inMemory()
    let service = MessageIngestionService(database: database)

    let result = try await service.sync(connector: FixtureConnector())

    #expect(result == IngestionResult(sourceID: "fixture", conversations: 1, messages: 1))
    #expect(try await database.message(id: "fixture:1")?.text == "A meeting tomorrow")
    #expect(try await database.backfillState(sourceID: "fixture", conversationID: "fixture:inbox")?.complete == true)
  }

  @Test("Sync scans every new page and preserves older-history progress")
  func syncFindsBurst() async throws {
    let database = try MessageDatabase.inMemory()
    let connector = HistoryConnector(count: 60)
    let service = MessageIngestionService(database: database)

    let first = try await service.sync(connector: connector)
    #expect(first.messages == 25)
    #expect(try await database.backfillState(sourceID: "fixture", conversationID: "fixture:inbox")?.cursor == MessageCursor("36"))

    await connector.prepend(count: 130)
    let second = try await service.sync(connector: connector)
    #expect(second.messages == 130)
    #expect(try await database.message(id: "fixture:190") != nil)
    #expect(try await database.backfillState(sourceID: "fixture", conversationID: "fixture:inbox")?.cursor == MessageCursor("36"))
    #expect(try await service.sync(connector: connector) == IngestionResult(sourceID: "fixture", conversations: 1, messages: 0))
  }

  @Test("Gmail Inbox sync resumes after the first 25 messages")
  func gmailInboxSyncFindsBurst() async throws {
    let database = try MessageDatabase.inMemory()
    let client = GmailHistoryClient(count: 40)
    let connector = GmailMessageConnector(
      accessToken: "fixture", client: client,
      baseURL: URL(string: "https://example.test/gmail")!
    )
    let service = MessageIngestionService(database: database)

    #expect(try await service.sync(connector: connector, perConversationLimit: 10).messages == 25)
    #expect(try await database.hasMessages(sourceID: "gmail", conversationID: "gmail:inbox"))
    await client.prepend(count: 40)
    #expect(try await service.sync(connector: connector, perConversationLimit: 10).messages == 40)
    #expect(try await service.sync(connector: connector, perConversationLimit: 10).messages == 0)
  }

  @Test("Backfill resumes and reports exhaustion")
  func backfillResumes() async throws {
    let database = try MessageDatabase.inMemory()
    let connector = HistoryConnector(count: 32)
    let service = MessageIngestionService(database: database)
    _ = try await service.sync(connector: connector)

    let first = try await service.backfill(connector: connector, conversationID: "fixture:inbox", limit: 4)
    #expect(first.messages == 4)
    #expect(first.hasMore)
    let second = try await service.backfill(connector: connector, conversationID: "fixture:inbox", limit: 4)
    #expect(second.messages == 3)
    #expect(!second.hasMore)
    #expect(try await database.list(sourceID: "fixture", conversationID: nil, limit: 100).count == 32)
  }

  @Test("Interrupted sync retries remaining pages without duplicates")
  func interruptedSync() async throws {
    let database = try MessageDatabase.inMemory()
    let connector = HistoryConnector(count: 25)
    let service = MessageIngestionService(database: database)
    _ = try await service.sync(connector: connector)
    await connector.prepend(count: 130)
    await connector.failOnce(at: "56")
    do {
      _ = try await service.sync(connector: connector)
      Issue.record("Expected a page failure")
    } catch FixtureError.unsupported {}
    #expect(try await database.list(sourceID: "fixture", conversationID: nil, limit: 500).count == 25)
    #expect(try await service.sync(connector: connector).messages == 130)
    #expect(try await database.list(sourceID: "fixture", conversationID: nil, limit: 500).count == 155)
  }

  @Test("Expired backfill token recovers from oldest cached boundary")
  func expiredBackfillToken() async throws {
    let database = try MessageDatabase.inMemory()
    let connector = HistoryConnector(count: 32)
    let service = MessageIngestionService(database: database)
    _ = try await service.sync(connector: connector)
    try await database.storePage([], backfillCursor: MessageCursor("expired"), complete: false,
                                 sourceID: "fixture", conversationID: "fixture:inbox")
    let result = try await service.backfill(connector: connector,
                                            conversationID: "fixture:inbox", limit: 7)
    #expect(result.messages == 7)
    #expect(!result.hasMore)
    #expect(try await database.list(sourceID: "fixture", conversationID: nil, limit: 100).count == 32)
  }

  @Test("Telegram watch catches up and stores a burst of updates")
  func watchBurst() async throws {
    let database = try MessageDatabase.inMemory()
    try await MessageIngestionService(database: database).watch(connector: WatchConnector())
    #expect(try await database.list(sourceID: "telegram", conversationID: nil, limit: 500).count == 131)
  }

  @Test("Telegram watch keeps updates that arrive during catch-up")
  func watchDoesNotLoseCatchUpUpdates() async throws {
    let database = try MessageDatabase.inMemory()
    try await MessageIngestionService(database: database).watch(connector: WatchDuringSyncConnector())
    #expect(try await database.message(id: "telegram:chat:2") != nil)
  }

  @Test("Overlapping page boundaries count each full ID once")
  func overlappingBoundaries() async throws {
    let database = try MessageDatabase.inMemory()
    let connector = HistoryConnector(count: 32, overlap: true)
    let service = MessageIngestionService(database: database)
    #expect(try await service.sync(connector: connector, perConversationLimit: 10).messages == 25)
    await connector.prepend(count: 120)
    #expect(try await service.sync(connector: connector, perConversationLimit: 30).messages == 120)
    #expect(try await service.backfill(connector: connector, conversationID: "fixture:inbox", limit: 7).messages == 7)
    #expect(try await database.list(sourceID: "fixture", conversationID: nil, limit: 500).count == 152)
  }
}

private struct WatchConnector: MessageConnector {
  let source = MessageSource(id: "telegram", kind: .telegram, displayName: "Telegram")

  func conversations() async throws -> [MessageConversation] {
    [MessageConversation(id: "telegram:chat", sourceID: source.id, title: "Chat")]
  }

  func messages(in conversationID: String, cursor: MessageCursor?, limit: Int) async throws -> MessagePage {
    MessagePage(messages: [makeMessage(1)], nextCursor: nil)
  }

  func message(id: String) async throws -> MessageEnvelope { throw FixtureError.unsupported }

  func updates() async -> AsyncThrowingStream<MessageUpdate, any Error> {
    AsyncThrowingStream { continuation in
      for number in 2...131 { continuation.yield(.message(makeMessage(number))) }
      continuation.finish()
    }
  }

  private func makeMessage(_ number: Int) -> MessageEnvelope {
    MessageEnvelope(
      id: "telegram:\(number)", sourceID: source.id, conversationID: "telegram:chat",
      sender: MessageIdentity(id: "sender", displayName: nil),
      sentAt: Date(timeIntervalSince1970: Double(number)), receivedAt: nil,
      subject: nil, text: "Message \(number)", attachments: []
    )
  }
}

private actor WatchDuringSyncConnector: MessageConnector {
  nonisolated let source = MessageSource(id: "telegram", kind: .telegram, displayName: "Telegram")
  private var continuation: AsyncThrowingStream<MessageUpdate, any Error>.Continuation?

  func conversations() -> [MessageConversation] {
    [MessageConversation(id: "telegram:chat", sourceID: source.id, title: "Chat")]
  }

  func messages(in conversationID: String, cursor: MessageCursor?, limit: Int) -> MessagePage {
    continuation?.yield(.message(makeMessage(2)))
    continuation?.finish()
    return MessagePage(messages: [makeMessage(1)], nextCursor: nil)
  }

  func message(id: String) throws -> MessageEnvelope { throw FixtureError.unsupported }

  func updates() -> AsyncThrowingStream<MessageUpdate, any Error> {
    let (stream, continuation) = AsyncThrowingStream<MessageUpdate, any Error>.makeStream()
    self.continuation = continuation
    return stream
  }

  private func makeMessage(_ number: Int) -> MessageEnvelope {
    MessageEnvelope(
      id: "telegram:chat:\(number)", sourceID: source.id, conversationID: "telegram:chat",
      sender: MessageIdentity(id: "sender", displayName: nil),
      sentAt: Date(timeIntervalSince1970: Double(number)), receivedAt: nil,
      subject: nil, text: "Message \(number)", attachments: []
    )
  }
}

private actor HistoryConnector: MessageConnector {
  nonisolated let source = MessageSource(id: "fixture", kind: .imap, displayName: "Fixture")
  private var items: [MessageEnvelope]
  private var failureCursor: String?
  private let overlap: Bool

  init(count: Int, overlap: Bool = false) {
    items = (1...count).reversed().map(Self.makeMessage)
    self.overlap = overlap
  }

  func prepend(count: Int) {
    let highest = Int(items.first?.id.split(separator: ":").last ?? "0") ?? 0
    items.insert(contentsOf: (highest + 1...highest + count).reversed().map(Self.makeMessage), at: 0)
  }

  func failOnce(at cursor: String) { failureCursor = cursor }

  func conversations() async throws -> [MessageConversation] {
    [MessageConversation(id: "fixture:inbox", sourceID: source.id, title: "Inbox")]
  }

  func messages(in conversationID: String, cursor: MessageCursor?, limit: Int) async throws -> MessagePage {
    if cursor?.value == "expired" {
      throw EmailConnectorError.requestFailed(status: 400, body: "invalid page token")
    }
    if let failureCursor, cursor?.value == failureCursor {
      self.failureCursor = nil
      throw FixtureError.unsupported
    }
    let start = cursor.flatMap { value in
      items.firstIndex(where: { $0.id == "fixture:\(value.value)" }).map { $0 + (overlap ? 0 : 1) }
    } ?? 0
    let page = Array(items.dropFirst(start).prefix(limit + (overlap && cursor != nil ? 1 : 0)))
    let next = start + page.count < items.count
      ? page.last.map { MessageCursor(String($0.id.split(separator: ":").last ?? "")) }
      : nil
    return MessagePage(messages: page, nextCursor: next)
  }

  func message(id: String) async throws -> MessageEnvelope {
    guard let item = items.first(where: { $0.id == id }) else { throw FixtureError.unsupported }
    return item
  }

  func updates() async -> AsyncThrowingStream<MessageUpdate, any Error> {
    AsyncThrowingStream { $0.finish() }
  }

  private static func makeMessage(_ number: Int) -> MessageEnvelope {
    MessageEnvelope(
      id: "fixture:\(number)", sourceID: "fixture", conversationID: "fixture:inbox",
      sender: MessageIdentity(id: "sender", displayName: nil),
      sentAt: Date(timeIntervalSince1970: Double(number)), receivedAt: nil,
      subject: nil, text: "Message \(number)", attachments: []
    )
  }
}

private enum FixtureError: Error { case unsupported }

private actor GmailHistoryClient: HTTPDataClient {
  private var ids: [Int]

  init(count: Int) { ids = Array((1...count).reversed()) }

  func prepend(count: Int) {
    let newest = ids.first ?? 0
    ids.insert(contentsOf: (newest + 1...newest + count).reversed(), at: 0)
  }

  func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let body: String
    if url.path.hasSuffix("/messages") {
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let offset = Int(query.first { $0.name == "pageToken" }?.value ?? "0") ?? 0
      let limit = Int(query.first { $0.name == "maxResults" }?.value ?? "10") ?? 10
      let page = Array(ids.dropFirst(offset).prefix(limit))
      let messages = page.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
      let next = offset + page.count < ids.count
        ? ",\"nextPageToken\":\"\(offset + page.count)\"" : ""
      body = "{\"messages\":[\(messages)]\(next)}"
    } else {
      let id = url.lastPathComponent
      body = "{\"id\":\"\(id)\",\"internalDate\":\"1700000000000\",\"snippet\":\"Message \(id)\"}"
    }
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: nil, headerFields: nil)!)
  }
}

private struct FixtureConnector: MessageConnector {
  let source = MessageSource(id: "fixture", kind: .imap, displayName: "Fixture")

  func conversations() async throws -> [MessageConversation] {
    [MessageConversation(id: "fixture:inbox", sourceID: source.id, title: "Inbox")]
  }

  func messages(
    in conversationID: String,
    cursor: MessageCursor?,
    limit: Int
  ) async throws -> MessagePage {
    if cursor != nil { return MessagePage(messages: [], nextCursor: nil) }
    return MessagePage(
      messages: [
        MessageEnvelope(
          id: "fixture:1",
          sourceID: source.id,
          conversationID: conversationID,
          sender: MessageIdentity(id: "person@example.com", displayName: "Person"),
          sentAt: Date(timeIntervalSince1970: 1_700_000_000),
          receivedAt: nil,
          subject: "Plan",
          text: "A meeting tomorrow",
          attachments: []
        )
      ],
      nextCursor: MessageCursor("cursor-2")
    )
  }

  func message(id: String) async throws -> MessageEnvelope {
    throw FixtureError.unsupported
  }

  func updates() async -> AsyncThrowingStream<MessageUpdate, any Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
