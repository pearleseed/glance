//
//  LoopingVideoView.swift
//  glance
//
//  Plays a bundled video on loop, holding its last frame for `pauseBetweenLoops`
//  before restarting. Distinct from ScanAnimationView, which plays once and holds.
//

import AVFoundation
import AppKit
import SwiftUI

struct LoopingVideoView: NSViewRepresentable {
    let resourceName: String
    var pauseBetweenLoops: TimeInterval = 2.0

    func makeNSView(context: Context) -> LoopingVideoHostView {
        let view = LoopingVideoHostView()
        view.configure(resourceName: resourceName, pauseBetweenLoops: pauseBetweenLoops)
        return view
    }

    func updateNSView(_ nsView: LoopingVideoHostView, context: Context) {
        nsView.configure(resourceName: resourceName, pauseBetweenLoops: pauseBetweenLoops)
    }

    static func dismantleNSView(_ nsView: LoopingVideoHostView, coordinator: ()) {
        nsView.teardown()
    }
}

final class LoopingVideoHostView: NSView {
    private var player: AVPlayer?
    private let playerLayer = AVPlayerLayer()
    private let observerBox = NotificationObserverBox()
    private let restartBox = CancellableTaskBox()
    private var currentResourceName: String?
    private var pauseBetweenLoops: TimeInterval = 2.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        player?.pause()
        player = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(resourceName: String, pauseBetweenLoops: TimeInterval) {
        self.pauseBetweenLoops = pauseBetweenLoops
        guard resourceName != currentResourceName else { return }
        currentResourceName = resourceName
        teardown()

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else {
            assertionFailure("\(resourceName).mp4 missing from bundle — check glance/Resources/")
            return
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .pause

        playerLayer.player = newPlayer
        player = newPlayer

        let token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRestart()
            }
        }
        observerBox.add(token)

        newPlayer.seek(to: .zero)
        newPlayer.play()
    }

    private func scheduleRestart() {
        let delay = pauseBetweenLoops
        restartBox.replace(
            with: Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, let player = self.player else { return }
                _ = await player.seek(to: .zero)
                guard !Task.isCancelled else { return }
                player.play()
            }
        )
    }

    func teardown() {
        restartBox.cancel()
        observerBox.removeAll()
        player?.pause()
        player = nil
        playerLayer.player = nil
    }
}
