import Foundation

/// The rules behind the Security timeline: which events fall on a day, what
/// to call a camera, and how to write an event's time.
enum SecurityTimeline {
    /// How many days the strip offers, matching a person's history.
    static let dayCount = 10

    /// The events that started on `day`, in the order given (newest first).
    static func events(_ events: [LLMVisionEvent], on day: Date, calendar: Calendar = .current) -> [LLMVisionEvent] {
        events.filter { $0.startDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
    }

    /// The words a camera integration adds to name one of a camera's streams,
    /// not the camera: Reolink's "Fluent"/"Clear", UniFi's "High"/"Medium"/
    /// "Low", "Snapshot(s)", and so on.
    private static let streamWords: Set<String> = [
        "high", "medium", "low", "fluent", "clear", "balanced",
        "snapshot", "snapshots", "main", "sub", "substream", "stream", "hd", "sd",
        "resolution", "channel", "insecure",
    ]

    /// What to call the camera an event came from. LLM Vision reports the
    /// feed, often an entity id such as `camera.backyard_left_fluent`; this
    /// is "Backyard Left": the entity's friendly name when Home Assistant has
    /// one, else the id made readable, with stream words and a trailing
    /// "_2" style counter dropped either way.
    static func cameraName(_ raw: String?, friendlyName: (String) -> String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let isEntityId = raw.hasPrefix("camera.") && !raw.contains(" ")
        let base: String
        if isEntityId, let friendly = friendlyName(raw), friendly != raw {
            base = friendly
        } else if isEntityId {
            base = String(raw.dropFirst("camera.".count))
        } else {
            base = raw
        }
        var words = base
            .split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
            .map(String.init)
        while words.count > 1, let last = words.last,
              streamWords.contains(last.lowercased()) || last.allSatisfy(\.isNumber) {
            words.removeLast()
        }
        guard !words.isEmpty else { return base }
        // Ids are all lower case; a friendly name keeps its own capitals.
        return words.map { $0 == $0.lowercased() ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
            .joined(separator: " ")
    }

    /// "Today 5:42 PM", "Yesterday 5:42 PM", else "Fri, Nov 27, 5:42 PM";
    /// the year too when it isn't this one.
    static func eventTime(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEMMMdjmm" : "EEEMMMdyjmm")
        return formatter.string(from: date)
    }

    /// "5:42 PM": a row's time, under a strip that already says the day.
    static func rowTime(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }
}
