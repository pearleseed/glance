//
//  ScanAnimationView.swift
//  glance
//
//  Plays a scan animation once and holds its final frame — deliberately not
//  looping, since each video ends on a meaningful resolved state.
//

import AVFoundation
import AppKit
import SwiftUI

struct ScanAnimationView: NSViewRepresentable {
    let media: ScanMedia
    var color: UnlockAnimationColor = GlanceSettings.shared.unlockAnimationColor
    var compact: Bool = false

    func makeNSView(context: Context) -> ScanAnimationHostView {
        let view = ScanAnimationHostView()
        view.apply(media: media, color: color, compact: compact)
        return view
    }

    func updateNSView(_ nsView: ScanAnimationHostView, context: Context) {
        nsView.apply(media: media, color: color, compact: compact)
    }

    static func dismantleNSView(_ nsView: ScanAnimationHostView, coordinator: ()) {
        nsView.teardownPlayer()
    }
}

final class ScanAnimationHostView: NSView {
    private var player: AVPlayer?
    private let playerLayer = AVPlayerLayer()
    private let stillImageLayer = CALayer()
    private var currentMedia: ScanMedia?
    private var currentColor: UnlockAnimationColor?
    private var currentCompact: Bool?
    private var readyObservation: NSKeyValueObservation?
    private let fallbackRevealBox = CancellableTaskBox()
    private var compositionTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()

        stillImageLayer.contentsGravity = .resizeAspect
        stillImageLayer.minificationFilter = .trilinear
        layer?.addSublayer(stillImageLayer)

        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        compositionTask?.cancel()
        compositionTask = nil
        readyObservation?.invalidate()
        readyObservation = nil
        player?.pause()
        player = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        stillImageLayer.frame = bounds
        CATransaction.commit()
    }

    func apply(media: ScanMedia, color: UnlockAnimationColor, compact: Bool) {
        let mediaChanged = media != currentMedia
        let colorChanged = color != currentColor
        let compactChanged = compact != currentCompact
        guard mediaChanged || colorChanged || compactChanged else { return }

        let previousColor = currentColor
        currentMedia = media
        currentColor = color
        currentCompact = compact

        if colorChanged || compactChanged {
            if let still = AnimationTint.cachedStill(for: color, compact: compact) {
                stillImageLayer.contents = still
            }
        }

        guard let baseResource = media.videoResourceName else {
            teardownPlayer()
            showStillLayer()
            return
        }

        let tintChanged = color.resolvedTintRGB(for: media) != previousColor?.resolvedTintRGB(for: media)
        guard mediaChanged || compactChanged || tintChanged else { return }

        let resource = compact ? "\(baseResource)-small" : baseResource
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else {
            assertionFailure("\(resource).mp4 missing from bundle — check glance/Resources/")
            return
        }

        startVideoPlayer(url: url, tint: color.resolvedTintRGB(for: media))
    }

    private func showStillLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = true
        stillImageLayer.isHidden = false
        CATransaction.commit()
    }

    private func revealPlayerLayer() {
        // Without disabling implicit actions, toggling `isHidden` cross-fades both
        // layers over CALayer's default duration instead of swapping instantly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = false
        stillImageLayer.isHidden = true
        CATransaction.commit()
    }

    private func startVideoPlayer(url: URL, tint: AnimationTintRGB?) {
        teardownPlayer()
        showStillLayer()

        let item = AVPlayerItem(url: url)
        guard let tint else {
            attachAndPlay(item: item)
            return
        }

        let generation = playbackGeneration
        compositionTask = Task { [weak self] in
            let composition = await AnimationTint.makeVideoComposition(for: item.asset, rgb: tint)
            guard let self, !Task.isCancelled, self.playbackGeneration == generation else { return }
            self.compositionTask = nil
            item.videoComposition = composition
            self.attachAndPlay(item: item)
        }
    }

    private func attachAndPlay(item: AVPlayerItem) {
        let newPlayer = AVPlayer(playerItem: item)
        // This can play at the lock screen — never make noise.
        newPlayer.isMuted = true
        // Leaves the player paused on its final frame rather than rewinding.
        newPlayer.actionAtItemEnd = .none

        playerLayer.player = newPlayer
        player = newPlayer

        // Waits for `isReadyForDisplay` rather than a fixed delay, which raced the
        // real decode time and produced a black-frame flash.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                self?.fallbackRevealBox.cancel()
                self?.revealPlayerLayer()
                self?.readyObservation?.invalidate()
                self?.readyObservation = nil
            }
        }
        // Safety net only — if isReadyForDisplay never fires for some
        // reason, don't get stuck on the still forever.
        fallbackRevealBox.replace(
            with: Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                guard !Task.isCancelled, let self else { return }
                self.revealPlayerLayer()
            }
        )

        newPlayer.seek(to: .zero)
        newPlayer.play()
    }

    func teardownPlayer() {
        playbackGeneration &+= 1
        compositionTask?.cancel()
        compositionTask = nil
        readyObservation?.invalidate()
        readyObservation = nil
        fallbackRevealBox.cancel()
        player?.pause()
        player = nil
        playerLayer.player = nil
    }
}
