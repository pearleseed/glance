"use client";

import { ChevronLeft, ChevronRight, Sparkles } from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { scrollSecurityCards } from "@/lib/carousel";

const navAssets = "/media/navbar/";

export function SiteNav() {
  const pathname = usePathname();
  const [carouselVisible, setCarouselVisible] = useState(false);
  const [edges, setEdges] = useState({ first: true, last: false });
  const showArrows = pathname === "/" && carouselVisible;

  useEffect(() => {
    const track = document.getElementById("security-cards");
    if (pathname !== "/" || !track) return;

    const updateEdges = () => {
      const first = track.scrollLeft < 2;
      const last =
        track.scrollLeft + track.clientWidth >= track.scrollWidth - 2;
      setEdges((previous) =>
        previous.first === first && previous.last === last
          ? previous
          : { first, last },
      );
    };

    const intersection = new IntersectionObserver(
      ([entry]) => {
        setCarouselVisible(entry.isIntersecting);
        updateEdges();
      },
      { threshold: 0.35 },
    );
    const resize = new ResizeObserver(updateEdges);

    track.addEventListener("scroll", updateEdges, { passive: true });
    intersection.observe(track);
    resize.observe(track);

    return () => {
      intersection.disconnect();
      resize.disconnect();
      track.removeEventListener("scroll", updateEdges);
    };
  }, [pathname]);

  function step(direction: -1 | 1) {
    const track = document.getElementById("security-cards");
    if (track) scrollSecurityCards(track, direction);
  }

  return (
    <nav className="glance-nav" aria-label="Primary">
      <div className="glance-nav-cluster" data-carousel={showArrows}>
        <Link className="glance-brand" href="/">
          Glance
        </Link>
        <div className="glance-nav-links">
          <Link
            href="/#design"
            className="glance-nav-item"
            aria-label="Design"
          >
            <Image
              src={`${navAssets}hearticon.svg`}
              width={15}
              height={13}
              alt=""
            />
            <span>Design</span>
          </Link>
          <Link
            href="/#features"
            className="glance-nav-item"
            aria-label="Features"
          >
            <Sparkles size={14} strokeWidth={2.2} aria-hidden="true" />
            <span>Features</span>
          </Link>
          <Link
            href="/#security"
            className="glance-nav-item"
            aria-label="Security"
          >
            <Image
              src={`${navAssets}lockicon.svg`}
              width={13}
              height={13}
              alt=""
            />
            <span>Security</span>
          </Link>
          <Link
            href="/feedback"
            className="glance-nav-item glance-nav-feedback"
            aria-label="Feedback"
            aria-current={pathname === "/feedback" ? "page" : undefined}
          >
            <Image
              src={`${navAssets}feedbackicon.svg`}
              width={16}
              height={15}
              alt=""
            />
          </Link>
          <Link
            href="/download"
            className="glance-nav-item glance-nav-download"
            aria-current={pathname === "/download" ? "page" : undefined}
          >
            Download
          </Link>
        </div>
        {showArrows && (
          <div className="glance-nav-arrows">
            <button
              type="button"
              aria-label="Previous security card"
              disabled={edges.first}
              onClick={() => step(-1)}
            >
              <ChevronLeft size={20} aria-hidden="true" />
            </button>
            <button
              type="button"
              aria-label="Next security card"
              disabled={edges.last}
              onClick={() => step(1)}
            >
              <ChevronRight size={20} aria-hidden="true" />
            </button>
          </div>
        )}
      </div>
    </nav>
  );
}
