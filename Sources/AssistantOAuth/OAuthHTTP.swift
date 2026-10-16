import Foundation

public protocol OAuthHTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct OAuthURLSessionClient: OAuthHTTPClient {
  public init() {}

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw OAuthError.invalidCallback
    }
    return (data, response)
  }
}

struct OAuthTokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String?
  let expiresIn: TimeInterval

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
  }
}

struct OAuthEndpointError: Decodable {
  let error: String?
  let errorDescription: String?

  private enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }
}

enum OAuthTokenEndpoint {
  static func exchange(
    provider: OAuthProvider,
    clientConfiguration: OAuthProviderClientConfiguration,
    code: String,
    verifier: String,
    redirectURI: URL,
    httpClient: any OAuthHTTPClient
  ) async throws -> OAuthTokenResponse {
    var fields = baseFields(provider: provider, client: clientConfiguration)
    fields += [
      ("code", code),
      ("code_verifier", verifier),
      ("grant_type", "authorization_code"),
      ("redirect_uri", redirectURI.absoluteString),
    ]
    if provider == .microsoft {
      fields.append(("scope", OAuthProviderMetadata.scopes(for: provider).joined(separator: " ")))
    }
    return try await request(
      provider: provider,
      endpoint: OAuthProviderMetadata.tokenEndpoint(
        for: provider,
        client: clientConfiguration
      ),
      fields: fields,
      httpClient: httpClient
    )
  }

  static func refresh(
    session: OAuthTokenSet,
    httpClient: any OAuthHTTPClient
  ) async throws -> OAuthTokenResponse {
    guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
      throw OAuthError.refreshUnavailable(session.provider)
    }
    var fields = baseFields(provider: session.provider, client: session.clientConfiguration)
    fields += [
      ("refresh_token", refreshToken),
      ("grant_type", "refresh_token"),
    ]
    if session.provider == .microsoft {
      fields.append(
        ("scope", OAuthProviderMetadata.scopes(for: session.provider).joined(separator: " "))
      )
    }
    return try await request(
      provider: session.provider,
      endpoint: OAuthProviderMetadata.tokenEndpoint(
        for: session.provider,
        client: session.clientConfiguration
      ),
      fields: fields,
      httpClient: httpClient
    )
  }

  private static func baseFields(
    provider: OAuthProvider,
    client: OAuthProviderClientConfiguration
  ) -> [(String, String)] {
    var fields = [("client_id", client.clientId)]
    if provider == .gmail, let secret = client.clientSecret, !secret.isEmpty {
      fields.append(("client_secret", secret))
    }
    return fields
  }

  private static func request(
    provider: OAuthProvider,
    endpoint: URL,
    fields: [(String, String)],
    httpClient: any OAuthHTTPClient
  ) async throws -> OAuthTokenResponse {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(formEncoded(fields).utf8)

    let (data, response) = try await httpClient.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      let endpointError = try? JSONDecoder().decode(OAuthEndpointError.self, from: data)
      let providerDescription = endpointError?.errorDescription ?? endpointError?.error
      let description = providerDescription.flatMap {
        visibleProviderError($0, provider: provider)
      } ?? "request failed"
      throw OAuthError.tokenRequestFailed(status: response.statusCode, description: description)
    }
    do {
      return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    } catch {
      throw OAuthError.invalidConfiguration("token response was malformed")
    }
  }

  private static func formEncoded(_ fields: [(String, String)]) -> String {
    var components = URLComponents()
    components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
    return components.percentEncodedQuery ?? ""
  }
}

func visibleProviderError(_ detail: String, provider: OAuthProvider) -> String? {
  switch provider {
  case .gmail:
    #if ASSISTANTCTL_QUIET_GMAIL
    return nil
    #else
    return detail
    #endif
  case .microsoft:
    #if ASSISTANTCTL_QUIET_MICROSOFT
    return nil
    #else
    return detail
    #endif
  }
}
