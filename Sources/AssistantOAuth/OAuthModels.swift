import Foundation

public enum OAuthProvider: String, Codable, CaseIterable, Sendable {
  case gmail
  case microsoft

  public var displayName: String {
    switch self {
    case .gmail: "Gmail"
    case .microsoft: "Microsoft Mail"
    }
  }
}

public struct OAuthProviderClientConfiguration: Codable, Equatable, Sendable {
  public let clientId: String
  public let clientSecret: String?
  public let tenant: String?

  public init(clientId: String, clientSecret: String? = nil, tenant: String? = nil) {
    self.clientId = clientId
    self.clientSecret = clientSecret
    self.tenant = tenant
  }
}

public struct OAuthClientConfiguration: Codable, Equatable, Sendable {
  public let version: Int
  public let gmail: OAuthProviderClientConfiguration?
  public let microsoft: OAuthProviderClientConfiguration?

  public init(
    version: Int = 1,
    gmail: OAuthProviderClientConfiguration? = nil,
    microsoft: OAuthProviderClientConfiguration? = nil
  ) {
    self.version = version
    self.gmail = gmail
    self.microsoft = microsoft
  }

  public func configuration(for provider: OAuthProvider) -> OAuthProviderClientConfiguration? {
    switch provider {
    case .gmail: gmail
    case .microsoft: microsoft
    }
  }
}

public enum OAuthConfigurationSource: String, Codable, Equatable, Sendable {
  case commandLine = "command-line"
  case environment
  case embedded
}

public struct OAuthConfigurationSelection: Equatable, Sendable {
  public let configuration: OAuthClientConfiguration
  public let source: OAuthConfigurationSource

  public init(
    configuration: OAuthClientConfiguration,
    source: OAuthConfigurationSource
  ) {
    self.configuration = configuration
    self.source = source
  }
}

public struct OAuthTokenSet: Codable, Equatable, Sendable {
  public let provider: OAuthProvider
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date
  public let clientConfiguration: OAuthProviderClientConfiguration
  public let configurationSource: OAuthConfigurationSource

  public init(
    provider: OAuthProvider,
    accessToken: String,
    refreshToken: String?,
    expiresAt: Date,
    clientConfiguration: OAuthProviderClientConfiguration,
    configurationSource: OAuthConfigurationSource
  ) {
    self.provider = provider
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.clientConfiguration = clientConfiguration
    self.configurationSource = configurationSource
  }
}

public struct OAuthConnectionStatus: Codable, Equatable, Sendable {
  public let provider: OAuthProvider
  public let connected: Bool
  public let expiresAt: Date?
  public let canRefresh: Bool
  public let configurationSource: OAuthConfigurationSource?

  public init(provider: OAuthProvider, session: OAuthTokenSet?) {
    self.provider = provider
    connected = session != nil
    expiresAt = session?.expiresAt
    canRefresh = session?.refreshToken?.isEmpty == false
    configurationSource = session?.configurationSource
  }
}

public enum OAuthError: Error, LocalizedError, Sendable {
  case missingConfiguration(OAuthProvider)
  case configurationFileNotFound(String)
  case invalidConfiguration(String)
  case notLoggedIn(OAuthProvider)
  case refreshUnavailable(OAuthProvider)
  case browserOpenFailed
  case callbackTimeout
  case invalidCallback
  case callbackStateMismatch
  case authorizationDenied(String)
  case tokenRequestFailed(status: Int, description: String)

  public var errorDescription: String? {
    switch self {
    case .missingConfiguration(let provider):
      "Missing OAuth client configuration for \(provider.displayName). Pass --oauth-config, set ASSISTANTCTL_OAUTH_CONFIG, or add .assistantctl-private/oauth-clients.json before building."
    case .configurationFileNotFound(let path):
      "OAuth configuration file not found: \(path)"
    case .invalidConfiguration(let detail):
      "Invalid OAuth configuration: \(detail)"
    case .notLoggedIn(let provider):
      "\(provider.displayName) is not connected. Run assistantctl email \(provider.rawValue) login."
    case .refreshUnavailable(let provider):
      "\(provider.displayName) did not provide a refresh token. Run assistantctl email \(provider.rawValue) login again."
    case .browserOpenFailed:
      "Could not open the system browser for authorization."
    case .callbackTimeout:
      "Authorization timed out after five minutes."
    case .invalidCallback:
      "The OAuth callback was malformed."
    case .callbackStateMismatch:
      "The OAuth callback state did not match the login request."
    case .authorizationDenied(let description):
      "Authorization was denied: \(description)"
    case .tokenRequestFailed(let status, let description):
      "OAuth token endpoint returned HTTP \(status): \(description)"
    }
  }
}

public protocol AccessTokenProviding: Sendable {
  func accessToken(forceRefresh: Bool) async throws -> String
}

public struct StaticAccessTokenProvider: AccessTokenProviding {
  private let token: String

  public init(_ token: String) {
    self.token = token
  }

  public func accessToken(forceRefresh: Bool) async throws -> String {
    token
  }
}
