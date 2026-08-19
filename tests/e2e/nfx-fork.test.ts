import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

describe("n-fx fork integration", () => {
  test("CLIProxyAPI migration validates credentials and preserves the fx source", async () => {
    const requests: Array<{ path: string; authorization: string | null }> = [];
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch(request) {
        const url = new URL(request.url);
        requests.push({
          path: `${url.pathname}${url.search}`,
          authorization: request.headers.get("authorization"),
        });
        return Response.json({ data: [] });
      },
    });
    const root = mkdtempSync(join(tmpdir(), "nfx-cliproxyapi-migration-"));
    try {
      const home = join(root, "home");
      const fxDir = join(home, ".fx");
      mkdirSync(fxDir, { recursive: true, mode: 0o700 });
      chmodSync(fxDir, 0o700);
      const legacyPath = join(fxDir, "cliproxyapi.json");
      const legacyBytes = `${JSON.stringify({
        baseUrl: `http://127.0.0.1:${server.port}`,
        apiKey: "migration-secret",
      })}\n`;
      writeFileSync(legacyPath, legacyBytes, { mode: 0o600 });
      chmodSync(legacyPath, 0o600);

      const result = await runFx(
        ["login", "cliproxyapi", "--migrate-from-fx"],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            CLIPROXYAPI_API_KEY: undefined,
            CLIPROXYAPI_BASE_URL: undefined,
          },
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr).toBe("");
      expect(result.stdout).toContain("Validating CLIProxyAPI connection");
      expect(result.stdout).toContain("Saved CLIProxyAPI settings to ~/.nfx");
      expect(requests).toEqual([{
        path: "/v1/models?client_version=nfx",
        authorization: "Bearer migration-secret",
      }]);

      const nfxDir = join(home, ".nfx");
      const saved = JSON.parse(
        readFileSync(join(nfxDir, "cliproxyapi.json"), "utf8"),
      );
      expect(saved).toEqual({
        baseUrl: `http://127.0.0.1:${server.port}`,
        apiKey: "migration-secret",
      });
      expect(JSON.parse(readFileSync(join(nfxDir, "settings.json"), "utf8")))
        .toMatchObject({ provider: "cliproxyapi" });
      expect(statSync(nfxDir).mode & 0o777).toBe(0o700);
      expect(statSync(join(nfxDir, "cliproxyapi.json")).mode & 0o777).toBe(0o600);
      expect(statSync(join(nfxDir, "settings.json")).mode & 0o777).toBe(0o600);
      expect(readFileSync(legacyPath, "utf8")).toBe(legacyBytes);
    } finally {
      server.stop(true);
      rmSync(root, { recursive: true, force: true });
    }
  });
});
