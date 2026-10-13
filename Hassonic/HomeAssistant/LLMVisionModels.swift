import Foundation

struct LLMVisionEvent: Decodable, Identifiable, Equatable {
    private static let dateFormatter = ISO8601DateFormatter()

    let uid: String
    let title: String?
    let description: String?
    let start: String?
    let end: String?
    let keyFrame: String?
    let cameraName: String?
    let category: String?
    let label: String?

    var id: String { uid }

    var startDate: Date? {
        guard let start else { return nil }
        return Self.dateFormatter.date(from: start)
    }
}

struct LLMVisionTimelineResponse: Decodable {
    let events: [LLMVisionEvent]
}

enum LLMVisionError: Error, Equatable {
    case integrationUnavailable
    case authenticationFailed
    case networkError(String)
    case decodingError

    var isRetryable: Bool {
        switch self {
        case .networkError: return true
        case .integrationUnavailable, .authenticationFailed, .decodingError: return false
        }
    }
}
