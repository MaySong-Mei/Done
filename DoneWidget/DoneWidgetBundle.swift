import WidgetKit
import SwiftUI

@main
struct DoneWidgetBundle: WidgetBundle {
    var body: some Widget {
        DoneWidget()
        ProgressRingWidget()
        MiniTimelineWidget()
        TimelineBarWidget()
    }
}
