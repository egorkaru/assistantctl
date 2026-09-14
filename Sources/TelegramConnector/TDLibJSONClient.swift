import AssistantJSON
import CTDLib
import Foundation

actor TDLibJSONClient {
  private let clientID: Int32
  private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
  private var updateContinuations: [UUID: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
  private var receiverTask: Task<Void, Never>?

  init() {
    clientID = td_create_client_id()
  }

  deinit {
    receiverTask?.cancel()
  }

  func request(type: String, fields: [String: JSONValue] = [:]) async throws -> Data {
    guard TelegramRequestPolicy.isAllowed(type) else {
      throw TelegramConnectorError.requestBlocked(type)
    }
    startReceiverIfNeeded()

    let requestID = UUID().uuidString
    var object = fields
    object["@type"] = .string(type)
    object["@extra"] = .string(requestID)
    let data = try JSONEncoder().encode(JSONValue.object(object))
    guard let json = String(data: data, encoding: .utf8) else {
      throw TelegramConnectorError.invalidResponse("Could not encode TDLib request")
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[requestID] = continuation
        json.withCString { pointer in
          td_send(clientID, pointer)
        }
      }
    } onCancel: {
      Task { await self.cancel(requestID: requestID) }
    }
  }

  func updates() -> AsyncThrowingStream<Data, any Error> {
    startReceiverIfNeeded()
    let id = UUID()
    return AsyncThrowingStream { continuation in
      updateContinuations[id] = continuation
      continuation.onTermination = { @Sendable _ in
        Task { await self.removeUpdateContinuation(id: id) }
      }
    }
  }

  private func startReceiverIfNeeded() {
    guard receiverTask == nil else { return }
    receiverTask = Task.detached { [weak self] in
      while !Task.isCancelled {
        guard let pointer = td_receive(0.25) else { continue }
        let data = Data(bytes: pointer, count: strlen(pointer))
        await self?.handle(data)
      }
    }
  }

  private func handle(_ data: Data) {
    guard
      let object = try? TelegramMessageMapper.jsonObject(from: data),
      let responseClientID = object["@client_id"] as? NSNumber,
      responseClientID.int32Value == clientID
    else {
      return
    }

    if let requestID = object["@extra"] as? String,
      let continuation = pending.removeValue(forKey: requestID)
    {
      if object["@type"] as? String == "error" {
        let code = (object["code"] as? NSNumber)?.intValue ?? -1
        let message = object["message"] as? String ?? "Unknown TDLib error"
        continuation.resume(
          throwing: TelegramConnectorError.tdlib(code: code, message: message)
        )
      } else {
        continuation.resume(returning: data)
      }
      return
    }

    for continuation in updateContinuations.values {
      continuation.yield(data)
    }
  }

  private func cancel(requestID: String) {
    pending.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
  }

  private func removeUpdateContinuation(id: UUID) {
    updateContinuations.removeValue(forKey: id)
  }
}
