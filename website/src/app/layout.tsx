import type { Metadata } from "next";
import { Frost } from "@/components/frost";
import { SiteNav } from "@/components/site-nav";
import { resolveSiteUrl } from "@/lib/site-url";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL(resolveSiteUrl(process.env)),
  title: {
    default: "Glance — Face Unlock, App Lock & Face-for-sudo for Mac",
    template: "%s — Glance",
  },
  description:
    "Face unlock, per-window App Lock, and 1-click Face-for-sudo for macOS 14 Sonoma+. Runs 100% on-device with ArcFace w600k_r50 on Apple Silicon and Intel.",
  icons: {
    icon: "/icon.png",
    apple: "/apple-icon.png",
  },
  openGraph: {
    title: "Glance — Face Unlock, App Lock & Face-for-sudo for Mac",
    description:
      "Unlock your Mac with a glance, lock individual apps behind face verification, and authenticate sudo in Terminal — 100% on-device.",
    type: "website",
    siteName: "Glance",
    images: [{ url: "/media/hero/launch-poster.jpg", width: 1280, height: 720 }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Glance — Face Unlock, App Lock & Face-for-sudo for Mac",
    description:
      "On-device Face Unlock, App Lock, and 1-click Face-for-sudo for macOS 14+.",
    images: ["/media/hero/launch-poster.jpg"],
  },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <SiteNav />
        {children}
        <footer className="glance-footer">
          <Frost flipped />
        </footer>
      </body>
    </html>
  );
}
