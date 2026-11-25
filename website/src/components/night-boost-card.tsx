"use client";

import { Moon, Sun } from "lucide-react";
import { useState } from "react";

export function NightBoostCard() {
  const [enabled, setEnabled] = useState(true);

  return (
    <article className="glance-night-card">
      <div>
        <p className="glance-card-eyebrow">
          <Moon size={14} aria-hidden="true" /> Opt-in low-light mode
        </p>
        <h3>Night Boost</h3>
        <p>
          Softly illuminates the top 38% of your display in dark rooms, boosts
          low-light frames without contaminating glare checks, and restores
          brightness the moment you unlock.
        </p>
      </div>

      <div
        className="glance-night-screen"
        data-boost={enabled}
        aria-label={
          enabled
            ? "Lock screen preview with Night Boost illuminating the top 38 percent"
            : "Lock screen preview in a dark room with Night Boost off"
        }
      >
        <div className="glance-night-glow" aria-hidden="true" />
        <div className="glance-night-notch" aria-hidden="true">
          <span />
        </div>
        <div className="glance-night-clock" aria-hidden="true">
          10:42
        </div>
        <div className="glance-night-field" aria-hidden="true">
          Enter Password
        </div>
      </div>

      <div className="glance-night-footer">
        <button
          type="button"
          className="glance-night-toggle"
          aria-pressed={enabled}
          onClick={() => setEnabled((current) => !current)}
        >
          {enabled ? (
            <Sun size={15} aria-hidden="true" />
          ) : (
            <Moon size={15} aria-hidden="true" />
          )}
          Night Boost: {enabled ? "On" : "Off"}
        </button>
        <span className="glance-night-hint">
          Top 38% glow · Password box stays clear
        </span>
      </div>
    </article>
  );
}
