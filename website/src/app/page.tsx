import Image from "next/image";
import Link from "next/link";
import { DesignSection } from "@/components/design-section";
import { FeaturesSection } from "@/components/features-section";
import { Frost } from "@/components/frost";
import { HeroVideo } from "@/components/hero-video";
import { SecuritySection } from "@/components/security-section";
import { formatCompactCount, getGlanceReleaseData } from "@/lib/github";
import { GLANCE_REPO } from "@/lib/glance-data";

export const revalidate = 3600;

export default async function Home() {
  const release = await getGlanceReleaseData();

  return (
    <main>
      <section
        className="glance-shell glance-hero"
        aria-labelledby="glance-title"
      >
        <Frost />
        <h1 id="glance-title" className="glance-headline">
          <span>Face Unlock.</span>
          <span>
            For your{" "}
            <Image
              src="/media/hero/appleicon.svg"
              width={54}
              height={63}
              alt=""
            />
            Mac.
          </span>
        </h1>
        <p className="glance-hero-tagline">
          Face unlock, per-window App Lock, and 1-click Face-for-sudo — running
          100% on-device with ArcFace w600k_r50.
        </p>
        <div className="glance-hero-actions">
          <Link
            className="glance-pill glance-pill-dark glance-hero-download"
            href="/download"
          >
            Download for Mac
          </Link>
          <div className="glance-hero-meta">
            <a
              className="glance-pill"
              href={GLANCE_REPO.url}
              target="_blank"
              rel="noopener noreferrer"
            >
              GitHub
            </a>
            <a
              className="glance-pill"
              href={release.releaseUrl}
              target="_blank"
              rel="noopener noreferrer"
              aria-label={`Latest release ${release.version}`}
            >
              {release.version}
            </a>
            <Link className="glance-pill" href="/download">
              macOS 14+
            </Link>
            {release.stars > 0 && (
              <a
                className="glance-pill"
                href={GLANCE_REPO.url}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={`${release.stars} stars on GitHub`}
              >
                <Image
                  src="/media/hero/staricon.svg"
                  width={18}
                  height={18}
                  alt=""
                />
                {formatCompactCount(release.stars)}
              </a>
            )}
            {release.downloads > 0 && (
              <a
                className="glance-pill"
                href={release.releaseUrl}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={`${release.downloads} downloads on GitHub`}
              >
                <Image
                  src="/media/hero/downloadicon.svg"
                  width={17}
                  height={18}
                  alt=""
                />
                {formatCompactCount(release.downloads)}
              </a>
            )}
          </div>
        </div>
        <div className="glance-hero-frame">
          <HeroVideo />
        </div>
      </section>

      <DesignSection />
      <FeaturesSection />
      <SecuritySection />

      <section
        className="glance-shell glance-end"
        aria-labelledby="glance-open-source"
      >
        <h2 id="glance-open-source">Glance is open-source.</h2>
        <div className="glance-hero-actions">
          <Link className="glance-pill glance-pill-dark" href="/download">
            Download for Mac
          </Link>
          <a
            className="glance-pill"
            href={GLANCE_REPO.url}
            target="_blank"
            rel="noopener noreferrer"
          >
            GitHub
          </a>
          <a
            className="glance-pill"
            href={release.releaseUrl}
            target="_blank"
            rel="noopener noreferrer"
          >
            Releases ({release.version})
          </a>
        </div>
        <p className="glance-end-credit">
          MIT License · pearleseed/glance · Originally created by Jonathan Zhou
        </p>
      </section>
    </main>
  );
}
