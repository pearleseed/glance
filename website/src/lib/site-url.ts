export interface SiteUrlEnv {
  NEXT_PUBLIC_SITE_URL?: string;
  VERCEL_PROJECT_PRODUCTION_URL?: string;
  VERCEL_URL?: string;
  [key: string]: string | undefined;
}

export function resolveSiteUrl(env: SiteUrlEnv): string {
  const explicit = env.NEXT_PUBLIC_SITE_URL?.trim();
  if (explicit) return explicit;

  const prodHost = env.VERCEL_PROJECT_PRODUCTION_URL?.trim();
  if (prodHost) return `https://${prodHost}`;

  const deployHost = env.VERCEL_URL?.trim();
  if (deployHost) return `https://${deployHost}`;

  return "http://localhost:3000";
}
