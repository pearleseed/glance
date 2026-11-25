import { formatMegabytes } from "@/lib/github";
import type { GlanceReleaseData, ReleaseAsset } from "@/lib/glance-data";

export interface ArchDownloadAction {
  href: string;
  isDirectDownload: boolean;
  badgeText: string | null;
  sheetLabel: (archName: string) => string;
}

/** Resolves link target, badge text, and mobile sheet label for a release architecture asset. */
export function resolveArchDownload(
  asset: ReleaseAsset | null,
  release: Pick<GlanceReleaseData, "version" | "releaseUrl">,
): ArchDownloadAction {
  if (!asset) {
    return {
      href: release.releaseUrl,
      isDirectDownload: false,
      badgeText: "Not in release",
      sheetLabel: (archName: string) => `${archName} (View release assets)`,
    };
  }

  return {
    href: asset.url,
    isDirectDownload: true,
    badgeText: formatMegabytes(asset.sizeBytes) || null,
    sheetLabel: (archName: string) => `${archName} (${asset.name})`,
  };
}
