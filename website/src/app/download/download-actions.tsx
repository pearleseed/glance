"use client";

import { Cpu, Download, ExternalLink, ShieldCheck } from "lucide-react";
import Image from "next/image";
import { useEffect, useRef, useState, type MouseEvent } from "react";
import styles from "@/app/download/download.module.css";
import { formatMegabytes } from "@/lib/github";
import { GLANCE_REPO, type GlanceReleaseData } from "@/lib/glance-data";

type MacArch = "arm64" | "x86_64" | null;

function detectMacArchitecture(): MacArch {
  if (typeof navigator === "undefined") return null;
  const ua = navigator.userAgent;
  if (!/Macintosh|Mac OS X/i.test(ua)) return null;

  try {
    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl");
    if (gl) {
      const debugInfo = gl.getExtension("WEBGL_debug_renderer_info");
      const renderer = debugInfo
        ? String(gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL))
        : String(gl.getParameter(gl.RENDERER));
      if (/Apple M\d|Apple GPU/i.test(renderer)) return "arm64";
      if (/Intel|AMD|Radeon/i.test(renderer)) return "x86_64";
    }
  } catch {
    return null;
  }

  return null;
}

export function DownloadActions({ release }: { release: GlanceReleaseData }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [detectedArch, setDetectedArch] = useState<MacArch>(null);

  useEffect(() => {
    const frame = requestAnimationFrame(() => {
      setDetectedArch(detectMacArchitecture());
    });
    return () => cancelAnimationFrame(frame);
  }, []);

  function showDownloadNotice(event: MouseEvent<HTMLAnchorElement>) {
    if (
      event.altKey ||
      event.ctrlKey ||
      event.metaKey ||
      event.shiftKey ||
      !window.matchMedia("(max-width: 700px)").matches ||
      !dialog.current
    ) {
      return;
    }

    event.preventDefault();
    dialog.current.showModal();
  }

  const arm64Size = formatMegabytes(release.arm64.sizeBytes);
  const x86Size = formatMegabytes(release.x86_64.sizeBytes);

  return (
    <>
      <div className={`glance-shell ${styles.actions}`}>
        <div className={styles.downloadRow}>
          <a
            className={`glance-pill glance-pill-dark ${styles.downloadLink}`}
            href={release.arm64.url}
            onClick={showDownloadNotice}
          >
            <Download size={18} aria-hidden="true" />
            <span>Apple Silicon (arm64)</span>
            {arm64Size && <small className={styles.sizeTag}>{arm64Size}</small>}
            {detectedArch === "arm64" && (
              <span className={styles.matchBadge}>Your Mac</span>
            )}
          </a>

          <a
            className={`glance-pill ${
              detectedArch === "x86_64" ? "glance-pill-dark" : ""
            } ${styles.downloadLink}`}
            href={release.x86_64.url}
            onClick={showDownloadNotice}
          >
            <Cpu size={18} aria-hidden="true" />
            <span>Intel (x86_64)</span>
            {x86Size && <small className={styles.sizeTag}>{x86Size}</small>}
            {detectedArch === "x86_64" && (
              <span className={styles.matchBadge}>Your Mac</span>
            )}
          </a>

          <a
            className="glance-pill"
            href={GLANCE_REPO.url}
            target="_blank"
            rel="noopener noreferrer"
          >
            GitHub
          </a>
        </div>

        <div className={styles.metaRow}>
          <span>macOS 14 Sonoma or later</span>
          <span aria-hidden="true">·</span>
          <span>Version {release.version}</span>
          <span aria-hidden="true">·</span>
          <a
            href={release.checksumsUrl}
            target="_blank"
            rel="noopener noreferrer"
          >
            <ShieldCheck size={14} aria-hidden="true" />
            SHA256SUMS.txt
          </a>
          <span aria-hidden="true">·</span>
          <a
            href={release.releaseUrl}
            target="_blank"
            rel="noopener noreferrer"
          >
            <ExternalLink size={14} aria-hidden="true" />
            Release Notes
          </a>
        </div>
      </div>

      <dialog
        aria-labelledby="download-notice"
        className={styles.dialog}
        ref={dialog}
        onClick={(event) => {
          if (event.target === event.currentTarget) {
            event.currentTarget.close();
          }
        }}
      >
        <div className={styles.sheet}>
          <Image
            src="/apple-icon.png"
            alt=""
            width={56}
            height={56}
            unoptimized
            loading="eager"
          />
          <p id="download-notice" className={styles.message}>
            Glance is built for macOS 14+. Open this page on your Mac to install
            it, or download an installer directly:
          </p>
          <div className={styles.sheetLinks}>
            <a className={styles.releaseLink} href={release.arm64.url}>
              Apple Silicon ({release.arm64.name})
            </a>
            <a className={styles.releaseLink} href={release.x86_64.url}>
              Intel ({release.x86_64.name})
            </a>
          </div>
          <form method="dialog">
            <button className="glance-pill glance-pill-dark" type="submit">
              Close
            </button>
          </form>
        </div>
      </dialog>
    </>
  );
}
