import SwiftUI

@main struct NewtonApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model).tint(.indigo) }
    }
}
