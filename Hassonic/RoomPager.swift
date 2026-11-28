import SwiftUI

/// The room pages, side by side: swipe left or right for the next or
/// previous room, in the order their tiles are on Home, with dots at the
/// bottom for where you are.
///
/// Each room still scrolls up and down on its own. A drag that something
/// inside the room claims stays with it: a slider, or a horizontal scroller
/// or pager of its own (a remote's panels) wins over the room swipe where
/// it is, because the innermost scroll view gets a drag first. A scroller
/// that only wants the drag when it has something to scroll should say so
/// with `.scrollBounceBehavior(.basedOnSize)`, as the sensor chips do, so a
/// swipe across it still changes rooms when it all fits.
struct RoomPager: View {
    let rooms: [DashboardPageConfiguration]
    /// The room whose tile, or link, opened the pager.
    let enteredRoomID: String

    @EnvironmentObject private var router: AppRouter
    /// The page the scroll view is on. Mirrored to `router.visibleRoomID`,
    /// so the title follows a swipe and a link can turn the page.
    @State private var scrolledID: String?

    /// How much the bottom of each room's scroll leaves clear for the dots.
    static let dotsClearance: CGFloat = 40

    init(rooms: [DashboardPageConfiguration], enteredRoomID: String) {
        self.rooms = rooms
        self.enteredRoomID = enteredRoomID
        _scrolledID = State(initialValue: enteredRoomID)
    }

    private var current: DashboardPageConfiguration? {
        let id = scrolledID ?? enteredRoomID
        return rooms.first { $0.id == id } ?? rooms.first
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(rooms) { room in
                    DashboardPageView(page: room, isInRoomPager: true)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $scrolledID)
        // One room: nothing to page to, so no rubber band either.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .overlay(alignment: .bottom) {
            if rooms.count > 1 {
                RoomPageDots(rooms: rooms, selection: $scrolledID)
                    .padding(.bottom, 6)
            }
        }
        .navigationTitle(current?.title ?? "")
        // Inline: a large title collapses by following one scroll view, and
        // here each room has its own, inside the pager's, so it never would.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let current {
                ToolbarItem(placement: .topBarTrailing) {
                    AppMenuButton(page: AppPage(id: current.id, title: current.title, systemIcon: current.systemIcon))
                }
            }
        }
        .onChange(of: scrolledID) { _, id in
            if let id, id != router.visibleRoomID { router.visibleRoomID = id }
        }
        .onChange(of: router.visibleRoomID) { _, id in
            // A link or Shortcut for another room while this one's open.
            guard let id, id != scrolledID, rooms.contains(where: { $0.id == id }) else { return }
            withAnimation(.snappy) { scrolledID = id }
        }
        .onAppear {
            if let id = router.visibleRoomID, id != scrolledID, rooms.contains(where: { $0.id == id }) {
                scrolledID = id
            }
        }
    }
}

/// A dot per room, the current one filled, on a pill that reads over a
/// room's picture in light or dark. Tap a dot to go to that room;
/// VoiceOver swipes up or down for the next or previous one.
struct RoomPageDots: View {
    let rooms: [DashboardPageConfiguration]
    @Binding var selection: String?

    private var index: Int {
        rooms.firstIndex { $0.id == selection } ?? 0
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(rooms.enumerated()), id: \.element.id) { offset, room in
                let isCurrent = offset == index
                Circle()
                    .fill(Color.primary.opacity(isCurrent ? 0.9 : 0.3))
                    .frame(width: 7, height: 7)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture { turn(to: offset) }
            }
        }
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .animation(.snappy, value: index)
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement()
        .accessibilityLabel("Room")
        .accessibilityValue("\(rooms[index].title), \(index + 1) of \(rooms.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: turn(to: index + 1)
            case .decrement: turn(to: index - 1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("room-page-dots")
    }

    private func turn(to offset: Int) {
        guard rooms.indices.contains(offset) else { return }
        withAnimation(.snappy) { selection = rooms[offset].id }
    }
}
