import Foundation

public enum TelegramRequestPolicy {
  private static let allowedTypes: Set<String> = [
    "checkAuthenticationCode",
    "checkAuthenticationPassword",
    "checkDatabaseEncryptionKey",
    "close",
    "getAuthorizationState",
    "getChat",
    "getChatHistory",
    "getChats",
    "getMessage",
    "getUser",
    "searchChatMessages",
    "setAuthenticationPhoneNumber",
    "setTdlibParameters",
  ]

  public static func isAllowed(_ requestType: String) -> Bool {
    allowedTypes.contains(requestType)
  }
}
