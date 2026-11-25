import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  feedbackReducer,
  INITIAL_FEEDBACK_STATE,
} from "@/lib/feedback-state";
import { resolveSiteUrl } from "@/lib/site-url";

describe("Important #1: resolveSiteUrl metadataBase", () => {
  test("prefers NEXT_PUBLIC_SITE_URL, then VERCEL_PROJECT_PRODUCTION_URL, then VERCEL_URL, else localhost", () => {
    expect(
      resolveSiteUrl({
        NEXT_PUBLIC_SITE_URL: "https://glance.example.com",
        VERCEL_PROJECT_PRODUCTION_URL: "glance.vercel.app",
        VERCEL_URL: "glance-git-main.vercel.app",
      }),
    ).toBe("https://glance.example.com");

    expect(
      resolveSiteUrl({
        VERCEL_PROJECT_PRODUCTION_URL: "glance.vercel.app",
        VERCEL_URL: "glance-git-main.vercel.app",
      }),
    ).toBe("https://glance.vercel.app");

    expect(
      resolveSiteUrl({
        VERCEL_URL: "glance-preview.vercel.app",
      }),
    ).toBe("https://glance-preview.vercel.app");

    const fallback = resolveSiteUrl({});
    expect(fallback).toBe("http://localhost:3000");
    expect(fallback).not.toContain("github.com");
  });
});

describe("Important #2: App Lock curtain layout avoids chrome overlap and 375px clipping", () => {
  test("curtain uses inset: 0 inside a dedicated windowContent area with >= 220px mobile height", () => {
    const css = readFileSync(
      join(import.meta.dir, "../src/components/features-section.module.css"),
      "utf8",
    );
    expect(css).not.toContain("inset: 34px 0 0 0");
    expect(css).toContain(".windowContent");
    expect(css).toMatch(/\.curtain\s*\{[^}]*inset:\s*0;/s);
    const mobileBlock = css.slice(css.indexOf("@media (max-width: 700px)"));
    expect(mobileBlock).toMatch(/\.windowContent\s*\{[^}]*min-height:\s*22[0-9]px/s);
  });
});

describe("Important #3: feedbackReducer clears stale issueHref on edit and never fakes popup failure on copy", () => {
  test("copy does not set popup-fallback issueHref, and edit clears status, copied, and issueHref", () => {
    const afterOpen = feedbackReducer(INITIAL_FEEDBACK_STATE, {
      type: "opened",
      issueUrl: "https://github.com/pearleseed/glance/issues/new?title=A",
      status: "Opened a pre-filled issue on GitHub.",
    });
    expect(afterOpen.issueHref).toBe(
      "https://github.com/pearleseed/glance/issues/new?title=A",
    );

    const afterEdit = feedbackReducer(afterOpen, { type: "edited" });
    expect(afterEdit.issueHref).toBeNull();
    expect(afterEdit.status).toBe("");
    expect(afterEdit.copied).toBe(false);

    const afterCopy = feedbackReducer(afterEdit, {
      type: "copied",
      status: "Formatted Markdown copied to your clipboard.",
    });
    expect(afterCopy.copied).toBe(true);
    expect(afterCopy.issueHref).toBeNull();
  });
});
