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
    return try decoder.decode(OAuthTokenSet.self, from: data)
  }

  public func save(_ session: OAuthTokenSet) throws {
    let data = try encoder.encode(session)
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
