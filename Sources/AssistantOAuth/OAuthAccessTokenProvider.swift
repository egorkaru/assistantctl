import Foundation

public actor OAuthAccessTokenProvider: AccessTokenProviding {
  private let provider: OAuthProvider
  private let sessionStore: any OAuthSessionStoring
  private let httpClient: any OAuthHTTPClient
  private let now: @Sendable () -> Date
  private var refreshTask: Task<OAuthTokenSet, any Error>?

  public init(
    provider: OAuthProvider,
    sessionStore: any OAuthSessionStoring,
    httpClient: any OAuthHTTPClient = OAuthURLSessionClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.provider = provider
    self.sessionStore = sessionStore
    self.httpClient = httpClient
    self.now = now
  }

  public func accessToken(forceRefresh: Bool = false) async throws -> String {
    guard let session = try await sessionStore.session(for: provider) else {
      throw OAuthError.notLoggedIn(provider)
    }
    if !forceRefresh, session.expiresAt > now().addingTimeInterval(300) {
      return session.accessToken
    }
    if let refreshTask {
      return try await refreshTask.value.accessToken
    }

    let task = Task { [httpClient, now, sessionStore] in
      let response = try await OAuthTokenEndpoint.refresh(
        session: session,
        httpClient: httpClient
      )
      let refreshed = OAuthTokenSet(
        provider: session.provider,
        accessToken: response.accessToken,
        refreshToken: response.refreshToken ?? session.refreshToken,
        expiresAt: now().addingTimeInterval(response.expiresIn),
        clientConfiguration: session.clientConfiguration,
        configurationSource: session.configurationSource
      )
      try await sessionStore.save(refreshed)
      return refreshed
    }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value.accessToken
  }
}
