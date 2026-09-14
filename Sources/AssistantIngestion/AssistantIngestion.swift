import AssistantMessages
import AssistantStorage
import EmailConnector
import Foundation

public struct ApplicationPaths: Sendable {
  public let root: URL
  public let messagesDatabase: URL
  public let telegramDatabase: URL
  public let telegramFiles: URL

  public init(root: URL) {
    self.root = root
    messagesDatabase = root.appending(path: "messages.sqlite")
    telegramDatabase = root.appending(path: "telegram/database", directoryHint: .isDirectory)
    telegramFiles = root.appending(path: "telegram/files", directoryHint: .isDirectory)
  }

  public static var standard: ApplicationPaths {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return ApplicationPaths(root: support.appending(path: "AssistantCtl", directoryHint: .isDirectory))
  }

  public func prepare() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
}

public struct IngestionResult: Codable, Equatable, Sendable {
  public let sourceID: String
  public let conversations: Int
  public let messages: Int

  public init(sourceID: String, conversations: Int, messages: Int) {
    self.sourceID = sourceID
    self.conversations = conversations
    self.messages = messages
  }
}

public struct BackfillResult: Codable, Equatable, Sendable {
  public let sourceID: String
  public let conversationID: String
  public let messages: Int
  public let hasMore: Bool
}

public enum IngestionError: Error, LocalizedError {
  case invalidLimit
  case noProgress
  case missingBoundary
  case conversationNotFound

  public var errorDescription: String? {
    switch self {
    case .invalidLimit: "Limit must be positive; sync page size must be at most 100"
    case .noProgress: "Provider pagination did not advance"
    case .missingBoundary: "Could not recover the saved history position"
    case .conversationNotFound: "Conversation was not found"
    }
  }
}

