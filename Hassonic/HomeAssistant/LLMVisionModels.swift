import Foundation

struct LLMVisionEvent: Decodable, Identifiable, Equatable {
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
        start.flatMap(HATimestamp.parse)
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
}
