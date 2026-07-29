import SwiftUI

struct MobileRootView: View {
    @ObservedObject var model: MobileAppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack {
                MobileCaptureView(model: model)
            }
            .tabItem {
                Label("Capture", systemImage: "plus.app.fill")
            }
            .tag(MobileTab.capture)

            MobileTimelineView(model: model)
                .tabItem {
                    Label("Timeline", systemImage: "clock.arrow.circlepath")
                }
                .tag(MobileTab.timeline)

            NavigationStack {
                MobileAskView(model: model)
            }
            .tabItem {
                Label("Ask", systemImage: "sparkles")
            }
            .tag(MobileTab.ask)
        }
        .tint(.indigo)
        .overlay(alignment: .top) {
            if let label = model.importState.label {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 3)
                .padding(.top, 8)
            }
        }
        .alert(
            "Dropsift",
            isPresented: Binding(
                get: {
                    model.errorMessage != nil
                        || model.locator.errorMessage != nil
                        || model.recorder.errorMessage != nil
                },
                set: { value in
                    if !value {
                        model.errorMessage = nil
                        model.locator.errorMessage = nil
                        model.recorder.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                model.errorMessage = nil
                model.locator.errorMessage = nil
                model.recorder.errorMessage = nil
            }
        } message: {
            Text(
                model.errorMessage
                    ?? model.locator.errorMessage
                    ?? model.recorder.errorMessage
                    ?? ""
            )
        }
    }
}
