import { describe, expect, test } from "bun:test";
import { resolveArchDownload } from "@/lib/download-model";
import { FALLBACK_RELEASE } from "@/lib/glance-data";
import {
  formatCompactCount,
  formatMegabytes,
  getGlanceReleaseData,
  parseGitHubReleaseData,
} from "@/lib/github";

describe("formatCompactCount", () => {
  test("formats small numbers verbatim and compact thousands cleanly", () => {
    expect(formatCompactCount(0)).toBe("0");
    expect(formatCompactCount(42)).toBe("42");
    expect(formatCompactCount(999)).toBe("999");
    expect(formatCompactCount(1000)).toBe("1k");
    expect(formatCompactCount(1250)).toBe("1.3k");
    expect(formatCompactCount(2000)).toBe("2k");
    expect(formatCompactCount(122400)).toBe("122k");
  });
});

describe("formatMegabytes", () => {
  test("formats byte sizes into MB and returns empty string for non-positive values", () => {
    expect(formatMegabytes(44305881)).toBe("42.3 MB");
    expect(formatMegabytes(0)).toBe("");
    expect(formatMegabytes(-10)).toBe("");
  });
});

describe("parseGitHubReleaseData", () => {
  test("ignores draft releases, selects latest stable assets, and sums .dmg downloads", () => {
    const repoPayload = { stargazers_count: 1450 };
    const releasesPayload = [
      {
        tag_name: "v2.2.0-draft",
        draft: true,
        prerelease: false,
        html_url: "https://github.com/pearleseed/glance/releases/tag/v2.2.0-draft",
        published_at: "2026-11-25T00:00:00Z",
        assets: [
          {
            name: "Glance-2.2.0-arm64.dmg",
            browser_download_url: "https://example.com/draft-arm64.dmg",
            size: 50000000,
            download_count: 999,
          },
        ],
      },
      {
        tag_name: "v2.1.4",
        draft: false,
        prerelease: false,
        html_url: "https://github.com/pearleseed/glance/releases/tag/v2.1.4",
        published_at: "2026-11-24T15:00:00Z",
        assets: [
          {
            name: "Glance-2.1.4-arm64.dmg",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.4/Glance-2.1.4-arm64.dmg",
            size: 44100000,
            download_count: 320,
          },
          {
            name: "Glance-2.1.4-x86_64.dmg",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.4/Glance-2.1.4-x86_64.dmg",
            size: 44200000,
            download_count: 80,
          },
          {
            name: "SHA256SUMS.txt",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.4/SHA256SUMS.txt",
            size: 180,
            download_count: 50,
          },
        ],
      },
      {
        tag_name: "v2.1.3",
        draft: false,
        prerelease: false,
        html_url: "https://github.com/pearleseed/glance/releases/tag/v2.1.3",
        published_at: "2026-11-24T13:30:00Z",
        assets: [
          {
            name: "Glance-2.1.3-arm64.dmg",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.3/Glance-2.1.3-arm64.dmg",
            size: 44305881,
            download_count: 100,
          },
          {
            name: "appcast.xml",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.3/appcast.xml",
            size: 2205,
            download_count: 500,
          },
        ],
      },
    ];

    const data = parseGitHubReleaseData(repoPayload, releasesPayload);
    expect(data.source).toBe("github");
    expect(data.version).toBe("v2.1.4");
    expect(data.stars).toBe(1450);
    expect(data.downloads).toBe(500);
    expect(data.arm64?.name).toBe("Glance-2.1.4-arm64.dmg");
    expect(data.x86_64?.name).toBe("Glance-2.1.4-x86_64.dmg");
    expect(data.checksumsUrl).toContain("v2.1.4/SHA256SUMS.txt");
  });

  test("does not mix fallback assets or checksums from another version when x86_64 and checksums are absent", () => {
    const releasesPayload = [
      {
        tag_name: "v2.1.5",
        draft: false,
        prerelease: false,
        html_url: "https://github.com/pearleseed/glance/releases/tag/v2.1.5",
        published_at: "2026-11-25T10:00:00Z",
        assets: [
          {
            name: "Glance-2.1.5-arm64.dmg",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.5/Glance-2.1.5-arm64.dmg",
            size: 44000000,
            download_count: 10,
          },
        ],
      },
    ];

    const data = parseGitHubReleaseData({ stargazers_count: 0 }, releasesPayload);
    expect(data.version).toBe("v2.1.5");
    expect(data.arm64?.name).toBe("Glance-2.1.5-arm64.dmg");
    expect(data.x86_64).toBeNull();
    expect(data.checksumsUrl).toBeNull();
    expect(data.releaseUrl).toBe("https://github.com/pearleseed/glance/releases/tag/v2.1.5");
  });

  test("keeps checksums and available architecture bound to the same release when arm64 is absent", () => {
    const releasesPayload = [
      {
        tag_name: "v2.1.5",
        draft: false,
        prerelease: false,
        html_url: "https://github.com/pearleseed/glance/releases/tag/v2.1.5",
        published_at: "2026-11-25T10:00:00Z",
        assets: [
          {
            name: "Glance-2.1.5-x86_64.dmg",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.5/Glance-2.1.5-x86_64.dmg",
            size: 44200000,
            download_count: 5,
          },
          {
            name: "SHA256SUMS.txt",
            browser_download_url: "https://github.com/pearleseed/glance/releases/download/v2.1.5/SHA256SUMS.txt",
            size: 180,
            download_count: 3,
          },
        ],
      },
    ];

    const data = parseGitHubReleaseData({ stargazers_count: 0 }, releasesPayload);
    expect(data.arm64).toBeNull();
    expect(data.x86_64?.url).toContain("v2.1.5");
    expect(data.checksumsUrl).toContain("v2.1.5/SHA256SUMS.txt");
  });

  test("uses complete pinned fallback only when release metadata is unavailable", () => {
    const data = parseGitHubReleaseData(null, []);
    expect(data).toEqual(FALLBACK_RELEASE);
    expect(data.version).toBe("v2.1.4");
    expect(data.arm64?.url).toContain("/v2.1.4/Glance-2.1.4-arm64.dmg");
    expect(data.x86_64?.url).toContain("/v2.1.4/Glance-2.1.4-x86_64.dmg");
    expect(data.checksumsUrl).toContain("/v2.1.4/SHA256SUMS.txt");
  });
});

