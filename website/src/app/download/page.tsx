import type { Metadata } from "next";
import { CopyCommand } from "@/app/download/copy-command";
import { DownloadActions } from "@/app/download/download-actions";
import styles from "@/app/download/download.module.css";
import { PrivacyNotice } from "@/components/privacy-notice";
import { getGlanceReleaseData } from "@/lib/github";
import { XATTR_COMMAND } from "@/lib/glance-data";

export const revalidate = 3600;

export const metadata: Metadata = {
  title: "Download",
  description:
    "Download Glance for macOS 14 Sonoma+ (Apple Silicon arm64 and Intel x86_64) with bundled universal sudo PAM support.",
};

export default async function DownloadPage() {
  const release = await getGlanceReleaseData();

  return (
    <main className={styles.page}>
      <header className={`glance-shell ${styles.intro}`}>
        <p className={styles.eyebrow}>Download · {release.version}</p>
        <h1 className={styles.heading}>Important</h1>
        <p className={styles.summary}>
          Glance brings on-device Face Unlock, per-window App Lock, and opt-in
          Face-for-sudo to macOS 14+. Everything stays local on your Mac, with
          the hardware security limits explained below.
        </p>
      </header>

      <PrivacyNotice />
      <DownloadActions release={release} />

      <section
        className={`glance-shell ${styles.setupCard}`}
        aria-labelledby="setup-heading"
      >
        <h2 id="setup-heading">First-launch installation</h2>
        <p className={styles.setupSubtitle}>
          Community builds are ad-hoc signed (not notarized with a paid Apple
          Developer ID), and bundle universal <code>pam_glance.so</code> inside
          the app for 1-click sudo setup.
        </p>

        <ol className={styles.steps}>
          <li className={styles.step}>
            <span className={styles.stepNumber}>1</span>
            <div className={styles.stepBody}>
              <h3>Install into Applications</h3>
              <p>
                Open the downloaded <code>.dmg</code> matching your Mac and drag{" "}
                <strong>Glance.app</strong> to <code>/Applications</code>.
              </p>
            </div>
          </li>

          <li className={styles.step}>
            <span className={styles.stepNumber}>2</span>
            <div className={styles.stepBody}>
              <h3>Clear macOS Gatekeeper quarantine once</h3>
              <p>
                Run this single command in Terminal before opening Glance for
                the first time:
              </p>
              <CopyCommand command={XATTR_COMMAND} />
            </div>
          </li>

          <li className={styles.step}>
            <span className={styles.stepNumber}>3</span>
            <div className={styles.stepBody}>
              <h3>Enroll &amp; configure</h3>
              <p>
                Launch <strong>Glance</strong>, complete the circular 9-pose
                enrollment, and optionally enable <strong>App Lock</strong> or{" "}
                <strong>1-click Face-for-sudo</strong> in Settings.
              </p>
            </div>
          </li>
        </ol>

        <div className={styles.upgradeNote}>
          <strong>Upgrading from v2.0?</strong> Glance v2.1+ upgrades from
          MobileFaceNet to ResNet50 (<code>ArcFace w600k_r50</code> W8A16).
          Previously enrolled faces are automatically marked stale and require a
          quick one-time re-enrollment for the improved accuracy.
        </div>
      </section>
    </main>
  );
}
