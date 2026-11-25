import { Monitor } from "lucide-react";
import Image from "next/image";
import { DesignMotion } from "@/components/design-motion";
import { NightBoostCard } from "@/components/night-boost-card";

const assets = "/media/design/";
const features = [
  { icon: "haptic.svg", width: 67, height: 56, label: "Haptic feedback" },
  { icon: "heart.svg", width: 63, height: 56, label: "Dynamic colors" },
  { icon: "bolt.svg", width: 40, height: 57, label: "Instant unlocks" },
];
const identities = [
  { image: "identity2.png", alt: "Identity with a face mask" },
  { image: "identity3.png", alt: "Primary user identity with quality score" },
  { image: "identity1.png", alt: "Identity with sunglasses" },
];

export function DesignSection() {
  return (
    <section
      id="design"
      className="glance-shell glance-design"
      aria-labelledby="glance-design-title"
    >
      <h2 id="glance-design-title" className="glance-section-title">
        <span>With the </span>convenience
        <br />
        <span>and </span>design<span> of your </span>iPhone
      </h2>

      <div className="glance-design-grid">
        <div className="glance-design-overview">
          <DesignMotion />
          <div className="glance-design-features">
            {features.map(({ icon, width, height, label }) => (
              <div key={icon}>
                <Image
                  src={assets + icon}
                  alt=""
                  width={width}
                  height={height}
                />
                <p>{label}</p>
              </div>
            ))}
          </div>
        </div>

        <figure className="glance-design-device">
          <Image src={`${assets}lockscreen.png`} alt="" fill unoptimized />
          <figcaption>
            <strong>Lock screen ready</strong>
            <p>
              Trigger on wake, on lock, pressing Space, or returning from a
              screensaver — across built-in and external displays.
            </p>
          </figcaption>
        </figure>

        <figure className="glance-design-native">
          <Image src={`${assets}nativeapp.png`} alt="" fill unoptimized />
          <figcaption>
            <strong>
              Native
              <br />
              App
            </strong>
            <span className="glance-design-native-sub">
              SwiftUI · macOS 14+ · Apple Silicon &amp; Intel
            </span>
          </figcaption>
        </figure>

        <article className="glance-design-identities">
          <div className="glance-identity-copy">
            <h3>Identities</h3>
            <p>
              Enroll in one smooth circular 9-pose sweep with neutral-angle
              calibration and pose-aware quality grades. Add multiple people or
              looks and pause any profile anytime.
            </p>
          </div>
          <ul className="glance-identity-list">
            {identities.map(({ image, alt }) => (
              <li key={image}>
                <Image
                  src={assets + image}
                  alt={alt}
                  width={612}
                  height={158}
                  unoptimized
                />
              </li>
            ))}
          </ul>
        </article>
      </div>

      <div className="glance-design-extras">
        <NightBoostCard />

        <article className="glance-controls-card">
          <div>
            <p className="glance-card-eyebrow">
              <Monitor size={14} aria-hidden="true" /> Built for every desk
              setup
            </p>
            <h3>Displays, Cameras &amp; Triggers</h3>
            <p>
              Gate Face Unlock by display topology, auto-switch cameras in
              clamshell mode, and toggle Glance instantly from anywhere.
            </p>
          </div>

          <div className="glance-controls-rows">
            <div className="glance-control-row">
              <span className="glance-control-label">Active when</span>
              <div className="glance-chip-list">
                <span className="glance-chip glance-chip-active">
                  Built-in only
                </span>
                <span className="glance-chip glance-chip-active">
                  Built-in + external
                </span>
                <span className="glance-chip">External only (Clamshell)</span>
              </div>
            </div>

            <div className="glance-control-row">
              <span className="glance-control-label">
                Triggers &amp; Hot-Plug Cameras
              </span>
              <div className="glance-chip-list">
                <span className="glance-chip">On wake</span>
                <span className="glance-chip">On lock</span>
                <span className="glance-chip">Space key</span>
                <span className="glance-chip">Screensaver</span>
                <span className="glance-chip">Continuity Camera</span>
              </div>
            </div>

            <div className="glance-control-row">
              <span className="glance-control-label">
                Global Toggle &amp; Menu Bar
              </span>
              <div className="glance-chip-list">
                <span className="glance-kbd-group" aria-label="Control Option Command F">
                  <kbd className="glance-kbd">⌃</kbd>
                  <kbd className="glance-kbd">⌥</kbd>
                  <kbd className="glance-kbd">⌘</kbd>
                  <kbd className="glance-kbd">F</kbd>
                </span>
                <span className="glance-chip">Hideable menu bar icon</span>
                <span className="glance-chip">⌘, Settings</span>
              </div>
            </div>
          </div>
        </article>
      </div>
    </section>
  );
}
