import { Cpu } from "lucide-react";
import { AppLockPreview } from "@/components/app-lock-preview";
import styles from "@/components/features-section.module.css";
import { SudoPreview } from "@/components/sudo-preview";
import { ENGINE_METRICS } from "@/lib/glance-data";

export function FeaturesSection() {
  return (
    <section
      id="features"
      className={`glance-shell ${styles.section}`}
      aria-labelledby="glance-features-title"
    >
      <h2 id="glance-features-title" className="glance-section-title">
        <span>Beyond </span>the lock screen.
        <br />
        <span>Apps, </span>sudo<span>, and </span>speed.
      </h2>

      <div className={styles.topGrid}>
        <AppLockPreview />
        <SudoPreview />
      </div>

      <article className={styles.engineCard}>
        <div className={styles.engineCopy}>
          <p className={styles.eyebrow}>
            <Cpu size={14} aria-hidden="true" /> ArcFace w600k_r50 · W8A16 Core
            ML
          </p>
          <h3>ResNet50 accuracy. Built to stay invisible.</h3>
          <p className={styles.lead}>
            Glance runs an upgraded ResNet50 model quantized to W8A16 with
            native-resolution 512 px crops for naturally seated posture and
            wide-angle Studio Displays — plus an optional Strict close range
            mode. Event-driven frames and deadline timers replace legacy polling
            loops so idle energy stays near zero.
          </p>
        </div>

        <dl className={styles.metricsGrid}>
          {ENGINE_METRICS.map((metric) => (
            <div key={metric.label} className={styles.metricTile}>
              <dt>{metric.label}</dt>
              <dd className={styles.metricValue}>{metric.value}</dd>
              <dd className={styles.metricDetail}>{metric.detail}</dd>
            </div>
          ))}
        </dl>
      </article>
    </section>
  );
}