describe("resolveArchDownload", () => {
  test("links missing architecture to the current release page with an availability label", () => {
    const release = {
      version: "v2.1.5",
      releaseUrl: "https://github.com/pearleseed/glance/releases/tag/v2.1.5",
    };

    const missing = resolveArchDownload(null, release);
    expect(missing.href).toBe(release.releaseUrl);
    expect(missing.isDirectDownload).toBe(false);
    expect(missing.badgeText).toBe("Not in release");
    expect(missing.sheetLabel("Intel")).toContain("View release assets");

    const asset = {
      name: "Glance-2.1.5-arm64.dmg",
      url: "https://github.com/pearleseed/glance/releases/download/v2.1.5/Glance-2.1.5-arm64.dmg",
      sizeBytes: 44000000,
    };
    const present = resolveArchDownload(asset, release);
    expect(present.href).toBe(asset.url);
    expect(present.isDirectDownload).toBe(true);
    expect(present.badgeText).toBe(formatMegabytes(asset.sizeBytes) || null);
    expect(present.sheetLabel("Apple Silicon")).toBe("Apple Silicon (Glance-2.1.5-arm64.dmg)");

    const zeroSized = resolveArchDownload({ ...asset, sizeBytes: 0 }, release);
    expect(zeroSized.isDirectDownload).toBe(true);
    expect(zeroSized.badgeText).toBeNull();
  });
});

describe("getGlanceReleaseData", () => {
  test("returns deterministic fallback when GitHub returns 403 or network error", async () => {
    const rateLimitedFetch = (async () =>
      new Response("rate limited", { status: 403 })) as unknown as typeof fetch;

    const rateLimited = await getGlanceReleaseData(rateLimitedFetch);
    expect(rateLimited).toEqual(FALLBACK_RELEASE);

    const failingFetch = (async () => {
      throw new Error("network down");
    }) as unknown as typeof fetch;

    const networkFailed = await getGlanceReleaseData(failingFetch);
    expect(networkFailed).toEqual(FALLBACK_RELEASE);
  });
});
