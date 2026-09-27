import SwiftUI

struct ContentView: View {
    var body: some View {
        VisualizerView()
            .ignoresSafeArea()
            .frame(minWidth: 640, minHeight: 360)
    }
}

#Preview {
    ContentView()
}
