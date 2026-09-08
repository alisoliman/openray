import SwiftUI

struct CaffeinateMenuContent: View {
    let model: LauncherModel

    var body: some View {
        Button("Caffeinate — \(model.caffeinate.isActive ? "Active" : "Off")") {
            model.openCaffeinate()
            model.panel?.show()
        }
        if model.caffeinate.isActive {
            Text(model.caffeinate.statusText)
            Button("Stop Caffeinate") { model.caffeinate.stop() }
        }
        Menu(model.caffeinate.isActive ? "Keep Awake For…" : "Start Caffeinate") {
            ForEach(CaffeinateDuration.allCases) { duration in
                Button(duration.title) { model.caffeinate.start(for: duration) }
            }
            Divider()
            Button("More Options…") {
                model.openCaffeinate()
                model.panel?.show()
            }
        }
        if let error = model.caffeinate.errorMessage { Text(error) }
    }
}
