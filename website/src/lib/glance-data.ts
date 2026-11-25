export const GLANCE_REPO = {
  owner: "pearleseed",
  name: "glance",
  url: "https://github.com/pearleseed/glance",
  releasesUrl: "https://github.com/pearleseed/glance/releases/latest",
  issuesUrl: "https://github.com/pearleseed/glance/issues/new",
} as const;

export const XATTR_COMMAND = "xattr -cr /Applications/Glance.app";

export interface ReleaseAsset {
  name: string;
  url: string;
  sizeBytes: number;
}

export interface GlanceReleaseData {
  version: string;
  releaseUrl: string;
  publishedAt: string | null;
  arm64: ReleaseAsset | null;
  x86_64: ReleaseAsset | null;
  checksumsUrl: string | null;
  stars: number;
  downloads: number;
  source: "github" | "fallback";
}

export const FALLBACK_RELEASE: GlanceReleaseData = {
  version: "v2.1.3",
  releaseUrl: `${GLANCE_REPO.url}/releases/tag/v2.1.3`,
  publishedAt: "2026-11-24T13:33:56Z",
  arm64: {
    name: "Glance-2.1.3-arm64.dmg",
    url: `${GLANCE_REPO.url}/releases/download/v2.1.3/Glance-2.1.3-arm64.dmg`,
    sizeBytes: 44305881,
  },
  x86_64: {
    name: "Glance-2.1.3-x86_64.dmg",
    url: `${GLANCE_REPO.url}/releases/download/v2.1.3/Glance-2.1.3-x86_64.dmg`,
    sizeBytes: 44483803,
  },
  checksumsUrl: `${GLANCE_REPO.url}/releases/download/v2.1.3/SHA256SUMS.txt`,
  stars: 0,
  downloads: 0,
  source: "fallback",
};

export interface SecurityFeature {
  title: string;
  subtitle: string;
  icon: string;
  iconSize: readonly [number, number];
  details: string;
  applePrefix?: boolean;
}

export const SECURITY_FEATURES: readonly SecurityFeature[] = [
  {
    title: "Completely Offline.",
    subtitle: "Nothing leaves your Mac.",
    icon: "globeicon",
    iconSize: [111, 110],
    details:
      "Core ML (ArcFace w600k_r50 W8A16) and Apple Vision run face recognition strictly on-device. No accounts, no cloud servers, and zero telemetry.",
  },
  {
    title: "512-d Face Embeddings.",
    subtitle: "Your face is never stored.",
    icon: "faceidicon",
    iconSize: [101, 101],
    details:
      "Camera frames are discarded immediately after conversion into AES-GCM encrypted 512-dimensional embeddings. Weak fallback models are strictly refused for unlock.",
  },
  {
    title: "Encrypted in Apple Keychain.",
    subtitle: "Native, safe, and secure.",
    icon: "keychainicon",
    iconSize: [83, 113],
    applePrefix: true,
    details:
      "Your 256-bit AES-GCM session key is gated by Touch ID or Mac password in Data Protection Keychain, with seamless LAContext and Login Keychain support for ad-hoc community builds.",
  },
  {
    title: "5-Cue Liveness Checks.",
    subtitle: "Identity-bound anti-spoofing.",
    icon: "sunicon",
    iconSize: [107, 107],
    details:
      "Combines face-contour-masked screen glare and multi-candidate bezel detection with 3D landmark geometry, roll-invariant blinks, and nose parallax. Light or Heavy mode.",
  },
  {
    title: "Hardened sudo PAM.",
    subtitle: "Zero password injection.",
    icon: "sudoicon",
    iconSize: [106, 106],
    details:
      "The universal OpenPAM module rejects remote SSH sessions, verifies the root-owned Glance binary and 0700 socket, checks a fresh 256-bit nonce, and always enforces Heavy Liveness.",
  },
  {
    title: "Zeroized Keystrokes.",
    subtitle: "Wiped from memory immediately.",
    icon: "keystrokeicon",
    iconSize: [106, 106],
    details:
      "Credentials decode into a mutable UTF-16 buffer wiped via memset_s, inject through isolated privateState events immune to Caps Lock, and re-verify lock state before every step.",
  },
  {
    title: "Auto-Lock Sessions.",
    subtitle: "Keeping your data private.",
    icon: "lockicon",
    iconSize: [86, 107],
    details:
      "Set an idle session timeout (default 30 days or Never), optionally enable Unlock session at login on Touch ID-free Macs, and revoke every App Lock session automatically on sleep or lock.",
  },
  {
    title: "Full Control of Your Data.",
    subtitle: "Edit or delete at any time.",
    icon: "dataicon",
    iconSize: [106, 106],
    details:
      "Pause or remove any identity, reset stored data even while locked, or uninstall sudo PAM in one click. App Lock shields critical recovery apps from accidental lockouts.",
  },
];

export interface EngineMetric {
  value: string;
  label: string;
  detail: string;
}

export const ENGINE_METRICS: readonly EngineMetric[] = [
  {
    value: "2.1 ms",
    label: "Apple Silicon ANE median",
    detail: "w600k_r50 W8A16 on M3 · 9.4 ms Intel BNNS",
  },
  {
    value: "42 MB",
    label: "Half the FP16 footprint",
    detail: "0.9991 ONNX parity · Float16 fast-path",
  },
  {
    value: "0 Hz",
    label: "Background polling",
    detail: "Event-driven frames & deadline timers",
  },
  {
    value: "1 Pipeline",
    label: "Shared app-wide",
    detail: "Lock Screen, App Lock & sudo reuse one model",
  },
];
