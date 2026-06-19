import AVKit
import SwiftUI

/// Hosts the live `AVPlayer` produced by `LivePlayerService`. All lifecycle is
/// owned by the service; this view only mirrors the current player.
struct LivePlayerView: NSViewRepresentable {
    @ObservedObject var service: LivePlayerService

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = service.player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== service.player {
            nsView.player = service.player
        }
    }
}
