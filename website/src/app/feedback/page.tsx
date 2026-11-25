import type { Metadata } from "next";
import { FeedbackForm } from "@/app/feedback/feedback-form";
import styles from "@/app/feedback/feedback.module.css";

export const metadata: Metadata = {
  title: "Feedback",
  description:
    "Report a bug, request a feature, or ask a question directly on pearleseed/glance GitHub Issues.",
};

export default function FeedbackPage() {
  return (
    <main className={`glance-shell ${styles.page}`}>
      <section className={styles.content} aria-labelledby="feedback-title">
        <p className={styles.eyebrow}>GitHub Issues</p>
        <h1 className={styles.heading} id="feedback-title">
          Feedback
        </h1>
        <p className={styles.intro}>
          Fill out the details below to open a pre-filled issue on{" "}
          <strong>pearleseed/glance</strong>, or copy the formatted Markdown to
          share anywhere.
        </p>
        <FeedbackForm />
      </section>
    </main>
  );
}
