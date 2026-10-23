import SwiftUI

@main
struct KeyweeApp: App {
    var body: some Scene {
        WindowGroup {
            StationListView()
                .preferredColorScheme(.dark)
        }
    }
}
