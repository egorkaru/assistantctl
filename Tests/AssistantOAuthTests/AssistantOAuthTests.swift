import AssistantOAuth
import Foundation
import Testing

@Suite("OAuth authentication")
struct AssistantOAuthTests {
  @Test("Gmail authorization uses PKCE and the read-only scope")
  func gmailAuthorizationRequest() throws {
    let redirect = try #require(URL(string: "http://127.0.0.1:8123"))
    let request = OAuthAuthorizationRequestBuilder.make(
      provider: .gmail,
      client: OAuthProviderClientConfiguration(
        clientId: "client.apps.googleusercontent.com",
        clientSecret: "public-desktop-value"
      ),
      redirectURI: redirect,
      verifier: "verifier",
      state: "state"
    )
    let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: try #require(components.queryItems).map { ($0.name, $0.value) }
    )

    #expect(query["scope"] == "https://www.googleapis.com/auth/gmail.readonly")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["state"] == "state")
    #expect(query["access_type"] == "offline")
  }

  @Test("Microsoft authorization uses public-client read-only scopes")
  func microsoftAuthorizationRequest() throws {
    let redirect = try #require(URL(string: "http://localhost:8123"))
    let request = OAuthAuthorizationRequestBuilder.make(
      provider: .microsoft,
      client: OAuthProviderClientConfiguration(clientId: "client", tenant: "common"),
      redirectURI: redirect,
      verifier: "verifier",
      state: "state"
    )
    let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: try #require(components.queryItems).map { ($0.name, $0.value) }
    )

    #expect(query["scope"] == "offline_access Mail.Read")
    #expect(request.url.path == "/common/oauth2/v2.0/authorize")
    #expect(query["response_mode"] == "query")
  }

  @Test("Explicit config takes precedence over environment and embedded config")
  func configurationPrecedence() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let explicitURL = directory.appending(path: "explicit.json")
    let environmentURL = directory.appending(path: "environment.json")
    try configurationJSON(clientID: "explicit").write(to: explicitURL)
    try configurationJSON(clientID: "environment").write(to: environmentURL)
    let embedded = configurationJSON(clientID: "embedded").base64EncodedString()

    let loader = OAuthConfigurationLoader(
      environment: ["ASSISTANTCTL_OAUTH_CONFIG": environmentURL.path],
      embeddedBase64: embedded
    )
    let selection = try loader.load(explicitPath: explicitURL.path)

    #expect(selection.source == .commandLine)
    #expect(selection.configuration.gmail?.clientId == "explicit")
  }

  @Test("A source build without embedded config remains valid")
  func missingEmbeddedConfiguration() throws {
    let selection = try OAuthConfigurationLoader(
      environment: [:],
      embeddedBase64: nil
    ).load(explicitPath: nil)

    #expect(selection.source == .embedded)
    #expect(selection.configuration.gmail == nil)
    #expect(selection.configuration.microsoft == nil)
    #expect(throws: OAuthError.self) {
      try OAuthConfigurationLoader(environment: [:], embeddedBase64: nil)
        .loadProvider(.gmail, explicitPath: nil)
    }
  }

  @Test("Malformed OAuth config fails without exposing its contents")
  func rejectsMalformedConfiguration() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).json")
    try Data("not-json".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: OAuthError.self) {
      try OAuthConfigurationLoader(environment: [:], embeddedBase64: nil)
        .load(explicitPath: url.path)
    }
  }

  @Test("Expired access tokens refresh and rotated refresh tokens are saved")
  func refreshesExpiredToken() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = InMemoryOAuthSessionStore(
      session: OAuthTokenSet(
        provider: .gmail,
        accessToken: "expired",
        refreshToken: "refresh-1",
        expiresAt: now.addingTimeInterval(-1),
        clientConfiguration: OAuthProviderClientConfiguration(clientId: "client"),
        configurationSource: .embedded
      )
    )
    let client = StubOAuthHTTPClient(
      status: 200,
      body: #"{"access_token":"fresh","refresh_token":"refresh-2","expires_in":3600}"#
    )
    let provider = OAuthAccessTokenProvider(
      provider: .gmail,
      sessionStore: store,
      httpClient: client,
      now: { now }
    )

    #expect(try await provider.accessToken() == "fresh")
    #expect(await store.session(for: .gmail)?.refreshToken == "refresh-2")
    let request = try #require(await client.lastRequest())
    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(body.contains("grant_type=refresh_token"))
    #expect(body.contains("refresh_token=refresh-1"))
  }

  @Test("Concurrent requests share one token refresh")
  func serializesConcurrentRefresh() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = InMemoryOAuthSessionStore(
      session: expiredSession(now: now, provider: .microsoft)
    )
    let client = CountingOAuthHTTPClient()
    let provider = OAuthAccessTokenProvider(
      provider: .microsoft,
      sessionStore: store,
      httpClient: client,
      now: { now }
    )

    async let first = provider.accessToken()
    async let second = provider.accessToken()
    #expect(try await [first, second] == ["fresh", "fresh"])
    #expect(await client.requestCount() == 1)
  }

  @Test("A revoked refresh token returns a safe endpoint error")
  func revokedRefreshToken() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let provider = OAuthAccessTokenProvider(
      provider: .gmail,
      sessionStore: InMemoryOAuthSessionStore(
        session: expiredSession(now: now, provider: .gmail)
      ),
      httpClient: StubOAuthHTTPClient(
        status: 400,
        body: #"{"error":"invalid_grant","error_description":"Token expired or revoked"}"#
      ),
      now: { now }
    )

    await #expect(throws: OAuthError.self) {
      try await provider.accessToken()
    }
  }

  @Test("Login rejects a callback with the wrong state")
  func rejectsMismatchedState() async throws {
    let store = InMemoryOAuthSessionStore(session: nil)
    let service = OAuthLoginService(
      sessionStore: store,
      httpClient: StubOAuthHTTPClient(status: 500, body: "{}"),
      browser: StubBrowser(),
      serverFactory: StubCallbackServerFactory(
        callback: OAuthCallback(
          code: "code",
          state: "wrong-state",
          error: nil,
          errorDescription: nil
        )
      )
    )

    await #expect(throws: OAuthError.self) {
      try await service.login(
        provider: .gmail,
        clientConfiguration: OAuthProviderClientConfiguration(clientId: "client"),
        configurationSource: .embedded
      )
    }
  }

  @Test("Successful login exchanges the code and saves the session")
  func successfulLogin() async throws {
    let interaction = LoginInteraction()
    let store = InMemoryOAuthSessionStore(session: nil)
    let service = OAuthLoginService(
      sessionStore: store,
      httpClient: StubOAuthHTTPClient(
        status: 200,
        body: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#
      ),
      browser: CapturingBrowser(interaction: interaction),
      serverFactory: SuccessfulCallbackServerFactory(interaction: interaction),
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let session = try await service.login(
      provider: .gmail,
      clientConfiguration: OAuthProviderClientConfiguration(clientId: "client"),
      configurationSource: .commandLine
    )

    #expect(session.refreshToken == "refresh")
    #expect(session.expiresAt == Date(timeIntervalSince1970: 1_700_003_600))
    #expect(await store.session(for: .gmail)?.accessToken == "access")
  }

  @Test("Provider denial is returned before callback state validation")
  func reportsAuthorizationDenial() async throws {
    let service = OAuthLoginService(
      sessionStore: InMemoryOAuthSessionStore(session: nil),
      httpClient: StubOAuthHTTPClient(status: 500, body: "{}"),
      browser: StubBrowser(),
      serverFactory: StubCallbackServerFactory(
        callback: OAuthCallback(
          code: nil,
          state: nil,
          error: "access_denied",
          errorDescription: "User cancelled"
        )
      )
    )

    await #expect(throws: OAuthError.self) {
      try await service.login(
        provider: .microsoft,
        clientConfiguration: OAuthProviderClientConfiguration(clientId: "client"),
        configurationSource: .commandLine
      )
    }
  }

  @Test("Callback timeout is propagated")
  func reportsCallbackTimeout() async throws {
    let service = OAuthLoginService(
      sessionStore: InMemoryOAuthSessionStore(session: nil),
      httpClient: StubOAuthHTTPClient(status: 500, body: "{}"),
      browser: StubBrowser(),
      serverFactory: TimeoutCallbackServerFactory()
    )

    await #expect(throws: OAuthError.self) {
      try await service.login(
        provider: .gmail,
        clientConfiguration: OAuthProviderClientConfiguration(clientId: "client"),
        configurationSource: .embedded
      )
    }
  }

  @Test("Status encoding never contains tokens")
  func statusDoesNotExposeTokens() throws {
    let status = OAuthConnectionStatus(
      provider: .gmail,
      session: OAuthTokenSet(
        provider: .gmail,
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
        clientConfiguration: OAuthProviderClientConfiguration(clientId: "client"),
        configurationSource: .embedded
      )
    )
    let output = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)

    #expect(!output.contains("access-secret"))
    #expect(!output.contains("refresh-secret"))
  }

  private func configurationJSON(clientID: String) -> Data {
    Data(#"{"version":1,"gmail":{"clientId":"\#(clientID)"}}"#.utf8)
  }

  private func expiredSession(now: Date, provider: OAuthProvider) -> OAuthTokenSet {
    OAuthTokenSet(
      provider: provider,
      accessToken: "expired",
      refreshToken: "refresh-1",
      expiresAt: now.addingTimeInterval(-1),
      clientConfiguration: OAuthProviderClientConfiguration(clientId: "client"),
      configurationSource: .embedded
    )
  }
}

