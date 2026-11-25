"use client";

import { CheckCircle2, RotateCcw, ScanFace, Terminal } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import styles from "@/components/features-section.module.css";

type SudoStep = "idle" | "scanning" | "verified";

export function SudoPreview() {
  const [step, setStep] = useState<SudoStep>("verified");
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  function runDemo() {
    if (timerRef.current) clearTimeout(timerRef.current);

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setStep("verified");
      return;
    }

    setStep("scanning");
    timerRef.current = setTimeout(() => {
      setStep("verified");
    }, 950);
  }

  return (
    <article className={styles.sudoCard}>
      <div className={styles.cardHeader}>
        <p className={styles.eyebrow}>
          <Terminal size={14} aria-hidden="true" /> Opt-in Face for sudo
        </p>
        <h3>Authenticate Terminal in a glance.</h3>
        <p className={styles.leadDark}>
          Cascades cleanly from Face (Heavy Liveness) to Touch ID and Mac
          password via a bundled universal OpenPAM module — with 1-click Setup,
          Repair, Update, and Uninstall in Settings.
        </p>
      </div>

      <div className={styles.terminal}>
        <div className={styles.terminalBar}>
          <div className={styles.trafficLights} aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <span className={styles.terminalTitle}>zsh — sudo_local</span>
          <button
            type="button"
            className={styles.replayBtn}
            onClick={runDemo}
            aria-label="Replay sudo authentication flow"
          >
            <RotateCcw size={12} aria-hidden="true" />
            {step === "scanning" ? "Scanning…" : "Replay"}
          </button>
        </div>

        <div className={styles.terminalBody} role="status" aria-live="polite">
          <div className={styles.cmdLine}>
            <span className={styles.prompt}>%</span>
            <code>sudo dscacheutil -flushcache</code>
          </div>

          <div
            className={styles.pamStatus}
            data-state={step === "scanning" ? "scanning" : "verified"}
          >
            {step === "scanning" ? (
              <>
                <ScanFace size={15} aria-hidden="true" />
                <span>Glance · Verifying face (Heavy Liveness)…</span>
              </>
            ) : (
              <>
                <CheckCircle2 size={15} aria-hidden="true" />
                <span>Authenticated via pam_glance.so (256-bit nonce)</span>
              </>
            )}
          </div>

          <div className={styles.cascadeRow}>
            <span className={styles.cascadeStepActive}>Face (Heavy)</span>
            <span aria-hidden="true">→</span>
            <span className={styles.cascadeStep}>Touch ID</span>
            <span aria-hidden="true">→</span>
            <span className={styles.cascadeStep}>Password</span>
          </div>
        </div>
      </div>

      <div className={styles.sudoChips}>
        <span>1-Click Setup</span>
        <span>Universal pam_glance.so</span>
        <span>/etc/pam.d/sudo_local</span>
        <span>Zero password injection</span>
      </div>
    </article>
  );
}
