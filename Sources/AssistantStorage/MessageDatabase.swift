import AssistantMessages
import Foundation
import GRDB

public actor MessageDatabase {
  private let database: DatabaseQueue
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public static func inMemory() throws -> MessageDatabase {
    try MessageDatabase(database: DatabaseQueue())
  }

  public init(path: String) throws {
    try self.init(database: DatabaseQueue(path: path))
  }

  private init(database: DatabaseQueue) throws {
    self.database = database
    encoder = JSONEncoder()
    decoder = JSONDecoder()
    try Self.migrator.migrate(database)
  }

  public func upsert(_ message: MessageEnvelope) throws {
    let payload = try encoder.encode(message)
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages (
            id, source_id, conversation_id, sent_at, subject, body, payload
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            conversation_id = excluded.conversation_id,
            sent_at = excluded.sent_at,
            subject = excluded.subject,
            body = excluded.body,
            payload = excluded.payload
          """,
        arguments: [
          message.id,
          message.sourceID,
          message.conversationID,
          message.sentAt.timeIntervalSince1970,
          message.subject,
          message.text,
          payload,
        ]
      )
    }
  }

  public func message(id: String) throws -> MessageEnvelope? {
    try database.read { db in
      guard
        let payload = try Data.fetchOne(
          db,
          sql: "SELECT payload FROM messages WHERE id = ?",
          arguments: [id]
        )
      else {
        return nil
      }
      return try decoder.decode(MessageEnvelope.self, from: payload)
    }
  }

  public func list(
    sourceID: String?,
    conversationID: String?,
    limit: Int
  ) throws -> [MessageEnvelope] {
    let boundedLimit = max(1, min(limit, 500))
    var conditions: [String] = []
    var arguments: StatementArguments = []

    if let sourceID {
      conditions.append("source_id = ?")
      arguments += [sourceID]
    }
    if let conversationID {
      conditions.append("conversation_id = ?")
      arguments += [conversationID]
    }

    let whereClause =
      conditions.isEmpty
      ? ""
      : " WHERE " + conditions.joined(separator: " AND ")
    arguments += [boundedLimit]

    return try database.read { db in
      let payloads = try Data.fetchAll(
        db,
        sql: "SELECT payload FROM messages\(whereClause) ORDER BY sent_at DESC LIMIT ?",
        arguments: arguments
      )
      return try payloads.map {
        try decoder.decode(MessageEnvelope.self, from: $0)
      }
    }
  }

  public func search(query: String, limit: Int) throws -> [MessageEnvelope] {
    let boundedLimit = max(1, min(limit, 500))
    let escapedQuery =
      query
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")

    return try database.read { db in
      let payloads = try Data.fetchAll(
        db,
        sql: """
          SELECT payload
          FROM messages
          WHERE subject LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR body LIKE ? ESCAPE '\\' COLLATE NOCASE
          ORDER BY sent_at DESC
          LIMIT ?
          """,
        arguments: ["%\(escapedQuery)%", "%\(escapedQuery)%", boundedLimit]
      )
      return try payloads.map {
        try decoder.decode(MessageEnvelope.self, from: $0)
      }
    }
  }

  public func cursor(sourceID: String, conversationID: String) throws -> MessageCursor? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT value FROM cursors WHERE source_id = ? AND conversation_id = ?",
        arguments: [sourceID, conversationID]
      ).map(MessageCursor.init)
    }
  }

  public func setCursor(
    _ cursor: MessageCursor?,
    sourceID: String,
    conversationID: String
  ) throws {
    guard let cursor else { return }
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO cursors (source_id, conversation_id, value)
          VALUES (?, ?, ?)
          ON CONFLICT(source_id, conversation_id) DO UPDATE SET value = excluded.value
          """,
        arguments: [sourceID, conversationID, cursor.value]
      )
    }
  }

  public func containsMessage(id: String) throws -> Bool {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE id = ?", arguments: [id]) != nil
    }
  }

  public func hasMessages(sourceID: String, conversationID: String) throws -> Bool {
    try database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT 1 FROM messages WHERE source_id = ? AND conversation_id = ? LIMIT 1",
        arguments: [sourceID, conversationID]
      ) != nil
    }
  }

  public func oldestMessageID(sourceID: String, conversationID: String) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT id FROM messages WHERE source_id = ? AND conversation_id = ? ORDER BY sent_at ASC, id ASC LIMIT 1",
        arguments: [sourceID, conversationID]
      )
    }
  }

  public struct BackfillState: Sendable {
    public let cursor: MessageCursor?
    public let complete: Bool

    public init(cursor: MessageCursor?, complete: Bool) {
      self.cursor = cursor
      self.complete = complete
    }
  }

  public func backfillState(sourceID: String, conversationID: String) throws -> BackfillState? {
    try database.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: "SELECT cursor, complete FROM backfill_states WHERE source_id = ? AND conversation_id = ?",
        arguments: [sourceID, conversationID]
      ) else { return nil }
      let value: String? = row["cursor"]
      let complete: Bool = row["complete"]
      return BackfillState(cursor: value.map(MessageCursor.init), complete: complete)
    }
  }

  public func storePage(
    _ messages: [MessageEnvelope],
    backfillCursor: MessageCursor?,
    complete: Bool,
    sourceID: String,
    conversationID: String
  ) throws {
    try database.write { db in
      for message in messages {
        let payload = try encoder.encode(message)
        try db.execute(
          sql: """
            INSERT INTO messages (id, source_id, conversation_id, sent_at, subject, body, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              source_id = excluded.source_id, conversation_id = excluded.conversation_id,
              sent_at = excluded.sent_at, subject = excluded.subject,
              body = excluded.body, payload = excluded.payload
            """,
          arguments: [message.id, message.sourceID, message.conversationID,
                      message.sentAt.timeIntervalSince1970, message.subject, message.text, payload]
        )
      }
      try db.execute(
        sql: """
          INSERT INTO backfill_states (source_id, conversation_id, cursor, complete)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(source_id, conversation_id) DO UPDATE SET
            cursor = excluded.cursor, complete = excluded.complete
          """,
        arguments: [sourceID, conversationID, backfillCursor?.value, complete]
      )
    }
  }

  public func storeMessages(_ messages: [MessageEnvelope]) throws {
    try database.write { db in
      for message in messages {
        let payload = try encoder.encode(message)
        try db.execute(
          sql: """
            INSERT INTO messages (id, source_id, conversation_id, sent_at, subject, body, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              source_id = excluded.source_id, conversation_id = excluded.conversation_id,
              sent_at = excluded.sent_at, subject = excluded.subject,
              body = excluded.body, payload = excluded.payload
            """,
          arguments: [message.id, message.sourceID, message.conversationID,
                      message.sentAt.timeIntervalSince1970, message.subject, message.text, payload]
        )
      }
    }
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("messages-v1") { db in
      try db.create(table: "messages") { table in
        table.column("id", .text).primaryKey()
        table.column("source_id", .text).notNull().indexed()
        table.column("conversation_id", .text).notNull().indexed()
        table.column("sent_at", .double).notNull().indexed()
        table.column("subject", .text)
        table.column("body", .text)
        table.column("payload", .blob).notNull()
      }
    }
    migrator.registerMigration("cursors-v1") { db in
      try db.create(table: "cursors") { table in
        table.column("source_id", .text).notNull()
        table.column("conversation_id", .text).notNull()
        table.column("value", .text).notNull()
        table.primaryKey(["source_id", "conversation_id"])
      }
    }
    migrator.registerMigration("backfill-v1") { db in
      try db.create(table: "backfill_states") { table in
        table.column("source_id", .text).notNull()
        table.column("conversation_id", .text).notNull()
        table.column("cursor", .text)
        table.column("complete", .boolean).notNull().defaults(to: false)
        table.primaryKey(["source_id", "conversation_id"])
      }
      try db.execute(sql: """
        INSERT INTO backfill_states (source_id, conversation_id, cursor, complete)
        SELECT source_id, conversation_id, value, 0 FROM cursors
        """)
    }
    migrator.registerMigration("email-inbox-v1") { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, source_id, payload FROM messages WHERE source_id IN ('gmail', 'microsoft') AND conversation_id != (source_id || ':inbox')"
      )
      let decoder = JSONDecoder()
      let encoder = JSONEncoder()
      for row in rows {
        let sourceID: String = row["source_id"]
        let payload: Data = row["payload"]
        let message = try decoder.decode(MessageEnvelope.self, from: payload)
        let normalized = MessageEnvelope(
          id: message.id,
          sourceID: sourceID,
          conversationID: "\(sourceID):inbox",
          sender: message.sender,
          sentAt: message.sentAt,
          receivedAt: message.receivedAt,
          subject: message.subject,
          text: message.text,
          attachments: message.attachments
        )
        try db.execute(
          sql: "UPDATE messages SET conversation_id = ?, payload = ? WHERE id = ?",
          arguments: [normalized.conversationID, try encoder.encode(normalized), message.id]
        )
      }
    }
    return migrator
  }
}
