import Foundation

public enum TelegramRequestPolicy {
  private static let allowedTypes: Set<String> = [
    "checkAuthenticationCode",
    "checkAuthenticationPassword",
    "close",
    "getAuthorizationState",
    "getChat",
    "getChatHistory",
    "getChats",
    "getMessage",
    "getUser",
    "requestQrCodeAuthentication",
    "resendAuthenticationCode",
    "searchChatMessages",
    "setAuthenticationPhoneNumber",
    "setTdlibParameters",
  ]

  public static func isAllowed(_ requestType: String) -> Bool {
    allowedTypes.contains(requestType)
  }
}
