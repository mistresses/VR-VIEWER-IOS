import SwiftUI
import AVFoundation
import UIKit

struct VideoLayerView: UIViewRepresentable {
    let decoder: H264Decoder
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView(decoder: decoder)
        view.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: VideoDisplayView, context: Context) {
        uiView.videoGravity = videoGravity
    }
}

final class VideoDisplayView: UIView {
    private let decoder: H264Decoder
    private let displayLayer = AVSampleBufferDisplayLayer()

    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet { displayLayer.videoGravity = videoGravity }
    }

    init(decoder: H264Decoder) {
        self.decoder = decoder
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true

        displayLayer.videoGravity = videoGravity
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = bounds
        layer.addSublayer(displayLayer)

        decoder.attachDisplayLayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    deinit {
        decoder.detachDisplayLayer(displayLayer)
    }
}
