"use client";

import Image from "next/image";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { PrivacyNotice } from "@/components/privacy-notice";
import styles from "@/components/security-section.module.css";
import { scrollSecurityCards } from "@/lib/carousel";
import { SECURITY_FEATURES, type SecurityFeature } from "@/lib/glance-data";

const assets = "/media/security";

function handleTrackKey(event: KeyboardEvent<HTMLDivElement>) {
  if (event.altKey || event.ctrlKey || event.metaKey) return;

  const track = event.currentTarget;
  switch (event.key) {
    case "ArrowLeft":
      scrollSecurityCards(track, -1);
      break;
    case "ArrowRight":
      scrollSecurityCards(track, 1);
      break;
    case "Home":
      track.scrollTo({ left: 0 });
      break;
    case "End":
      track.scrollTo({ left: track.scrollWidth });
      break;
    default:
      return;
  }

  event.preventDefault();
}

function FeatureTitle({ feature }: { feature: SecurityFeature }) {
  if (!feature.applePrefix) return feature.title;

  return (
    <>
      Encrypted in
      <br />
      <span className={styles.apple} role="img" aria-label="Apple" />
      Keychain.
    </>
  );
}

function SecurityCard({
  feature,
  index,
}: {
  feature: SecurityFeature;
  index: number;
}) {
  const [expanded, setExpanded] = useState(false);
  const detailsId = `security-feature-${index}`;

  return (
    <article
      className={styles.card}
      data-expanded={expanded}
      style={{ animationDelay: `${index * 75}ms` }}
    >
      <div className={styles.cardInner}>
        <div className={styles.front} aria-hidden={expanded}>
          <div className={styles.icon}>
            <Image
              src={`${assets}/${feature.icon}.svg`}
              alt=""
              width={feature.iconSize[0]}
              height={feature.iconSize[1]}
              unoptimized
            />
          </div>
          <h3 className={styles.featureTitle}>
            <FeatureTitle feature={feature} />
          </h3>
          <p className={styles.subtitle}>{feature.subtitle}</p>
        </div>
        <div id={detailsId} className={styles.back} aria-hidden={!expanded}>
          <h3 className={styles.featureTitle}>
            <FeatureTitle feature={feature} />
          </h3>
          <p className={styles.details}>{feature.details}</p>
        </div>
      </div>
      <button
        type="button"
        className={styles.flip}
        aria-expanded={expanded}
        aria-controls={detailsId}
        aria-label={`${expanded ? "Hide details about" : "Show more about"} ${feature.title}`}
        onClick={() => setExpanded(!expanded)}
      >
        <Image
          src={`${assets}/${expanded ? "closeicon" : "plusicon"}.svg`}
          alt=""
          width={40}
          height={40}
          unoptimized
        />
      </button>
    </article>
  );
}

export function SecuritySection() {
  const track = useRef<HTMLDivElement>(null);
  const [entered, setEntered] = useState(false);
  const [scrollEdges, setScrollEdges] = useState({ start: true, end: false });

  useEffect(() => {
    const element = track.current;
    if (!element) return;

    const updateEdges = () => {
      const start = element.scrollLeft <= 3;
      const end =
        element.scrollWidth - element.clientWidth - element.scrollLeft <= 3;
      setScrollEdges((previous) =>
        previous.start === start && previous.end === end
          ? previous
          : { start, end },
      );
    };

    const entrance = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) return;
        setEntered(true);
        entrance.disconnect();
      },
      { threshold: 0.2 },
    );
    const resize = new ResizeObserver(updateEdges);

    entrance.observe(element);
    resize.observe(element);
    element.addEventListener("scroll", updateEdges, { passive: true });

    return () => {
      entrance.disconnect();
      resize.disconnect();
      element.removeEventListener("scroll", updateEdges);
    };
  }, []);

  function move(direction: -1 | 1) {
    if (track.current) scrollSecurityCards(track.current, direction);
  }

  return (
    <section
      id="security"
      className={styles.section}
      aria-labelledby="security-heading"
    >
      <header className={`glance-shell ${styles.heading}`}>
        <h2 id="security-heading" className={styles.title}>
          <span>
            <strong>Security</strong> and <strong>Privacy.</strong>
          </span>
          <span>Your face stays on your</span>
          <span>
            Mac. You stay in <strong>control.</strong>
          </span>
        </h2>
      </header>
      <div id="security-carousel" className={styles.carousel}>
        <div
          id="security-cards"
          ref={track}
          className={styles.track}
          data-entered={entered}
          role="region"
          aria-roledescription="carousel"
          aria-label="Security features"
          tabIndex={0}
          onKeyDown={handleTrackKey}
        >
          {SECURITY_FEATURES.map((feature, index) => (
            <SecurityCard
              key={feature.title}
              feature={feature}
              index={index}
            />
          ))}
        </div>
        <div className={`glance-shell ${styles.controls}`}>
          <button
            type="button"
            aria-controls="security-cards"
            aria-label="Previous security card"
            disabled={scrollEdges.start}
            onClick={() => move(-1)}
          >
            ‹
          </button>
          <button
            type="button"
            aria-controls="security-cards"
            aria-label="Next security card"
            disabled={scrollEdges.end}
            onClick={() => move(1)}
          >
            ›
          </button>
        </div>
      </div>
      <div className={styles.notice}>
        <PrivacyNotice />
      </div>
    </section>
  );
}
