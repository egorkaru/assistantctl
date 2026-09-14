import Foundation

public struct OAuthConfigurationLoader: Sendable {
  private let environment: [String: String]
  private let embeddedBase64: String?

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    embeddedBase64: String? = EmbeddedOAuthClientConfiguration.jsonBase64
  ) {
    self.environment = environment
    self.embeddedBase64 = embeddedBase64
  }

  public func load(explicitPath: String?) throws -> OAuthConfigurationSelection {
    if let explicitPath, !explicitPath.isEmpty {
      return try loadFile(path: explicitPath, source: .commandLine)
    }
    if let path = environment["ASSISTANTCTL_OAUTH_CONFIG"], !path.isEmpty {
      return try loadFile(path: path, source: .environment)
    }
    guard
      let embeddedBase64,
      let data = Data(base64Encoded: embeddedBase64)
    else {
      return OAuthConfigurationSelection(
        configuration: OAuthClientConfiguration(),
        source: .embedded
      )
    }
    return try decode(data: data, source: .embedded)
  }

  public func loadProvider(
    _ provider: OAuthProvider,
    explicitPath: String?
  ) throws -> (OAuthProviderClientConfiguration, OAuthConfigurationSource) {
    let selection = try load(explicitPath: explicitPath)
    guard let configuration = selection.configuration.configuration(for: provider) else {
      throw OAuthError.missingConfiguration(provider)
    }
    try validate(configuration, for: provider)
    return (configuration, selection.source)
  }

  private func loadFile(
    path: String,
    source: OAuthConfigurationSource
  ) throws -> OAuthConfigurationSelection {
    let expandedPath = NSString(string: path).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expandedPath) else {
      throw OAuthError.configurationFileNotFound(expandedPath)
    }
    return try decode(data: Data(contentsOf: URL(fileURLWithPath: expandedPath)), source: source)
  }

  private func decode(
    data: Data,
    source: OAuthConfigurationSource
  ) throws -> OAuthConfigurationSelection {
    do {
      let configuration = try JSONDecoder().decode(OAuthClientConfiguration.self, from: data)
      guard configuration.version == 1 else {
        throw OAuthError.invalidConfiguration(
          "unsupported version \(configuration.version); expected 1"
        )
      }
      return OAuthConfigurationSelection(configuration: configuration, source: source)
    } catch let error as OAuthError {
      throw error
    } catch {
      throw OAuthError.invalidConfiguration(error.localizedDescription)
    }
  }

  private func validate(
    _ configuration: OAuthProviderClientConfiguration,
    for provider: OAuthProvider
  ) throws {
    guard !configuration.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OAuthError.invalidConfiguration("\(provider.rawValue).clientId is empty")
    }
    if provider == .microsoft,
      let tenant = configuration.tenant,
      tenant.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) == nil
    {
      throw OAuthError.invalidConfiguration("microsoft.tenant contains invalid characters")
    }
  }
}
