"use client";

import { Cpu, Download, ExternalLink, ShieldCheck } from "lucide-react";
import Image from "next/image";
import { useEffect, useRef, useState, type MouseEvent } from "react";
import styles from "@/app/download/download.module.css";
import { resolveArchDownload } from "@/lib/download-model";
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

  const archEntries = [
    {
      key: "arm64" as const,
      buttonLabel: "Apple Silicon (arm64)",
      sheetName: "Apple Silicon",
      icon: Download,
      action: resolveArchDownload(release.arm64, release),
      isDark: true,
    },
    {
      key: "x86_64" as const,
      buttonLabel: "Intel (x86_64)",
      sheetName: "Intel",
      icon: Cpu,
      action: resolveArchDownload(release.x86_64, release),
      isDark: detectedArch === "x86_64",
    },
  ];

  return (
    <>
      <div className={`glance-shell ${styles.actions}`}>
        <div className={styles.downloadRow}>
          {archEntries.map(({ key, buttonLabel, icon: Icon, action, isDark }) => (
            <a
              key={key}
              className={`glance-pill ${isDark ? "glance-pill-dark" : ""} ${styles.downloadLink}`}
              href={action.href}
              target={action.isDirectDownload ? undefined : "_blank"}
              rel={action.isDirectDownload ? undefined : "noopener noreferrer"}
              onClick={action.isDirectDownload ? showDownloadNotice : undefined}
            >
              <Icon size={18} aria-hidden="true" />
              <span>{buttonLabel}</span>
              {action.badgeText && (
                <small className={styles.sizeTag}>{action.badgeText}</small>
              )}
              {detectedArch === key && (
                <span className={styles.matchBadge}>Your Mac</span>
              )}
            </a>
          ))}

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
          {release.checksumsUrl !== null && (
            <>
              <span aria-hidden="true">·</span>
              <a
                href={release.checksumsUrl}
                target="_blank"
                rel="noopener noreferrer"
              >
                <ShieldCheck size={14} aria-hidden="true" />
                SHA256SUMS.txt
              </a>
            </>
          )}
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
            {archEntries.map(({ key, sheetName, action }) => (
              <a
                key={key}
                className={styles.releaseLink}
                href={action.href}
                target={action.isDirectDownload ? undefined : "_blank"}
                rel={action.isDirectDownload ? undefined : "noopener noreferrer"}
              >
                {action.sheetLabel(sheetName)}
              </a>
            ))}
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
