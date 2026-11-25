export interface FeedbackFormState {
  status: string;
  issueHref: string | null;
  copied: boolean;
}

export type FeedbackFormAction =
  | { type: "edited" }
  | { type: "error"; status: string }
  | { type: "opened"; issueUrl: string; status: string }
  | { type: "copied"; status: string }
  | { type: "copy-reset" };

export const INITIAL_FEEDBACK_STATE: FeedbackFormState = {
  status: "",
  issueHref: null,
  copied: false,
};

export function feedbackReducer(
  state: FeedbackFormState,
  action: FeedbackFormAction,
): FeedbackFormState {
  switch (action.type) {
    case "edited":
      return INITIAL_FEEDBACK_STATE;
    case "error":
      return { status: action.status, issueHref: null, copied: false };
    case "opened":
      return { status: action.status, issueHref: action.issueUrl, copied: false };
    case "copied":
      return { status: action.status, issueHref: null, copied: true };
    case "copy-reset":
      return { ...state, copied: false };
  }
}
