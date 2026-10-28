import Testing
@testable import ArcusisBrowser

struct SidebarVisibilityTests {
  @Test func pinnedAndHoverTransitions() {
    var visibility = SidebarVisibility.pinned
    visibility.pointerEnteredEdge()
    visibility.pointerLeftSidebar()
    #expect(visibility == .pinned)

    visibility.setPinned(false)
    #expect(visibility == .hidden)
    visibility.pointerEnteredEdge()
    #expect(visibility == .revealed)
    visibility.pointerLeftSidebar()
    #expect(visibility == .hidden)

    visibility.pointerEnteredEdge()
    visibility.setPinned(true)
    visibility.pointerLeftSidebar()
    #expect(visibility == .pinned)
    visibility.setPinned(false)
    #expect(visibility == .hidden)
  }
}
