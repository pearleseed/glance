import type { CSSProperties } from "react";

const heights = [
  26, 40, 32, 28, 20, 26, 42, 28, 17, 25, 14, 20, 33, 22, 16, 14, 14, 20,
  36, 42, 32, 19, 31, 48, 68, 60, 48, 40, 50, 72, 100, 80, 94, 84, 70, 40,
  48, 44, 36, 68, 48, 58,
];

export function Frost({ flipped = false }: { flipped?: boolean }) {
  return (
    <div
      className={flipped ? "glance-frost glance-frost-flipped" : "glance-frost"}
      aria-hidden="true"
    >
      <div className="glance-frost-field">
        {heights.map((height, index) => (
          <span
            key={index}
            style={
              {
                "--strip-height": `${height}%`,
                "--strip-index": index,
              } as CSSProperties
            }
          />
        ))}
      </div>
    </div>
  );
}
