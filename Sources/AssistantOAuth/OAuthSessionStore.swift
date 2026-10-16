import AssistantSecurity
import Foundation

public protocol OAuthSessionStoring: Sendable {
  func session(for provider: OAuthProvider) async throws -> OAuthTokenSet?
  func save(_ session: OAuthTokenSet) async throws
  func deleteSession(for provider: OAuthProvider) async throws
}

public actor KeychainOAuthSessionStore: OAuthSessionStoring {
  private let secrets: KeychainSecretStore
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(secrets: KeychainSecretStore = KeychainSecretStore()) {
    self.secrets = secrets
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  public func session(for provider: OAuthProvider) throws -> OAuthTokenSet? {
    guard let value = try secrets.value(for: key(for: provider)) else { return nil }
    guard let data = value.data(using: .utf8) else { throw SecretStoreError.invalidData }
    let stored = try decoder.decode(StoredOAuthSession.self, from: data)
    let embeddedConfiguration = stored.configurationSource == .embedded
      ? try? OAuthConfigurationLoader(environment: [:]).loadProvider(provider, explicitPath: nil).0
      : nil
    guard let clientConfiguration = embeddedConfiguration ?? stored.clientConfiguration else {
      throw OAuthError.missingConfiguration(provider)
    }
    let session = OAuthTokenSet(
      provider: stored.provider,
      accessToken: stored.accessToken,
      refreshToken: stored.refreshToken,
      expiresAt: stored.expiresAt,
      clientConfiguration: clientConfiguration,
      configurationSource: stored.configurationSource
    )
    if embeddedConfiguration != nil, stored.clientConfiguration != nil {
      try save(session)
    }
    return session
  }

  public func save(_ session: OAuthTokenSet) throws {
    let stored = StoredOAuthSession(
      provider: session.provider,
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresAt: session.expiresAt,
      clientConfiguration: session.configurationSource == .embedded
        ? nil : session.clientConfiguration,
      configurationSource: session.configurationSource
    )
    let data = try encoder.encode(stored)
    guard let value = String(data: data, encoding: .utf8) else {
      throw SecretStoreError.invalidData
    }
    try secrets.set(value, for: key(for: session.provider))
  }

  public func deleteSession(for provider: OAuthProvider) throws {
    try secrets.deleteValue(for: key(for: provider))
  }

  private func key(for provider: OAuthProvider) -> String {
    "oauth.\(provider.rawValue).session-v1"
  }
}

struct StoredOAuthSession: Codable {
  let provider: OAuthProvider
  let accessToken: String
  let refreshToken: String?
  let expiresAt: Date
  let clientConfiguration: OAuthProviderClientConfiguration?
  let configurationSource: OAuthConfigurationSource
}
