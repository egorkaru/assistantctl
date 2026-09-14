import AssistantMessages
import AssistantOAuth
import Foundation

public enum EmailConnectorError: Error, LocalizedError, Sendable {
  case invalidConversationID(String)
  case invalidMessageID(String)
  case invalidResponse(String)
  case requestFailed(status: Int, body: String)

  public var isInvalidPageToken: Bool {
    if case .requestFailed(let status, _) = self {
      return status == 400 || status == 404 || status == 410
    }
    return false
  }

  public var errorDescription: String? {
    switch self {
    case .invalidConversationID(let id): "Invalid email conversation ID: \(id)"
    case .invalidMessageID(let id): "Invalid email message ID: \(id)"
    case .invalidResponse(let detail): "Invalid email response: \(detail)"
    case .requestFailed(let status, let body): "Email API returned HTTP \(status): \(body)"
    }
  }
}

public protocol HTTPDataClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPDataClient: HTTPDataClient {
  public init() {}

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw EmailConnectorError.invalidResponse("Missing HTTP response")
    }
    return (data, response)
  }
}

public final class GmailMessageConnector: MessageConnector, Sendable {
  public let source = MessageSource(id: "gmail", kind: .gmail, displayName: "Gmail")

  private let accessTokenProvider: any AccessTokenProviding
  private let client: any HTTPDataClient
  private let baseURL: URL

  public init(
    accessToken: String,
    client: any HTTPDataClient = URLSessionHTTPDataClient(),
    baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
  ) {
    accessTokenProvider = StaticAccessTokenProvider(accessToken)
    self.client = client
    self.baseURL = baseURL
  }

  public init(
    accessTokenProvider: any AccessTokenProviding,
    client: any HTTPDataClient = URLSessionHTTPDataClient(),
    baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
  ) {
    self.accessTokenProvider = accessTokenProvider
    self.client = client
    self.baseURL = baseURL
  }

  public func conversations() async throws -> [MessageConversation] {
    [MessageConversation(id: "gmail:inbox", sourceID: source.id, title: "Inbox")]
  }

  public func messages(
    in conversationID: String,
    cursor: MessageCursor?,
    limit: Int
  ) async throws -> MessagePage {
    guard conversationID == "gmail:inbox" else {
      throw EmailConnectorError.invalidConversationID(conversationID)
    }
    var components = URLComponents(
      url: baseURL.appending(path: "messages"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "labelIds", value: "INBOX"),
      URLQueryItem(name: "maxResults", value: String(max(1, min(limit, 100)))),
    ]
    if let cursor {
      components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor.value))
    }
    let list: GmailMessageList = try await get(components.url!)
    var messages: [MessageEnvelope] = []
    for reference in list.messages ?? [] {
      messages.append(try await fetchMessage(reference.id))
    }
    return MessagePage(
      messages: messages,
      nextCursor: list.nextPageToken.map(MessageCursor.init)
    )
  }

  public func message(id: String) async throws -> MessageEnvelope {
    let prefix = "gmail:"
    guard id.hasPrefix(prefix), id.count > prefix.count else {
      throw EmailConnectorError.invalidMessageID(id)
    }
    return try await fetchMessage(String(id.dropFirst(prefix.count)))
  }

  public func updates() async -> AsyncThrowingStream<MessageUpdate, any Error> {
    pollingUpdates(conversationID: "gmail:inbox")
  }

  private func fetchMessage(_ providerID: String) async throws -> MessageEnvelope {
    var components = URLComponents(
      url: baseURL.appending(path: "messages/\(providerID)"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "format", value: "full")]
    let message: GmailMessage = try await get(components.url!)
    return message.envelope
  }

  private func get<Response: Decodable>(_ url: URL) async throws -> Response {
    let data = try await authenticatedEmailData(
      from: url,
      accessTokenProvider: accessTokenProvider,
      client: client
    )
    return try JSONDecoder().decode(Response.self, from: data)
  }

  private func pollingUpdates(
    conversationID: String
  ) -> AsyncThrowingStream<MessageUpdate, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var seen = Set<String>()
        do {
          while !Task.isCancelled {
            let page = try await messages(in: conversationID, cursor: nil, limit: 25)
            for message in page.messages where seen.insert(message.id).inserted {
              continuation.yield(.message(message))
            }
            try await Task.sleep(for: .seconds(30))
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }
}

