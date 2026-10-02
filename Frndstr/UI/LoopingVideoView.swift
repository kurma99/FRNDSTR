import AVFoundation
import SwiftUI

/// Instagram-style feed video: muted autoplay loop while visible, tap the speaker to toggle sound.
struct LoopingVideoView: View {
    let url: URL
    /// Whether the video is on screen; playback pauses when it scrolls away.
    let isActive: Bool
    /// Crop to fill the frame (feed) or show the whole video (full-screen viewer).
    var fillsFrame = true

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isMuted = true

    var body: some View {
        PlayerLayerView(player: player, fillsFrame: fillsFrame)
            .background(Color.black)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                    if !isMuted {
                        try? AVAudioSession.sharedInstance().setCategory(.playback)
                    }
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                // Dark-tinted glass keeps the icon readable over bright video frames.
                .buttonStyle(.glass(.regular.tint(.black.opacity(0.35))))
                .buttonBorderShape(.circle)
                .padding(12)
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            }
            .onAppear(perform: setUp)
            .onDisappear { player?.pause() }
            .onChange(of: isActive) { _, active in
                active ? player?.play() : player?.pause()
            }
    }

    private func setUp() {
        if player == nil {
            // AVPlayer can't send custom headers, but it can send the Cloudflare Access cookie.
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: CloudflareAccess.cookies(for: url)])
            let item = AVPlayerItem(asset: asset)
            let queue = AVQueuePlayer()
            queue.isMuted = isMuted
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        }
        if isActive { player?.play() }
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    let fillsFrame: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView()
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
