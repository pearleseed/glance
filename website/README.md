# Glance Website

Official Next.js marketing & download website for [Glance](https://github.com/pearleseed/glance) — Face Unlock, App Lock, and Face-for-`sudo` for macOS 14 Sonoma+.

## Local Development (Bun)

```bash
cd website
bun install
bun dev
```

Open [http://localhost:3000](http://localhost:3000).

## Verification

```bash
bun test       # Unit & hygiene tests
bun run check  # ESLint + TypeScript + Next.js production build
```

## Deploying to Vercel

1. Import `pearleseed/glance` in Vercel.
2. Set **Root Directory** to `website`.
3. Vercel automatically detects Next.js and Bun via `bun.lock`.
4. *(Optional)* Add a `GITHUB_TOKEN` environment variable to raise GitHub API rate limits for live release & star counts (the site caches responses via ISR for 1 hour and falls back cleanly to bundled `v2.1.3` release metadata).
