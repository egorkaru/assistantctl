import Foundation
import Security

public enum SecretStoreError: Error, LocalizedError {
  case invalidData
  case keychain(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidData: "The Keychain value is not valid UTF-8"
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
  }
}

public struct KeychainSecretStore: Sendable {
  private let service: String

  public init(service: String = "dev.assistantctl") {
    self.service = service
  }

  public func value(for key: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw SecretStoreError.invalidData
    }
    return value
  }

  public func set(_ value: String, for key: String) throws {
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
    let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw SecretStoreError.keychain(updateStatus)
    }
    var item = lookup
    item[kSecValueData as String] = Data(value.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
  }

  public func deleteValue(for key: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreError.keychain(status)
    }
  }

  public func valueOrCreate(for key: String) throws -> String {
    if let existing = try value(for: key) { return existing }
    let value = UUID().uuidString + UUID().uuidString
    try set(value, for: key)
    return value
  }
}

public enum CredentialKey {
  public static let telegramAPIID = "telegram.api-id"
  public static let telegramAPIHash = "telegram.api-hash"
  public static let telegramPhone = "telegram.phone"
  public static let telegramDatabaseKey = "telegram.database-key"
  public static let gmailAccessToken = "gmail.access-token"
  public static let microsoftAccessToken = "microsoft.access-token"
  public static let mcpBearerToken = "mcp.bearer-token"
}
