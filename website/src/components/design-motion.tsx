"use client";

import Image from "next/image";
import { useEffect, useRef, useState } from "react";

const media = "/media/design/";
const statuses = ["unlockanimation", "unsuccessfulunlockanimation"] as const;

type NotchStyle = "all" | "expanded" | "minimal" | "headless";
type TintMode = "blue" | "green" | "blue-green";

const styleOptions: readonly { id: NotchStyle; label: string }[] = [
  { id: "all", label: "All" },
  { id: "expanded", label: "Expanded" },
  { id: "minimal", label: "Minimal" },
  { id: "headless", label: "Headless" },
];

const tintOptions: readonly {
  id: TintMode;
  label: string;
  swatchClass: string;
}[] = [
  { id: "blue", label: "Blue", swatchClass: "glance-swatch-blue" },
  { id: "green", label: "Green", swatchClass: "glance-swatch-green" },
  { id: "blue-green", label: "Blue → Green", swatchClass: "glance-swatch-dual" },
];

export function DesignMotion() {
  const card = useRef<HTMLDivElement>(null);
  const [styleMode, setStyleMode] = useState<NotchStyle>("all");
  const [tint, setTint] = useState<TintMode>("blue-green");

  useEffect(() => {
    const container = card.current;
    if (!container) return;

    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let visible = false;

    function syncPlayback() {
      if (!container) return;
      const videos = container.querySelectorAll("video");
      videos.forEach((video) => {
        if (visible && !motion.matches) {
          video.play().catch(() => undefined);
        } else {
          video.pause();
        }
      });
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        syncPlayback();
      },
      { threshold: 0.2 },
    );

    observer.observe(container);
    motion.addEventListener("change", syncPlayback);
    return () => {
      observer.disconnect();
      motion.removeEventListener("change", syncPlayback);
    };
  }, [styleMode]);

  const expandedTintClass = tint === "green" ? "glance-tint-green" : "";
  const unlockTintClass =
    tint === "green" || tint === "blue-green" ? "glance-tint-green" : "";

  return (
    <div className="glance-design-modes-card" ref={card}>
      <div className="glance-design-toolbar">
        <div
          className="glance-segmented"
          role="group"
          aria-label="Notch animation style"
        >
          {styleOptions.map((option) => (
            <button
              key={option.id}
              type="button"
              aria-pressed={styleMode === option.id}
              onClick={() => setStyleMode(option.id)}
            >
              {option.label}
            </button>
          ))}
        </div>
        <div
          className="glance-segmented"
          role="group"
          aria-label="Dynamic animation color"
        >
          {tintOptions.map((option) => (
            <button
              key={option.id}
              type="button"
              aria-pressed={tint === option.id}
              onClick={() => setTint(option.id)}
            >
              <span
                className={`glance-swatch ${option.swatchClass}`}
                aria-hidden="true"
              />
              {option.label}
            </button>
          ))}
        </div>
      </div>

      <div className="glance-design-stage">
        {styleMode === "headless" ? (
          <div className="glance-design-headless">
            <div className="glance-headless-bar">
              <span className="glance-headless-dot" aria-hidden="true" />
              Headless Mode · Zero Overlay
            </div>
            <p>
              Turn notch and pill animations off completely for silent
              background unlocks with instant haptic feedback.
            </p>
          </div>
        ) : (
          <>
            <div
              className="glance-design-mode"
              data-dimmed={styleMode === "minimal"}
            >
              <video
                className={`glance-design-expanded ${expandedTintClass}`}
                src={`${media}idleanimation.mp4`}
                poster={`${media}idleanimation.jpg`}
                loop
                muted
                playsInline
                preload="none"
                aria-hidden="true"
              />
              <p>Expanded</p>
            </div>
            <div
              className="glance-design-mode"
              data-dimmed={styleMode === "expanded"}
            >
              <div className="glance-design-pills">
                {statuses.map((status) => (
                  <div className="glance-design-demo-pill" key={status}>
                    <Image
                      src={`${media}lockicon.svg`}
                      alt=""
                      width={15}
                      height={20}
                    />
                    <video
                      className={
                        status === "unlockanimation" ? unlockTintClass : ""
                      }
                      src={`${media}${status}.mp4`}
                      poster={`${media}${status}.jpg`}
                      loop
                      muted
                      playsInline
                      preload="none"
                      aria-hidden="true"
                    />
                  </div>
                ))}
              </div>
              <p>Minimal</p>
            </div>
          </>
        )}
      </div>

      <p className="glance-design-footnote">
        ±20 pt notch width &amp; height tuning · Auto-adapts to a floating pill
        on external displays
      </p>
    </div>
  );
}