public final class MicrosoftMailConnector: MessageConnector, Sendable {
  public let source = MessageSource(
    id: "microsoft",
    kind: .microsoft,
    displayName: "Microsoft Mail"
  )

  private let accessTokenProvider: any AccessTokenProviding
  private let client: any HTTPDataClient
  private let baseURL: URL

  public init(
    accessToken: String,
    client: any HTTPDataClient = URLSessionHTTPDataClient(),
    baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0/me")!
  ) {
    accessTokenProvider = StaticAccessTokenProvider(accessToken)
    self.client = client
    self.baseURL = baseURL
  }

  public init(
    accessTokenProvider: any AccessTokenProviding,
    client: any HTTPDataClient = URLSessionHTTPDataClient(),
    baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0/me")!
  ) {
    self.accessTokenProvider = accessTokenProvider
    self.client = client
    self.baseURL = baseURL
  }

  public func conversations() async throws -> [MessageConversation] {
    [MessageConversation(id: "microsoft:inbox", sourceID: source.id, title: "Inbox")]
  }

  public func messages(
    in conversationID: String,
    cursor: MessageCursor?,
    limit: Int
  ) async throws -> MessagePage {
    guard conversationID == "microsoft:inbox" else {
      throw EmailConnectorError.invalidConversationID(conversationID)
    }
    let savedPage = cursor.flatMap { MicrosoftPagePosition.decode($0.value) }
    let url: URL
    if let savedPage, let cursorURL = URL(string: savedPage.url) {
      url = cursorURL
    } else if let cursor, let cursorURL = URL(string: cursor.value) {
      url = cursorURL
    } else {
      var components = URLComponents(
        url: baseURL.appending(path: "mailFolders/inbox/messages"),
        resolvingAgainstBaseURL: false
      )!
      components.queryItems = [
        URLQueryItem(name: "$top", value: String(max(1, min(limit, 100)))),
        URLQueryItem(name: "$select", value: Self.listFields),
        URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
      ]
      url = components.url!
    }
    let list: MicrosoftMessageList = try await get(url)
    let offset = savedPage?.offset ?? 0
    guard offset <= list.value.count else {
      throw EmailConnectorError.invalidResponse("Saved Microsoft page position is unavailable")
    }
    let remaining = Array(list.value.dropFirst(offset))
    let selected = Array(remaining.prefix(max(1, min(limit, 100))))
    let next: MessageCursor?
    if selected.count < remaining.count {
      next = try MicrosoftPagePosition(url: url.absoluteString, offset: offset + selected.count).cursor()
    } else {
      next = list.nextLink.map(MessageCursor.init)
    }
    var messages: [MessageEnvelope] = []
    for item in selected {
      messages.append(try await message(id: "microsoft:\(item.id)"))
    }
    return MessagePage(messages: messages, nextCursor: next)
  }

  public func message(id: String) async throws -> MessageEnvelope {
    let prefix = "microsoft:"
    guard id.hasPrefix(prefix), id.count > prefix.count else {
      throw EmailConnectorError.invalidMessageID(id)
    }
    let providerID = String(id.dropFirst(prefix.count))
    var components = URLComponents(
      url: baseURL.appending(path: "messages/\(providerID)"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "$select", value: Self.messageFields)]
    let message: MicrosoftMessage = try await get(components.url!)
    return message.envelope
  }

