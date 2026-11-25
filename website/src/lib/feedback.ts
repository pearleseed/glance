import { GLANCE_REPO } from "@/lib/glance-data";

export const FEEDBACK_TYPES = ["Bug", "Feature", "Question", "Other"] as const;
export type FeedbackType = (typeof FEEDBACK_TYPES)[number];

export interface FeedbackInput {
  type: FeedbackType;
  environment?: string;
  title: string;
  description: string;
}

export interface FeedbackPayload {
  issueUrl: string;
  markdown: string;
  truncatedForUrl: boolean;
}

const LABEL_MAP: Partial<Record<FeedbackType, string>> = {
  Bug: "bug",
  Feature: "enhancement",
  Question: "question",
};

const MAX_ISSUE_URL_LENGTH = 6000;
const TRUNCATION_NOTE =
  "\n\n---\n*(Description truncated for URL length — click Copy Markdown on the feedback form to paste the full report.)*";

function buildIssueUrl(
  issueTitle: string,
  body: string,
  label: string | undefined,
): string {
  const params = new URLSearchParams();
  params.set("title", issueTitle);
  params.set("body", body);
  if (label) {
    params.set("labels", label);
  }
  return `${GLANCE_REPO.issuesUrl}?${params.toString()}`;
}

export function buildFeedbackPayload(input: FeedbackInput): FeedbackPayload {
  const cleanTitle = input.title.trim();
  const cleanEnvironment = input.environment?.trim() ?? "";
  const cleanDescription = input.description.trim();
  const issueTitle = `[${input.type}] ${cleanTitle}`;
  const label = LABEL_MAP[input.type];

  const headerLines = [`**Type:** ${input.type}`];
  if (cleanEnvironment) {
    headerLines.push(`**Environment:** ${cleanEnvironment}`);
  }
  const fullBody = `${headerLines.join("\n")}\n\n${cleanDescription}`;
  const markdown = `# ${issueTitle}\n\n${fullBody}`;

  const fullUrl = buildIssueUrl(issueTitle, fullBody, label);
  if (fullUrl.length <= MAX_ISSUE_URL_LENGTH) {
    return {
      issueUrl: fullUrl,
      markdown,
      truncatedForUrl: false,
    };
  }

  let low = 0;
  let high = cleanDescription.length;
  let bestUrl = buildIssueUrl(
    issueTitle,
    `${headerLines.join("\n")}\n\n${TRUNCATION_NOTE}`,
    label,
  );

  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    const candidateBody = `${headerLines.join("\n")}\n\n${cleanDescription.slice(0, mid)}…${TRUNCATION_NOTE}`;
    const candidateUrl = buildIssueUrl(issueTitle, candidateBody, label);
    if (candidateUrl.length <= MAX_ISSUE_URL_LENGTH) {
      bestUrl = candidateUrl;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }

  return {
    issueUrl: bestUrl,
    markdown,
    truncatedForUrl: true,
  };
}
