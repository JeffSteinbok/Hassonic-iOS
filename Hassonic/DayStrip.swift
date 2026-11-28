import SwiftUI

/// The row of days along the top of a by-date view: "Today", "Yesterday",
/// then "Sat 10" back as far as history goes. A person's history and the
/// Security timeline both use it, with `historyRow` rows under it, so the
/// two read the same.
struct DayStrip: View {
    let days: [Date]
    @Binding var selection: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let isSelected = day == selection
                    Button { selection = day } label: {
                        Text(Self.label(for: day))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }

    /// The start of today and the `count - 1` days before it, newest first.
    static func recentDays(_ count: Int, now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    static func label(for day: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).day())
    }
}

extension View {
    /// One row in a by-date list: a rounded material card, outlined in
    /// `tint` while selected.
    func historyRow(isSelected: Bool = false, tint: Color = .accentColor) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? tint : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
    }
}
