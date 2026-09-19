import AVFoundation
import AppKit
import SwiftUI

/// Hosts the live `AVPlayer` produced by `LivePlayerService`. All lifecycle is
/// owned by the service; this view only mirrors the current player.
///
/// Backed by a plain `AVPlayerLayer`, not AVKit's `AVPlayerView`: on macOS 27
/// `AVPlayerView` traps (EXC_BREAKPOINT inside AVKit → SwiftUI `Binding.init`)
/// while the first view body is evaluated, which crashed the app at launch.
/// The preview needs no transport controls; mute and status live in the app UI.
struct LivePlayerView: NSViewRepresentable {
    @ObservedObject var service: LivePlayerService

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = service.player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.player !== service.player {
            nsView.player = service.player
        }
    }
}

final class PlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { false }
}