public actor MessageIngestionService {
  private let database: MessageDatabase

  public init(database: MessageDatabase) {
    self.database = database
  }

  public func sync(
    connector: any MessageConnector,
    perConversationLimit: Int = 100
  ) async throws -> IngestionResult {
    guard (1...100).contains(perConversationLimit) else { throw IngestionError.invalidLimit }
    let conversations = try await connector.conversations()
    var imported = 0
    for conversation in conversations {
      imported += try await syncConversation(
        connector: connector,
        conversationID: conversation.id,
        pageSize: perConversationLimit
      )
    }
    return IngestionResult(
      sourceID: connector.source.id,
      conversations: conversations.count,
      messages: imported
    )
  }

  private func syncConversation(
    connector: any MessageConnector,
    conversationID: String,
    pageSize: Int
  ) async throws -> Int {
    let sourceID = connector.source.id
    let initial = try await !database.hasMessages(sourceID: sourceID, conversationID: conversationID)
    var cursor: MessageCursor?
    var pending: [MessageEnvelope] = []
    var pendingIDs = Set<String>()
    var seenCursors = Set<String>()

    while true {
      let requestLimit = initial ? min(pageSize, 25 - pending.count) : pageSize
      let page = try await connector.messages(
        in: conversationID, cursor: cursor, limit: requestLimit
      )
      let priorCursor = cursor
      var fresh: [MessageEnvelope] = []
      var reachedCached = false
      for message in page.messages {
        if try await database.containsMessage(id: message.id) {
          reachedCached = true
          break
        }
        if pendingIDs.insert(message.id).inserted { fresh.append(message) }
      }
      pending.append(contentsOf: fresh)

      if reachedCached || page.nextCursor == nil || (initial && pending.count >= 25) {
        if initial {
          try await database.storePage(
            pending,
            backfillCursor: page.nextCursor,
            complete: page.nextCursor == nil,
            sourceID: sourceID,
            conversationID: conversationID
          )
        } else {
          try await database.storeMessages(pending)
        }
        return pending.count
      }
      guard let next = page.nextCursor,
            next != priorCursor,
            seenCursors.insert(next.value).inserted else {
        throw IngestionError.noProgress
      }
      cursor = next
    }
  }

  public func backfill(
    connector: any MessageConnector,
    conversationID: String,
    limit: Int
  ) async throws -> BackfillResult {
    guard limit > 0 else { throw IngestionError.invalidLimit }
    let sourceID = connector.source.id
    let conversations = try await connector.conversations()
    guard conversations.contains(where: { $0.id == conversationID }) else {
      throw IngestionError.conversationNotFound
    }
    if try await !database.hasMessages(sourceID: sourceID, conversationID: conversationID) {
      _ = try await syncConversation(connector: connector, conversationID: conversationID, pageSize: 25)
      if try await !database.hasMessages(sourceID: sourceID, conversationID: conversationID) {
        return BackfillResult(sourceID: sourceID, conversationID: conversationID,
                              messages: 0, hasMore: false)
      }
    }
    var state = try await database.backfillState(sourceID: sourceID, conversationID: conversationID)
    if state?.complete == true {
      return BackfillResult(sourceID: sourceID, conversationID: conversationID,
                            messages: 0, hasMore: false)
    }
    if state == nil {
      let boundary = try await database.oldestMessageID(sourceID: sourceID, conversationID: conversationID)
      state = try await recoverBackfillState(connector: connector, conversationID: conversationID,
                                            boundaryID: boundary)
    }
    var cursor = state?.cursor
    var imported = 0
    var seenCursors = Set<String>()
    while imported < limit, cursor != nil {
      let remaining = limit - imported
      let requestLimit = min(100, remaining)
      let page: MessagePage
      do {
        page = try await connector.messages(in: conversationID, cursor: cursor,
                                            limit: requestLimit)
      } catch let error as EmailConnectorError where error.isInvalidPageToken {
        let boundary = try await database.oldestMessageID(sourceID: sourceID,
                                                    conversationID: conversationID)
        let recovered = try await recoverBackfillState(
          connector: connector, conversationID: conversationID, boundaryID: boundary
        )
        guard recovered.cursor != cursor else { throw error }
        cursor = recovered.cursor
        if recovered.complete { break }
        continue
      }
      var fresh: [MessageEnvelope] = []
      var pageIDs = Set<String>()
      for message in page.messages where (try await !database.containsMessage(id: message.id)) {
        if pageIDs.insert(message.id).inserted { fresh.append(message) }
      }
      let selected = Array(fresh.prefix(remaining))
      var next = page.nextCursor
      if fresh.count > remaining, let last = selected.last, sourceID == "telegram" {
        next = MessageCursor(String(last.id.split(separator: ":").last ?? ""))
      }
      if selected.isEmpty && next == cursor { throw IngestionError.noProgress }
      try await database.storePage(selected, backfillCursor: next, complete: next == nil,
                             sourceID: sourceID, conversationID: conversationID)
      imported += selected.count
      if next == nil { break }
      guard let next, seenCursors.insert(next.value).inserted else {
        throw IngestionError.noProgress
      }
      cursor = next
    }
    let final = try await database.backfillState(sourceID: sourceID, conversationID: conversationID)
    return BackfillResult(sourceID: sourceID, conversationID: conversationID,
                          messages: imported, hasMore: final?.complete == false)
  }

  private func recoverBackfillState(
    connector: any MessageConnector,
    conversationID: String,
    boundaryID: String?
  ) async throws -> MessageDatabase.BackfillState {
    guard let boundaryID else { throw IngestionError.missingBoundary }
    if connector.source.kind == .telegram {
      guard let messageID = boundaryID.split(separator: ":").last else {
        throw IngestionError.missingBoundary
      }
      let state = MessageDatabase.BackfillState(
        cursor: MessageCursor(String(messageID)), complete: false
      )
      try await database.storePage([], backfillCursor: state.cursor, complete: false,
                                   sourceID: connector.source.id, conversationID: conversationID)
      return state
    }
    var cursor: MessageCursor?
    var seen = Set<String>()
    while true {
      try Task.checkCancellation()
      let page = try await connector.messages(in: conversationID, cursor: cursor, limit: 1)
      if page.messages.contains(where: { $0.id == boundaryID }) {
        let state = MessageDatabase.BackfillState(
          cursor: page.nextCursor, complete: page.nextCursor == nil
        )
        try await database.storePage([], backfillCursor: state.cursor, complete: state.complete,
                               sourceID: connector.source.id, conversationID: conversationID)
        return state
      }
      guard let next = page.nextCursor, seen.insert(next.value).inserted else {
        throw IngestionError.missingBoundary
      }
      cursor = next
    }
  }

  public func watch(connector: any MessageConnector) async throws {
    if connector.source.kind == .gmail || connector.source.kind == .microsoft {
      _ = try await sync(connector: connector)
      while !Task.isCancelled {
        try await Task.sleep(for: .seconds(30))
        _ = try await sync(connector: connector)
      }
      return
    }
    let updates = await connector.updates()
    _ = try await sync(connector: connector)
    for try await update in updates {
      guard case .message(let message) = update else { continue }
      try await database.upsert(message)
    }
  }
}
