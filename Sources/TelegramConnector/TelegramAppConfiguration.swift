import Foundation

public struct TelegramAppConfiguration: Equatable, Sendable {
  public let apiID: Int
  public let apiHash: String

  public init(apiID: Int, apiHash: String) {
    self.apiID = apiID
    self.apiHash = apiHash
  }
}

public enum TelegramAppConfigurationError: Error, LocalizedError, Sendable {
  case missingAPIID
  case missingAPIHash
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .missingAPIID:
      "Missing Telegram API ID. Pass --api-id, set ASSISTANTCTL_TELEGRAM_API_ID, or embed a Telegram app configuration."
    case .missingAPIHash:
      "Missing Telegram API hash. Pass --api-hash, set ASSISTANTCTL_TELEGRAM_API_HASH, or embed a Telegram app configuration."
    case .invalid(let detail):
      "Invalid Telegram app configuration: \(detail)"
    }
  }
}

public struct TelegramAppConfigurationLoader: Sendable {
  private struct EmbeddedFile: Decodable {
    let version: Int
    let apiId: Int
    let apiHash: String

    private enum CodingKeys: String, CodingKey {
      case version, apiId, apiHash
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      guard let version = try? values.decode(Int.self, forKey: .version) else {
        throw TelegramAppConfigurationError.invalid("invalid version")
      }
      guard let apiId = try? values.decode(Int.self, forKey: .apiId) else {
        throw TelegramAppConfigurationError.invalid("invalid apiId")
      }
      guard let apiHash = try? values.decode(String.self, forKey: .apiHash) else {
        throw TelegramAppConfigurationError.invalid("invalid apiHash")
      }
      self.version = version
      self.apiId = apiId
      self.apiHash = apiHash
    }
  }

  private let embeddedBase64: String?

  public init(embeddedBase64: String? = EmbeddedTelegramAppConfiguration.jsonBase64) {
    self.embeddedBase64 = embeddedBase64
  }

  public func loadEmbedded() throws -> TelegramAppConfiguration? {
    guard let embeddedBase64 else { return nil }
    guard let data = Data(base64Encoded: embeddedBase64) else {
      throw TelegramAppConfigurationError.invalid("embedded data is not Base64")
    }

    let file: EmbeddedFile
    do {
      file = try JSONDecoder().decode(EmbeddedFile.self, from: data)
    } catch let error as TelegramAppConfigurationError {
      throw error
    } catch {
      throw TelegramAppConfigurationError.invalid("malformed embedded JSON")
    }

    guard file.version == 1 else {
      throw TelegramAppConfigurationError.invalid("unsupported version; expected 1")
    }
    guard file.apiId > 0 else {
      throw TelegramAppConfigurationError.invalid("apiId must be a positive integer")
    }
    guard !file.apiHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TelegramAppConfigurationError.invalid("apiHash must not be empty")
    }
    return TelegramAppConfiguration(apiID: file.apiId, apiHash: file.apiHash)
  }

  public func resolve(
    externalAPIID: String?,
    externalAPIHash: String?
  ) throws -> TelegramAppConfiguration {
    switch (externalAPIID, externalAPIHash) {
    case (nil, nil):
      guard let embedded = try loadEmbedded() else {
        throw TelegramAppConfigurationError.missingAPIID
      }
      return embedded
    case (nil, _):
      throw TelegramAppConfigurationError.missingAPIID
    case (_, nil):
      throw TelegramAppConfigurationError.missingAPIHash
    case (let id?, let hash?):
      guard let numericID = Int(id), numericID > 0 else {
        throw TelegramAppConfigurationError.invalid("apiId must be a positive integer")
      }
      guard !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TelegramAppConfigurationError.invalid("apiHash must not be empty")
      }
      return TelegramAppConfiguration(apiID: numericID, apiHash: hash)
    }
  }
}
