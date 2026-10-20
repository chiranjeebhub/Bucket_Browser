import Foundation

public enum S3Error: LocalizedError, Sendable {
    /// The service answered with an error status (and usually an `<Error>` document).
    case service(status: Int, code: String?, message: String?, requestID: String?)
    case invalidResponse(String)
    case invalidConfiguration(String)
    case partialFailure([String])

    public var errorDescription: String? {
        switch self {
        case let .service(status, code, message, _):
            let detail = [code, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if detail.isEmpty {
                return "\(HTTPURLResponse.localizedString(forStatusCode: status).capitalized) (HTTP \(status))"
            }
            return "\(detail) (HTTP \(status))"
        case let .invalidResponse(reason):
            return "Unexpected response from server: \(reason)"
        case let .invalidConfiguration(reason):
            return reason
        case let .partialFailure(messages):
            let shown = messages.prefix(5).joined(separator: "\n")
            let more = messages.count > 5 ? "\n…and \(messages.count - 5) more" : ""
            return "Some items failed:\n\(shown)\(more)"
        }
    }

    public var statusCode: Int? {
        if case let .service(status, _, _, _) = self { return status }
        return nil
    }

    public var code: String? {
        if case let .service(_, code, _, _) = self { return code }
        return nil
    }

    static func from(status: Int, data: Data) -> S3Error {
        if !data.isEmpty, let root = try? S3XMLNode.parse(data), root.name == "Error" {
            return .service(status: status, code: root.value("Code"), message: root.value("Message"), requestID: root.value("RequestId"))
        }
        return .service(status: status, code: nil, message: nil, requestID: nil)
    }
}
