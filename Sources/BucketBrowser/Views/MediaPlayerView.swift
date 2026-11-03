import AVKit
import Combine
import SwiftUI

/// Plays audio or video straight from the bucket. AVPlayer reads the object with HTTP range
/// requests, so playback starts after the first few seconds arrive and seeking fetches only
/// the part that's needed.
struct MediaPlayerView: View {
    let media: StreamingMedia
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failure: String?

    private var isAudio: Bool { !media.item.contentType.conforms(to: .movie) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let player {
                    VideoPlayer(player: player) {
                        if isAudio {
                            VStack(spacing: 8) {
                                Image(nsImage: media.item.icon)
                                    .resizable()
                                    .frame(width: 96, height: 96)
                                Text(media.item.name).font(.headline)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                        }
                    }
                }
                if let failure {
                    ContentUnavailableView {
                        Label("Can’t Play This File", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Download Instead…") {
                            model.download([media.item])
                            dismiss()
                        }
                    }
                    .background(.background)
                }
            }
            .frame(minWidth: 640, idealWidth: 960, minHeight: isAudio ? 240 : 360, idealHeight: isAudio ? 260 : 540)

            Divider()
            HStack {
                Text(media.item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(media.item.formattedSize)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download…") { model.download([media.item]) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .task {
            let player = AVPlayer(url: media.url)
            self.player = player
            player.play()
            // Report files AVFoundation can't decode (an unusual codec, say) instead of a black frame.
            for await status in player.currentItem!.publisher(for: \.status).values {
                if status == .failed {
                    failure = player.currentItem?.error?.localizedDescription ?? "The file couldn’t be decoded."
                    break
                }
                if status == .readyToPlay { break }
            }
        }
        .onDisappear { player?.pause() }
    }
}
