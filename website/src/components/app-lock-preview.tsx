"use client";

import { Fingerprint, Lock, ScanFace, ShieldCheck, Unlock } from "lucide-react";
import { useState } from "react";
import styles from "@/components/features-section.module.css";

const relockPolicies = [
  {
    id: "every-time",
    label: "Every time",
    note: "Curtain re-engages the moment you switch away from the app.",
  },
  {
    id: "5-min",
    label: "After 5 min",
    note: "Monotonic uptime timer — system clock edits cannot bypass locks.",
  },
  {
    id: "after-leaving",
    label: "5 min after leaving",
    note: "Stays unlocked briefly between quick switches; revokes on sleep or lock.",
  },
] as const;

type RelockId = (typeof relockPolicies)[number]["id"];

export function AppLockPreview() {
  const [locked, setLocked] = useState(true);
  const [policy, setPolicy] = useState<RelockId>("every-time");

  const activePolicy =
    relockPolicies.find((item) => item.id === policy) ?? relockPolicies[0];

  return (
    <article className={styles.appLockCard}>
      <div className={styles.cardHeader}>
        <p className={styles.eyebrow}>
          <Lock size={14} aria-hidden="true" /> Opt-in App Lock
        </p>
        <h3>Lock individual apps behind your face.</h3>
        <p className={styles.lead}>
          Per-window privacy curtains cover only the locked app at its exact
          z-order — no Screen Recording permission needed, other apps stay
          unobstructed, and Mission Control auto-hides challenged windows.
        </p>
      </div>

      <div className={styles.desktopStage}>
        <div className={styles.backWindow} aria-hidden="true">
          <div className={styles.windowChrome}>
            <span />
            <span />
            <span />
            <small>Notes — Unobstructed</small>
          </div>
          <div className={styles.notesBody}>
            <div className={styles.skeletonLineWide} />
            <div className={styles.skeletonLine} />
            <div className={styles.skeletonLineShort} />
          </div>
        </div>

        <div className={styles.frontWindow} data-locked={locked}>
          <div className={styles.windowChrome}>
            <span />
            <span />
            <span />
            <small>Messages {locked ? "· Protected" : "· Unlocked"}</small>
            {!locked && (
              <button
                type="button"
                className={styles.relockBtn}
                onClick={() => setLocked(true)}
              >
                <Lock size={12} aria-hidden="true" /> Re-lock
              </button>
            )}
          </div>

          <div className={styles.windowContent}>
            <div className={styles.messagesBody} aria-hidden={locked}>
              <div className={styles.bubbleIn}>
                Flight confirmation &amp; boarding pass attached.
              </div>
              <div className={styles.bubbleOut}>
                Got it — unlocked straight from the curtain.
              </div>
            </div>

            {locked && (
              <div className={styles.curtain}>
                <div className={styles.curtainBadge}>
                  <ScanFace size={22} aria-hidden="true" />
                </div>
                <strong>Messages is locked</strong>
                <span>Per-window curtain · Zero extra model RAM</span>
                <div className={styles.curtainActions}>
                  <button
                    type="button"
                    className={styles.curtainPrimary}
                    onClick={() => setLocked(false)}
                  >
                    <Unlock size={14} aria-hidden="true" /> Unlock with Face
                  </button>
                  <button
                    type="button"
                    className={styles.curtainSecondary}
                    onClick={() => setLocked(false)}
                  >
                    <Fingerprint size={14} aria-hidden="true" /> Touch ID
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      <div className={styles.policyBox}>
        <div
          className={styles.policyPills}
          role="group"
          aria-label="Relock policy presets"
        >
          {relockPolicies.map((item) => (
            <button
              key={item.id}
              type="button"
              aria-pressed={policy === item.id}
              onClick={() => setPolicy(item.id)}
            >
              {item.label}
            </button>
          ))}
        </div>
        <p className={styles.policyNote}>
          <ShieldCheck size={14} aria-hidden="true" />
          <span>
            {activePolicy.note} Critical apps (Finder, Terminal, System
            Settings) are protected from lockouts.
          </span>
        </p>
      </div>
    </article>
  );
}
