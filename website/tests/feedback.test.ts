import { describe, expect, test } from "bun:test";
import { buildFeedbackPayload } from "@/lib/feedback";
import { GLANCE_REPO } from "@/lib/glance-data";

describe("buildFeedbackPayload", () => {
  test("maps feedback types to labels and builds pearleseed/glance issue URLs", () => {
    const bug = buildFeedbackPayload({
      type: "Bug",
      environment: "macOS 15.1 · M3 Pro",
      title: "Notch clipped on Studio Display",
      description: "Repro steps here",
    });
    const bugUrl = new URL(bug.issueUrl);
    expect(bug.issueUrl.startsWith(`${GLANCE_REPO.issuesUrl}?`)).toBe(true);
    expect(bugUrl.searchParams.get("labels")).toBe("bug");
    expect(bugUrl.searchParams.get("title")).toBe(
      "[Bug] Notch clipped on Studio Display",
    );
    expect(bugUrl.searchParams.get("body")).toContain("macOS 15.1 · M3 Pro");
    expect(bug.truncatedForUrl).toBe(false);

    const feature = buildFeedbackPayload({
      type: "Feature",
      title: "Custom hotkey sound",
      description: "Let me pick a sound",
    });
    expect(new URL(feature.issueUrl).searchParams.get("labels")).toBe(
      "enhancement",
    );

    const question = buildFeedbackPayload({
      type: "Question",
      title: "Clamshell camera order",
      description: "Which camera is preferred?",
    });
    expect(new URL(question.issueUrl).searchParams.get("labels")).toBe(
      "question",
    );

    const other = buildFeedbackPayload({
      type: "Other",
      title: "Hello",
      description: "General note",
    });
    expect(new URL(other.issueUrl).searchParams.get("labels")).toBeNull();
  });

  test("preserves Unicode, emojis, newlines, and URL-reserved characters", () => {
    const description = "Tiếng Việt 🚀\nStep 1: check a=1&b=2#hash?query=true";
    const payload = buildFeedbackPayload({
      type: "Bug",
      title: "Special chars & # ? check",
      description,
    });

    const parsed = new URL(payload.issueUrl);
    expect(parsed.searchParams.get("title")).toBe(
      "[Bug] Special chars & # ? check",
    );
    expect(parsed.searchParams.get("body")).toContain(description);
    expect(payload.markdown).toContain(description);
  });

  test("truncates oversized 8000-char descriptions safely for URL while preserving full markdown", () => {
    const longDescription = "A".repeat(8000);
    const payload = buildFeedbackPayload({
      type: "Bug",
      environment: "macOS 14.7 · Intel",
      title: "Long diagnostic log",
      description: longDescription,
    });

    expect(payload.truncatedForUrl).toBe(true);
    expect(payload.issueUrl.length).toBeLessThanOrEqual(6000);
    expect(new URL(payload.issueUrl).searchParams.get("body")).toContain(
      "truncated",
    );
    expect(payload.markdown).toContain(longDescription);
  });
});