  public func updates() async -> AsyncThrowingStream<MessageUpdate, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var seen = Set<String>()
        do {
          while !Task.isCancelled {
            let page = try await messages(in: "microsoft:inbox", cursor: nil, limit: 25)
            for message in page.messages where seen.insert(message.id).inserted {
              continuation.yield(.message(message))
            }
            try await Task.sleep(for: .seconds(30))
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func get<Response: Decodable>(_ url: URL) async throws -> Response {
    let data = try await authenticatedEmailData(
      from: url,
      accessTokenProvider: accessTokenProvider,
      client: client,
      preferTextBody: true
    )
    return try JSONDecoder().decode(Response.self, from: data)
  }

  private static let listFields =
    "id,conversationId,receivedDateTime,sentDateTime,subject,bodyPreview,from,hasAttachments"
  private static let messageFields = listFields + ",body"
}

private struct MicrosoftPagePosition: Codable {
  let url: String
  let offset: Int

  func cursor() throws -> MessageCursor {
    let data = try JSONEncoder().encode(self)
    return MessageCursor("assistantctl-ms-page:" + data.base64EncodedString())
  }

  static func decode(_ value: String) -> MicrosoftPagePosition? {
    let prefix = "assistantctl-ms-page:"
    guard value.hasPrefix(prefix),
          let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
          let position = try? JSONDecoder().decode(Self.self, from: data),
          position.offset >= 0 else { return nil }
    return position
  }
}

private func authenticatedEmailData(
  from url: URL,
  accessTokenProvider: any AccessTokenProviding,
  client: any HTTPDataClient,
  preferTextBody: Bool = false
) async throws -> Data {
  let token = try await accessTokenProvider.accessToken(forceRefresh: false)
  let firstResponse = try await emailResponse(
    from: url, token: token, client: client, preferTextBody: preferTextBody
  )
  guard firstResponse.1.statusCode == 401 else {
    return try validatedEmailData(firstResponse)
  }
  let refreshedToken = try await accessTokenProvider.accessToken(forceRefresh: true)
  return try validatedEmailData(
    try await emailResponse(from: url, token: refreshedToken, client: client,
                            preferTextBody: preferTextBody)
  )
}

private func emailResponse(
  from url: URL,
  token: String,
  client: any HTTPDataClient,
  preferTextBody: Bool
) async throws -> (Data, HTTPURLResponse) {
  var request = URLRequest(url: url)
  request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  request.setValue("application/json", forHTTPHeaderField: "Accept")
  if preferTextBody {
    request.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
  }
  return try await client.data(for: request)
}

private func validatedEmailData(_ result: (Data, HTTPURLResponse)) throws -> Data {
  let (data, response) = result
  guard (200..<300).contains(response.statusCode) else {
    throw EmailConnectorError.requestFailed(
      status: response.statusCode,
      body: String(decoding: data, as: UTF8.self)
    )
  }
  return data
}

private struct GmailMessageList: Decodable {
  let messages: [Reference]?
  let nextPageToken: String?

  struct Reference: Decodable { let id: String }
}

private struct GmailMessage: Decodable {
  let id: String
  let internalDate: String?
  let snippet: String?
  let payload: Part?

  struct Part: Decodable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    let body: Body?
    let parts: [Part]?
  }

  struct Header: Decodable {
    let name: String
    let value: String
  }
  struct Body: Decodable {
    let attachmentId: String?
    let size: Int?
    let data: String?
  }

  var envelope: MessageEnvelope {
    let headers = Dictionary(
      (payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) },
      uniquingKeysWith: { first, _ in first }
    )
    let sender = EmailAddress.parse(headers["from"] ?? "Unknown")
    let timestamp =
      Double(internalDate ?? "").map { Date(timeIntervalSince1970: $0 / 1_000) }
      ?? Date(timeIntervalSince1970: 0)
    return MessageEnvelope(
      id: "gmail:\(id)",
      sourceID: "gmail",
      conversationID: "gmail:inbox",
      sender: sender,
      sentAt: timestamp,
      receivedAt: timestamp,
      subject: headers["subject"],
      text: payload?.plainText ?? snippet,
      attachments: payload?.attachments ?? []
    )
  }
}