private actor InMemoryOAuthSessionStore: OAuthSessionStoring {
  private var storedSession: OAuthTokenSet?

  init(session: OAuthTokenSet?) {
    storedSession = session
  }

  func session(for provider: OAuthProvider) -> OAuthTokenSet? {
    storedSession?.provider == provider ? storedSession : nil
  }

  func save(_ session: OAuthTokenSet) {
    storedSession = session
  }

  func deleteSession(for provider: OAuthProvider) {
    if storedSession?.provider == provider { storedSession = nil }
  }
}

private actor StubOAuthHTTPClient: OAuthHTTPClient {
  private let status: Int
  private let body: String
  private var request: URLRequest?

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  func data(for request: URLRequest) -> (Data, HTTPURLResponse) {
    self.request = request
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

  func lastRequest() -> URLRequest? { request }
}

private actor CountingOAuthHTTPClient: OAuthHTTPClient {
  private var count = 0

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    count += 1
    try await Task.sleep(for: .milliseconds(50))
    return (
      Data(#"{"access_token":"fresh","refresh_token":"refresh-2","expires_in":3600}"#.utf8),
      HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
    )
  }

  func requestCount() -> Int { count }
}

private struct StubBrowser: OAuthBrowserOpening {
  func open(_ url: URL) async throws {}
}

private actor LoginInteraction {
  private var authorizationURL: URL?

  func record(_ url: URL) {
    authorizationURL = url
  }

  func state() -> String? {
    guard
      let authorizationURL,
      let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
    else {
      return nil
    }
    return components.queryItems?.first(where: { $0.name == "state" })?.value
  }
}

private struct CapturingBrowser: OAuthBrowserOpening {
  let interaction: LoginInteraction

  func open(_ url: URL) async throws {
    await interaction.record(url)
  }
}

private struct StubCallbackServerFactory: OAuthCallbackServerCreating {
  let callback: OAuthCallback

  func makeServer(for provider: OAuthProvider) throws -> any OAuthCallbackServing {
    StubCallbackServer(callback: callback)
  }
}

private struct StubCallbackServer: OAuthCallbackServing {
  let callback: OAuthCallback
  let redirectURI = URL(string: "http://127.0.0.1:8123")!

  func waitForCallback(timeout: Duration) async throws -> OAuthCallback { callback }
}

private struct TimeoutCallbackServerFactory: OAuthCallbackServerCreating {
  func makeServer(for provider: OAuthProvider) throws -> any OAuthCallbackServing {
    TimeoutCallbackServer()
  }
}

private struct TimeoutCallbackServer: OAuthCallbackServing {
  let redirectURI = URL(string: "http://127.0.0.1:8123")!

  func waitForCallback(timeout: Duration) async throws -> OAuthCallback {
    throw OAuthError.callbackTimeout
  }
}

private struct SuccessfulCallbackServerFactory: OAuthCallbackServerCreating {
  let interaction: LoginInteraction

  func makeServer(for provider: OAuthProvider) throws -> any OAuthCallbackServing {
    SuccessfulCallbackServer(interaction: interaction)
  }
}

private struct SuccessfulCallbackServer: OAuthCallbackServing {
  let interaction: LoginInteraction
  let redirectURI = URL(string: "http://127.0.0.1:8123")!

  func waitForCallback(timeout: Duration) async throws -> OAuthCallback {
    OAuthCallback(
      code: "authorization-code",
      state: await interaction.state(),
      error: nil,
      errorDescription: nil
    )
  }
}
