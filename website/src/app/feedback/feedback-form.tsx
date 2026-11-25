"use client";

import { Check, Copy, ExternalLink } from "lucide-react";
import { useEffect, useReducer, useRef, type FormEvent } from "react";
import styles from "@/app/feedback/feedback.module.css";
import {
  buildFeedbackPayload,
  FEEDBACK_TYPES,
  type FeedbackType,
} from "@/lib/feedback";
import {
  feedbackReducer,
  INITIAL_FEEDBACK_STATE,
} from "@/lib/feedback-state";

function isFeedbackType(value: string): value is FeedbackType {
  return (FEEDBACK_TYPES as readonly string[]).includes(value);
}

export function FeedbackForm() {
  const formRef = useRef<HTMLFormElement>(null);
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [state, dispatch] = useReducer(feedbackReducer, INITIAL_FEEDBACK_STATE);

  useEffect(() => {
    return () => {
      if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
    };
  }, []);

  function extractPayload() {
    const form = formRef.current;
    if (!form) return null;

    const fields = new FormData(form);
    const rawType = String(fields.get("type") ?? "");
    const type: FeedbackType = isFeedbackType(rawType) ? rawType : "Bug";
    const environment = String(fields.get("environment") ?? "").trim();
    const title = String(fields.get("title") ?? "").trim();
    const description = String(fields.get("description") ?? "").trim();

    if (!rawType) {
      dispatch({ type: "error", status: "Please choose a feedback type." });
      form.querySelector<HTMLElement>("[name=type]")?.focus();
      return null;
    }

    if (!title || !description) {
      dispatch({
        type: "error",
        status: "Please enter a title and a description.",
      });
      form
        .querySelector<HTMLElement>(title ? "textarea" : "[name=title]")
        ?.focus();
      return null;
    }

    return buildFeedbackPayload({ type, environment, title, description });
  }

  function openGitHubIssue(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const payload = extractPayload();
    if (!payload) return;

    window.open(payload.issueUrl, "_blank", "noopener,noreferrer");
    dispatch({
      type: "opened",
      issueUrl: payload.issueUrl,
      status: payload.truncatedForUrl
        ? "Opened GitHub with a shortened body — use Copy Markdown below for the full text."
        : "Opened a pre-filled issue on GitHub.",
    });
  }

  async function copyMarkdown() {
    const payload = extractPayload();
    if (!payload) return;

    try {
      await navigator.clipboard.writeText(payload.markdown);
      dispatch({
        type: "copied",
        status: "Formatted Markdown copied to your clipboard.",
      });
      if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
      copyTimerRef.current = setTimeout(
        () => dispatch({ type: "copy-reset" }),
        2000,
      );
    } catch {
      dispatch({
        type: "error",
        status: "Could not access clipboard. Use Open on GitHub instead.",
      });
    }
  }

  return (
    <form
      ref={formRef}
      method="get"
      onSubmit={openGitHubIssue}
      onChange={() => {
        if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
        dispatch({ type: "edited" });
      }}
    >
      <div className={styles.row}>
        <label className={styles.type}>
          <span className="sr-only">Type</span>
          <select
            className={`${styles.input} ${styles.select}`}
            name="type"
            defaultValue=""
            required
          >
            <option value="" disabled>
              Type...
            </option>
            {FEEDBACK_TYPES.map((type) => (
              <option key={type} value={type}>
                {type}
              </option>
            ))}
          </select>
        </label>
        <label className={styles.environment}>
          <span className="sr-only">Mac and macOS version (optional)</span>
          <input
            className={styles.input}
            maxLength={120}
            name="environment"
            placeholder="macOS & Mac chip (optional)"
            type="text"
          />
        </label>
      </div>

      <label className={styles.field}>
        <span className="sr-only">Title</span>
        <input
          className={styles.input}
          maxLength={200}
          name="title"
          placeholder="Title..."
          required
        />
      </label>

      <label className={styles.field}>
        <span className="sr-only">Description</span>
        <textarea
          className={styles.textarea}
          maxLength={8000}
          name="description"
          placeholder="Explain in as much detail as possible..."
          required
        />
      </label>

      <div className={styles.actions}>
        <button className={styles.send} type="submit">
          <ExternalLink size={16} aria-hidden="true" />
          Open on GitHub
        </button>
        <button
          className={styles.secondary}
          type="button"
          onClick={copyMarkdown}
        >
          {state.copied ? (
            <Check size={16} aria-hidden="true" />
          ) : (
            <Copy size={16} aria-hidden="true" />
          )}
          {state.copied ? "Copied Markdown" : "Copy Markdown"}
        </button>
      </div>

      <div className={styles.status} role="status" aria-live="polite">
        {state.status && <p>{state.status}</p>}
        {state.issueHref && (
          <a href={state.issueHref} target="_blank" rel="noopener noreferrer">
            Didn’t open automatically? Click here to open the GitHub issue.
          </a>
        )}
      </div>
    </form>
  );
}
