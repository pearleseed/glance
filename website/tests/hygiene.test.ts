import { describe, expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const websiteRoot = join(import.meta.dir, "..");

function collectFiles(dir: string): string[] {
  const results: string[] = [];
  for (const entry of readdirSync(dir)) {
    const fullPath = join(dir, entry);
    const stats = statSync(fullPath);
    if (stats.isDirectory()) {
      results.push(...collectFiles(fullPath));
    } else {
      results.push(fullPath);
    }
  }
  return results;
}

describe("website repository hygiene", () => {
  test("uses Bun lockfile with no npm package-lock.json", () => {
    expect(existsSync(join(websiteRoot, "bun.lock"))).toBe(true);
    expect(existsSync(join(websiteRoot, "package-lock.json"))).toBe(false);
  });

  test("contains zero stale upstream references or dead template dependencies", () => {
    const filesToCheck = [
      join(websiteRoot, "package.json"),
      ...collectFiles(join(websiteRoot, "src")),
    ];

    const forbiddenPatterns = [
      /jonnyoo\/glance/i,
      /macOS 15 Sequoia/i,
      /ai-website-clone-template/i,
      /\bshadcn\b/i,
      /@base-ui\b/i,
      /localStorage\.setItem/i,
    ];

    const violations: string[] = [];
    for (const filePath of filesToCheck) {
      const content = readFileSync(filePath, "utf8");
      for (const pattern of forbiddenPatterns) {
        if (pattern.test(content)) {
          violations.push(`${filePath}: matched ${pattern}`);
        }
      }
    }

    expect(violations).toEqual([]);
  });
});
