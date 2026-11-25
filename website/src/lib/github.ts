import {
  FALLBACK_RELEASE,
  GLANCE_REPO,
  type GlanceReleaseData,
  type ReleaseAsset,
} from "@/lib/glance-data";

interface GitHubRepoResponse {
  stargazers_count?: unknown;
}

interface GitHubAssetResponse {
  name?: unknown;
  browser_download_url?: unknown;
  size?: unknown;
  download_count?: unknown;
}

interface GitHubReleaseResponse {
  tag_name?: unknown;
  draft?: unknown;
  prerelease?: unknown;
  html_url?: unknown;
  published_at?: unknown;
  assets?: unknown;
}

export function formatCompactCount(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "0";
  if (value < 1000) return String(Math.round(value));
  if (value < 10000) {
    const formatted = (value / 1000).toFixed(1);
    return formatted.endsWith(".0") ? `${formatted.slice(0, -2)}k` : `${formatted}k`;
  }
  return `${Math.round(value / 1000)}k`;
}

export function formatMegabytes(sizeBytes: number): string {
  if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) return "";
  return `${(sizeBytes / (1024 * 1024)).toFixed(1)} MB`;
}

function asAsset(raw: GitHubAssetResponse | undefined): ReleaseAsset | null {
  if (
    !raw ||
    typeof raw.name !== "string" ||
    typeof raw.browser_download_url !== "string" ||
    !raw.browser_download_url.startsWith("https://")
  ) {
    return null;
  }

  return {
    name: raw.name,
    url: raw.browser_download_url,
    sizeBytes: typeof raw.size === "number" && Number.isFinite(raw.size) ? raw.size : 0,
  };
}

export function parseGitHubReleaseData(
  repoPayload: unknown,
  releasesPayload: unknown,
): GlanceReleaseData {
  const repo = (repoPayload && typeof repoPayload === "object"
    ? repoPayload
    : {}) as GitHubRepoResponse;

  const stars =
    typeof repo.stargazers_count === "number" && Number.isFinite(repo.stargazers_count)
      ? Math.max(0, Math.floor(repo.stargazers_count))
      : FALLBACK_RELEASE.stars;

  const releases = Array.isArray(releasesPayload)
    ? (releasesPayload as GitHubReleaseResponse[])
    : [];

  const stableReleases = releases.filter(
    (release) =>
      release &&
      typeof release === "object" &&
      release.draft !== true &&
      release.prerelease !== true &&
      typeof release.tag_name === "string" &&
      release.tag_name.length > 0,
  );

  const latest = stableReleases[0];
  if (!latest) {
    return {
      ...FALLBACK_RELEASE,
      stars,
      source: typeof repo.stargazers_count === "number" ? "github" : "fallback",
    };
  }

  let totalDownloads = 0;
  for (const release of stableReleases) {
    const assets = Array.isArray(release.assets)
      ? (release.assets as GitHubAssetResponse[])
      : [];
    for (const asset of assets) {
      if (
        typeof asset?.name === "string" &&
        asset.name.toLowerCase().endsWith(".dmg") &&
        typeof asset.download_count === "number" &&
        Number.isFinite(asset.download_count)
      ) {
        totalDownloads += Math.max(0, Math.floor(asset.download_count));
      }
    }
  }

  const latestAssets = Array.isArray(latest.assets)
    ? (latest.assets as GitHubAssetResponse[])
    : [];

  const arm64 =
    asAsset(latestAssets.find((asset) => typeof asset?.name === "string" && /arm64.*\.dmg$/i.test(asset.name))) ??
    FALLBACK_RELEASE.arm64;

  const x86_64 =
    asAsset(latestAssets.find((asset) => typeof asset?.name === "string" && /x86_64.*\.dmg$/i.test(asset.name))) ??
    FALLBACK_RELEASE.x86_64;

  const checksumsAsset = asAsset(
    latestAssets.find((asset) => typeof asset?.name === "string" && /SHA256SUMS/i.test(asset.name)),
  );

  const version = String(latest.tag_name);
  const releaseUrl =
    typeof latest.html_url === "string" && latest.html_url.startsWith("https://")
      ? latest.html_url
      : `${GLANCE_REPO.url}/releases/tag/${encodeURIComponent(version)}`;

  return {
    version,
    releaseUrl,
    publishedAt: typeof latest.published_at === "string" ? latest.published_at : null,
    arm64,
    x86_64,
    checksumsUrl: checksumsAsset?.url ?? FALLBACK_RELEASE.checksumsUrl,
    stars,
    downloads: totalDownloads,
    source: "github",
  };
}

export async function getGlanceReleaseData(
  fetchImpl: typeof fetch = fetch,
): Promise<GlanceReleaseData> {
  const headers: HeadersInit = {
    Accept: "application/vnd.github+json",
    "User-Agent": "glance-website",
  };

  if (process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }

  const requestInit: RequestInit & { next?: { revalidate: number } } = {
    headers,
    signal: AbortSignal.timeout(3500),
    next: { revalidate: 3600 },
  };

  const apiBase = `https://api.github.com/repos/${GLANCE_REPO.owner}/${GLANCE_REPO.name}`;

  const [repoResult, releasesResult] = await Promise.allSettled([
    fetchImpl(apiBase, requestInit),
    fetchImpl(`${apiBase}/releases?per_page=10`, requestInit),
  ]);

  let repoPayload: unknown = null;
  let releasesPayload: unknown = null;

  if (repoResult.status === "fulfilled" && repoResult.value.ok) {
    try {
      repoPayload = await repoResult.value.json();
    } catch {
      repoPayload = null;
    }
  }

  if (releasesResult.status === "fulfilled" && releasesResult.value.ok) {
    try {
      releasesPayload = await releasesResult.value.json();
    } catch {
      releasesPayload = null;
    }
  }

  if (!repoPayload && !releasesPayload) {
    return FALLBACK_RELEASE;
  }

  return parseGitHubReleaseData(repoPayload, releasesPayload);
}
