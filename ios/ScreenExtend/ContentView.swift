import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var receiver: Receiver

    var body: some View {
        ZStack {
            Color.black
            VideoView(layer: receiver.displayLayer)
            if !receiver.isStreaming {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 44))
                    Text("ScreenExtend")
                        .font(.title2.bold())
                    Text(receiver.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

/// Hosts the layer that decodes and shows the incoming video.
struct VideoView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoUIView { VideoUIView(videoLayer: layer) }
    func updateUIView(_ view: VideoUIView, context: Context) {}
}

final class VideoUIView: UIView {
    private let videoLayer: AVSampleBufferDisplayLayer

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
