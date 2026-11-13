import { execFileSync } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "wxt";
import { DISPLAY_NAME, EXTENSION_PUBLIC_KEY, FILL_MATCHES, FIREFOX_EXTENSION_ID, STORE_TITLE } from "./src/config.ts";

// Give the Windows fork its own Chrome ID so it can be loaded beside the store build.
const windowsPairingFork = process.env.WXT_WINDOWS_PAIRING_FORK === "1";
const windowsPairingPublicKey =
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAo81NFjus8TfSZi9/HOk8StyA4+/Es7+yymeewkRjraO67Bc8oTZVwTsH4c8rnuT4/48yM70B0vkseHVXWuQnp0Xyi2JcZyR/Nao64ZFzyRKPCE7YiTUf+3I45c38AR2Zzea/cQ8359nLsHxwqGuA09c4Od+ixTkE12JggEDhSqGJrvQNNKA/dUMdo+tYf3nH15y5q7+voXgNLveYJ/i0hkee9DGT0YmYCdb2tHqHW9AuEUFxc/ytBiR3YMacXKRS54Le94W4TK2GZmQXU1LoGSEVW347iC8g4/5OIaQWgXMfaEqFoCZoc3gTAChko8KPi3OOad0yJqpo/3Bsu1j7awIDAQAB";

export default defineConfig({
  outDirTemplate: `{{browser}}-mv{{manifestVersion}}{{modeSuffix}}${windowsPairingFork ? "-windows-pairing" : ""}`,
  hooks: {
    // The GitHub ZIP keeps the identity field so unpacked installs get the store's ID, which
    // native messaging allows. Chrome rejects that field in store uploads, so the store gets a
    // copy without it in .output/store, outside the release's asset glob.
    "zip:extension:done": async (wxt, zipPath) => {
      if (wxt.config.browser !== "chrome") return;
      const path = join(wxt.config.outDir, "manifest.json");
      const manifest = JSON.parse(await readFile(path, "utf8"));
      const { key, ...storeManifest } = manifest;
      const storeZip = join(dirname(zipPath), "store", basename(zipPath));
      await mkdir(dirname(storeZip), { recursive: true });
      await rm(storeZip, { force: true });
      await writeFile(path, JSON.stringify(storeManifest));
      try {
        execFileSync("zip", ["-qrX", storeZip, "."], { cwd: wxt.config.outDir });
      } finally {
        await writeFile(path, JSON.stringify({ ...manifest, key }));
      }
    },
  },
  zip: {
    artifactTemplate: "better-passwords-{{packageVersion}}-{{browser}}.zip",
    sourcesTemplate: "better-passwords-{{packageVersion}}-sources.zip",
    // Reviewers need the workspace protocol package and root lockfile to reproduce the build.
    sourcesRoot: fileURLToPath(new URL("../../", import.meta.url)),
    includeSources: [
      "package.json",
      "bun.lock",
      "tsconfig.base.json",
      "README.md",
      "CONTRIBUTING.md",
      "LICENSE",
      "NOTICE",
      "PRIVACY.md",
      "SECURITY.md",
      "biome.json",
      "lefthook.yml",
      "commitlint.config.js",
      "vitest.config.ts",
      "apps/extension/**",
      "apps/companion-windows/**",
      "packages/**",
      "scripts/**",
      "docs/**",
    ],
    excludeSources: [
      "**/.output/**",
      "**/.wxt/**",
      "**/node_modules/**",
      "**/test-results/**",
      "**/playwright-report/**",
    ],
  },
  manifest: ({ browser }) => {
    const isWindowsPairingFork = windowsPairingFork && browser === "chrome";
    return {
      name: isWindowsPairingFork ? "Better Passwords - Windows pairing" : STORE_TITLE,
      short_name: DISPLAY_NAME,
      description: "Fill passwords from Apple Passwords, pairing far less often.",
      permissions: [
        "nativeMessaging",
        "storage",
        "alarms",
        "idle",
        "activeTab",
        "scripting",
        // while Hide My Email is on, sets icloud.com's Origin on our own requests to iCloud
        "declarativeNetRequestWithHostAccess",
      ],
      // the inline menu reads the page's URL and runs on login pages
      host_permissions: FILL_MATCHES,
      // Chromium: reachable only at a per-session URL, so pages can't load (or probe for) the menu
      web_accessible_resources: [
        {
          resources: ["menu.html"],
          matches: FILL_MATCHES,
          ...(browser === "firefox" ? {} : { use_dynamic_url: true }),
        },
      ],
      action: { default_title: DISPLAY_NAME },
      ...(browser === "firefox"
        ? {
            browser_specific_settings: {
              gecko: {
                id: FIREFOX_EXTENSION_ID,
                strict_min_version: "142.0",
                // Mozilla's transmission rules include the local native password helper.
                data_collection_permissions: {
                  required: ["authenticationInfo", "browsingActivity"],
                  optional: ["personallyIdentifyingInfo", "websiteContent"],
                },
              },
            },
          }
        : { key: isWindowsPairingFork ? windowsPairingPublicKey : EXTENSION_PUBLIC_KEY }),
    };
  },
});
