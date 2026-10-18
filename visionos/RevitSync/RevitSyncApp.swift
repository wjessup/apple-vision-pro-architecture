import SwiftUI

@main
struct RevitSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: AppModel.mainWindowID) {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 520, height: 720)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(model.immersiveOpen ? .utilityPanel : nil)
        }

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
