//
//  ScanAnimationView.swift
//  glance
//
//  Plays a scan animation once and holds its final frame — deliberately not
//  looping, since each video ends on a meaningful resolved state.
//

import SwiftUI
import AVFoundation
import AppKit

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
    private var fallbackRevealWorkItem: DispatchWorkItem?

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
        readyObservation?.invalidate()
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()
        fallbackRevealWorkItem = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
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
            if let still = Self.loadStillFromBundle(compact: compact) {
                stillImageLayer.contents = AnimationTint.apply(
                    color.resolvedTintRGB(for: .idle),
                    to: still
                )
            }
        }

        guard let baseResource = media.videoResourceName else {
            teardownPlayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.isHidden = true
            stillImageLayer.isHidden = false
            CATransaction.commit()
            return
        }

        let tintChanged = color.resolvedTintRGB(for: media) != previousColor?.resolvedTintRGB(for: media)
        guard mediaChanged || compactChanged || tintChanged else { return }

        let resource = compact ? "\(baseResource)-small" : baseResource
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else {
            assertionFailure("\(resource).mp4 missing from bundle — check glance/Resources/")
            return
        }

        teardownPlayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = true
        stillImageLayer.isHidden = false
        CATransaction.commit()

        let item = AVPlayerItem(url: url)
        item.videoComposition = AnimationTint.videoComposition(
            for: item.asset,
            rgb: color.resolvedTintRGB(for: media)
        )
        let newPlayer = AVPlayer(playerItem: item)
        // This can play at the lock screen — never make noise.
        newPlayer.isMuted = true
        // Leaves the player paused on its final frame rather than rewinding.
        newPlayer.actionAtItemEnd = .none

        playerLayer.player = newPlayer
        player = newPlayer

        // Waits for `isReadyForDisplay` rather than a fixed delay, which raced the
        // real decode time and produced a black-frame flash.
        let reveal: () -> Void = { [weak self] in
            guard let self else { return }
            // Without disabling implicit actions, toggling `isHidden` cross-fades both
            // layers over CALayer's default duration instead of swapping instantly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.playerLayer.isHidden = false
            self.stillImageLayer.isHidden = true
            CATransaction.commit()
        }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                self?.fallbackRevealWorkItem?.cancel()
                self?.fallbackRevealWorkItem = nil
                reveal()
                self?.readyObservation?.invalidate()
                self?.readyObservation = nil
            }
        }
        // Safety net only — if isReadyForDisplay never fires for some
        // reason, don't get stuck on the still forever.
        let fallback = DispatchWorkItem { reveal() }
        fallbackRevealWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)

        newPlayer.seek(to: .zero)
        newPlayer.play()
    }

    func teardownPlayer() {
        readyObservation?.invalidate()
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()
        fallbackRevealWorkItem = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
    }

    /// The asset lives in Resources/ rather than an asset catalog, so
    /// `NSImage(named:)` won't find it — load by URL instead.
    private static func loadStillFromBundle(compact: Bool) -> NSImage? {
        let resource = compact ? "unlockstatic-small" : "unlockstatic"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
