import WidgetKit
import SwiftUI

@main
struct TesstatsWidgetBundle: WidgetBundle {
    var body: some Widget {
        TesstatsStatusWidget()
        ChargingLiveActivityWidget()
    }
}