extension GmailMessage.Part {
  fileprivate var plainText: String? {
    if mimeType == "text/plain", let data = body?.data {
      return Self.decodeBase64URL(data)
    }
    return parts?.lazy.compactMap(\.plainText).first
  }

  fileprivate var attachments: [AttachmentMetadata] {
    var result = parts?.flatMap(\.attachments) ?? []
    if let attachmentID = body?.attachmentId {
      result.append(
        AttachmentMetadata(
          id: attachmentID,
          fileName: filename?.isEmpty == false ? filename : nil,
          mediaType: mimeType,
          sizeBytes: body?.size.map(Int64.init)
        )
      )
    }
    return result
  }

  private static func decodeBase64URL(_ value: String) -> String? {
    var normalized = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    guard let data = Data(base64Encoded: normalized) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

private struct MicrosoftMessageList: Decodable {
  let value: [MicrosoftMessage]
  let nextLink: String?

  enum CodingKeys: String, CodingKey {
    case value
    case nextLink = "@odata.nextLink"
  }
}

private struct MicrosoftMessage: Decodable {
  let id: String
  let conversationId: String?
  let receivedDateTime: Date?
  let sentDateTime: Date?
  let subject: String?
  let body: Body?
  let bodyPreview: String?
  let from: Recipient?
  let hasAttachments: Bool?

  struct Recipient: Decodable { let emailAddress: Address }
  struct Address: Decodable {
    let name: String?
    let address: String
  }
  struct Body: Decodable {
    let contentType: String
    let content: String
  }

  var envelope: MessageEnvelope {
    let timestamp = sentDateTime ?? receivedDateTime ?? Date(timeIntervalSince1970: 0)
    let address = from?.emailAddress
    return MessageEnvelope(
      id: "microsoft:\(id)",
      sourceID: "microsoft",
      conversationID: "microsoft:inbox",
      sender: MessageIdentity(id: address?.address ?? "unknown", displayName: address?.name),
      sentAt: timestamp,
      receivedAt: receivedDateTime,
      subject: subject,
      text: body?.contentType.lowercased() == "text" ? body?.content : bodyPreview,
      attachments: hasAttachments == true
        ? [AttachmentMetadata(id: "microsoft:\(id):attachments")]
        : []
    )
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
    subject = try container.decodeIfPresent(String.self, forKey: .subject)
    body = try container.decodeIfPresent(Body.self, forKey: .body)
    bodyPreview = try container.decodeIfPresent(String.self, forKey: .bodyPreview)
    from = try container.decodeIfPresent(Recipient.self, forKey: .from)
    hasAttachments = try container.decodeIfPresent(Bool.self, forKey: .hasAttachments)
    receivedDateTime = try Self.decodeDate(container, key: .receivedDateTime)
    sentDateTime = try Self.decodeDate(container, key: .sentDateTime)
  }

  private enum CodingKeys: String, CodingKey {
    case id, conversationId, receivedDateTime, sentDateTime, subject, body, bodyPreview, from,
      hasAttachments
  }

  private static func decodeDate(
    _ container: KeyedDecodingContainer<CodingKeys>,
    key: CodingKeys
  ) throws -> Date? {
    guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
    return ISO8601DateFormatter().date(from: value)
  }
}

private enum EmailAddress {
  static func parse(_ value: String) -> MessageIdentity {
    guard let start = value.lastIndex(of: "<"), let end = value.lastIndex(of: ">"), start < end
    else {
      return MessageIdentity(id: value.trimmingCharacters(in: .whitespaces), displayName: nil)
    }
    let address = String(value[value.index(after: start)..<end])
    let name = value[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return MessageIdentity(id: address, displayName: name.isEmpty ? nil : name)
  }
}
