import AssistantMessages
import AssistantOAuth
import EmailConnector
import Foundation
import Testing

@Suite("Read-only email connectors")
struct EmailConnectorTests {
  @Test("Gmail maps list and full-message responses")
  func gmailMapsMessages() async throws {
    let client = StubHTTPClient(responses: [
      "messages": #"{"messages":[{"id":"abc"}],"nextPageToken":"next"}"#,
      "messages/abc":
        #"{"id":"abc","threadId":"thread","internalDate":"1700000000000","snippet":"fallback","payload":{"mimeType":"multipart/alternative","headers":[{"name":"From","value":"Alice <alice@example.com>"},{"name":"Subject","value":"Plan"}],"parts":[{"partId":"1","mimeType":"text/plain","filename":"","body":{"size":5,"data":"SGVsbG8"}}]}}"#,
    ])
    let connector = GmailMessageConnector(
      accessToken: "token",
      client: client,
      baseURL: URL(string: "https://example.test/gmail")!
    )

    let page = try await connector.messages(in: "gmail:inbox", cursor: nil, limit: 10)

    #expect(page.nextCursor == MessageCursor("next"))
    #expect(page.messages.first?.id == "gmail:abc")
    #expect(page.messages.first?.conversationID == "gmail:inbox")
    #expect(page.messages.first?.sender.id == "alice@example.com")
    #expect(page.messages.first?.text == "Hello")
  }

  @Test("Microsoft Graph maps inbox responses")
  func microsoftMapsMessages() async throws {
    let client = StubHTTPClient(responses: [
      "mailFolders/inbox/messages":
        #"{"value":[{"id":"m1","conversationId":"c1","receivedDateTime":"2023-11-14T22:13:20Z","sentDateTime":"2023-11-14T22:12:00Z","subject":"Hello","bodyPreview":"Preview","from":{"emailAddress":{"name":"Bob","address":"bob@example.com"}},"hasAttachments":false}]}"#,
      "messages/m1":
        #"{"id":"m1","conversationId":"c1","receivedDateTime":"2023-11-14T22:13:20Z","sentDateTime":"2023-11-14T22:12:00Z","subject":"Hello","bodyPreview":"Preview","body":{"contentType":"text","content":"Full message beyond the preview"},"from":{"emailAddress":{"name":"Bob","address":"bob@example.com"}},"hasAttachments":false}"#,
    ])
    let connector = MicrosoftMailConnector(
      accessToken: "token",
      client: client,
      baseURL: URL(string: "https://example.test/me")!
    )

    let page = try await connector.messages(in: "microsoft:inbox", cursor: nil, limit: 10)

    #expect(page.messages.first?.id == "microsoft:m1")
    #expect(page.messages.first?.conversationID == "microsoft:inbox")
    #expect(page.messages.first?.sender.displayName == "Bob")
    #expect(page.messages.first?.text == "Full message beyond the preview")
    #expect(await client.preferredTextBody())
  }

  @Test("Microsoft cursor preserves an unread page remainder")
  func microsoftBackfillPageRemainder() async throws {
    let entries = (1...5).map { number in
      """
      {"id":"m\(number)","conversationId":"c1","receivedDateTime":"2023-11-14T22:13:20Z","sentDateTime":"2023-11-14T22:12:00Z","subject":"Hello","bodyPreview":"Preview","from":{"emailAddress":{"name":"Bob","address":"bob@example.com"}},"hasAttachments":false}
      """
    }.joined(separator: ",")
    var responses = ["mailFolders/inbox/messages": "{\"value\":[\(entries)]}"]
    for number in 1...5 {
      responses["messages/m\(number)"] = "{\"id\":\"m\(number)\",\"body\":{\"contentType\":\"text\",\"content\":\"Full \(number)\"}}"
    }
    let client = StubHTTPClient(responses: responses)
    let connector = MicrosoftMailConnector(
      accessToken: "token", client: client,
      baseURL: URL(string: "https://example.test/me")!
    )
    var cursor: MessageCursor? = MessageCursor("https://example.test/me/mailFolders/inbox/messages?page=2")
    var ids: [String] = []
    for _ in 0..<3 {
      let page = try await connector.messages(in: "microsoft:inbox", cursor: cursor, limit: 2)
      ids += page.messages.map(\.id)
      cursor = page.nextCursor
    }
    #expect(ids == ["microsoft:m1", "microsoft:m2", "microsoft:m3", "microsoft:m4", "microsoft:m5"])
    #expect(cursor == nil)
  }

  @Test("A 401 refreshes the token and retries once")
  func refreshesAndRetriesUnauthorizedRequest() async throws {
    let client = RetryHTTPClient()
    let tokens = RotatingAccessTokenProvider()
    let connector = GmailMessageConnector(
      accessTokenProvider: tokens,
      client: client,
      baseURL: URL(string: "https://example.test/gmail")!
    )

    let page = try await connector.messages(in: "gmail:inbox", cursor: nil, limit: 10)

    #expect(page.messages.isEmpty)
    #expect(await tokens.forcedRefreshCount() == 1)
    #expect(await client.authorizationHeaders() == ["Bearer expired", "Bearer fresh"])
  }
}

private actor StubHTTPClient: HTTPDataClient {
  let responses: [String: String]
  private var sawTextBodyPreference = false

  init(responses: [String: String]) { self.responses = responses }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.value(forHTTPHeaderField: "Prefer") == "outlook.body-content-type=\"text\"" {
      sawTextBodyPreference = true
    }
    let path = request.url!.path
    guard let pair = responses.first(where: { path.hasSuffix($0.key) }) else {
      throw EmailConnectorError.invalidResponse("No fixture for \(path)")
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    return (Data(pair.value.utf8), response)
  }

  func preferredTextBody() -> Bool { sawTextBodyPreference }
}

private actor RotatingAccessTokenProvider: AccessTokenProviding {
  private var refreshes = 0

  func accessToken(forceRefresh: Bool) -> String {
    if forceRefresh { refreshes += 1 }
    return forceRefresh ? "fresh" : "expired"
  }

  func forcedRefreshCount() -> Int { refreshes }
}

private actor RetryHTTPClient: HTTPDataClient {
  private var headers: [String] = []

  func data(for request: URLRequest) -> (Data, HTTPURLResponse) {
    headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
    let status = headers.count == 1 ? 401 : 200
    let body = status == 200 ? #"{"messages":[]}"# : #"{"error":"expired"}"#
    return (
      Data(body.utf8),
      HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
      )!
    )
  }

  func authorizationHeaders() -> [String] { headers }
}
