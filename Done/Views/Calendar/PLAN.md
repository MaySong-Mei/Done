# Calendar Page Plan

## Goal
- Split `CalendarView.swift` into small components for readability.
- Add a page entry file: `CalendarPageView`.

## Entry Composition (View Tree)
CalendarView
- CalendarPageView (wrapper)

CalendarPageView
- GeometryReader
  - ZStack(alignment: .top) [ignoresSafeArea(.top)]
    - ScrollView (timeline + top fade/hold mask)
      - CalendarTimelineView(events) [paddingTop = timelineTopInset]
    - GlassCardView (fixed header overlay) [paddingTop = headerTopInset]

CalendarTimelineView
- HStack
  - TimeAxisView
  - TabView(.page)
    - ForEach(dayRange) -> TimelineDayView(date, events)

TimelineDayView
- ZStack
  - TimelineGrid (date header + hour lines)
  - ForEach(dayEvents) -> CalendarEventBlockView(event)

## Data Flow
- Source: `EventStore.events`
- `CalendarPageView` reads store via `@EnvironmentObject`
- Child components receive `[Event]` via parameters
- `CalendarLayout` computes filter + geometry + color

## Files To Create
- `Done/Views/Calendar/CalendarPageView.swift`
- `Done/Views/Calendar/CalendarLayout.swift`
- `Done/Views/Calendar/Components/GlassCardView.swift`
- `Done/Views/Calendar/Components/CalendarTimelineView.swift`
- `Done/Views/Calendar/Components/TimelineDayView.swift`
- `Done/Views/Calendar/Components/CalendarEventBlockView.swift`

## Files To Update
- `Done/Views/Calendar/CalendarView.swift` -> wrapper to `CalendarPageView`
- `Done.xcodeproj/project.pbxproj` -> add new Swift files to Sources

## Non-goals (for now)
- Overlap handling / column packing
- Recurrence expansion
- Performance optimizations
