"use client";

import { Pause, Play, Volume2, VolumeX } from "lucide-react";
import { useEffect, useRef, useState } from "react";

export function HeroVideo() {
  const video = useRef<HTMLVideoElement>(null);
  const [muted, setMuted] = useState(true);
  const [paused, setPaused] = useState(true);

  useEffect(() => {
    const player = video.current;
    if (
      !player ||
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      return;
    }
    player.play().catch(() => undefined);
  }, []);

  function togglePlayback() {
    const player = video.current;
    if (!player) return;
    if (player.paused) {
      player.play().catch(() => undefined);
    } else {
      player.pause();
    }
  }

  function toggleSound() {
    const player = video.current;
    if (!player) return;
    player.muted = !player.muted;
    setMuted(player.muted);
  }

  return (
    <div className="glance-hero-player">
      <video
        ref={video}
        src="/media/GlanceLaunchVideoUpdatedSmall.mp4"
        poster="/media/hero/launch-poster.jpg"
        muted
        loop
        playsInline
        preload="metadata"
        aria-label="Glance product launch video"
        onPlay={() => setPaused(false)}
        onPause={() => setPaused(true)}
        onClick={toggleSound}
      />
      <div className="glance-video-controls">
        <button
          type="button"
          onClick={togglePlayback}
          aria-label={paused ? "Play video" : "Pause video"}
        >
          {paused ? <Play size={17} /> : <Pause size={17} />}
        </button>
        <button
          type="button"
          onClick={toggleSound}
          aria-label={muted ? "Unmute video" : "Mute video"}
        >
          {muted ? <VolumeX size={17} /> : <Volume2 size={17} />}
        </button>
      </div>
    </div>
  );
}
