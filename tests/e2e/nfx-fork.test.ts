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
import { spawn as nodeSpawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";

const TIMEOUT = 20_000;

function isolatedCliproxyEnv(
  home: string,
  baseUrl: string,
): Record<string, string | undefined> {
  return {
    ...process.env,
    HOME: home,
    PATH: process.env.PATH ?? "",
    NO_COLOR: "1",
    FX_AUTO_UPGRADE: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_MODEL: "gpt-5.6-sol",
    FX_PROVIDER: "cliproxyapi",
    FX_SKIP_ONBOARDING: "1",
    CLIPROXYAPI_BASE_URL: baseUrl,
    CLIPROXYAPI_API_KEY: "cliproxy-secret",
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
  };
}

function responsesSse(text: string): string {
  return [
    'data: {"type":"response.created","response":{"id":"resp_nfx"}}\n\n',
    'data: {"type":"response.reasoning_summary_text.delta","delta":"brief thought"}\n\n',
    `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n`,
    'data: {"type":"response.completed","response":{"id":"resp_nfx","status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
  ].join("");
}

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
  }, TIMEOUT);

  test("built nfx uses the documented Responses route, images, and isolated bearer credential", async () => {
    const requests: Array<{
      method: string;
      path: string;
      authorization: string | null;
      accept: string | null;
      beta: string | null;
      originator: string | null;
      userAgent: string | null;
      body: unknown;
    }> = [];
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/v1/models") {
          return Response.json({
            models: [{
              slug: "gpt-5.6-sol",
              input_modalities: ["text", "image"],
              supported_reasoning_levels: [{ effort: "high" }],
            }],
          });
        }
        const body = await request.json();
        requests.push({
          method: request.method,
          path: `${url.pathname}${url.search}`,
          authorization: request.headers.get("authorization"),
          accept: request.headers.get("accept"),
          beta: request.headers.get("openai-beta"),
          originator: request.headers.get("originator"),
          userAgent: request.headers.get("user-agent"),
          body,
        });
        return new Response(responsesSse("CLIProxy response\n"), {
          headers: { "content-type": "text/event-stream" },
        });
      },
    });
    const root = mkdtempSync(join(tmpdir(), "nfx-cliproxyapi-ask-"));
    try {
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home);
      mkdirSync(workspace);
      const result = await runFx(
        [
          "ask",
          "--stream-json",
          "--no-save",
          "--image",
          join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"),
          "Use CLIProxyAPI to describe the image.",
        ],
        {
          cwd: workspace,
          env: isolatedCliproxyEnv(
            home,
            `http://127.0.0.1:${server.port}`,
          ),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr).toBe("");
      const events = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
      expect(events.some((event) =>
        event.t === "text" && event.delta === "CLIProxy response\n"
      )).toBe(true);
      expect(events.at(-1)).toMatchObject({
        t: "run_end",
        exit_code: 0,
        output: "CLIProxy response\n",
      });
      expect(requests).toHaveLength(1);
      expect(requests[0]).toMatchObject({
        method: "POST",
        path: "/v1/responses",
        authorization: "Bearer cliproxy-secret",
        accept: "text/event-stream",
        beta: "responses=experimental",
        originator: "nfx",
      });
      expect(requests[0]!.userAgent).toStartWith("nfx-cliproxyapi/");
      expect(requests[0]!.body).toMatchObject({
        model: "gpt-5.6-sol",
        stream: true,
      });
      const requestBody = JSON.stringify(requests[0]!.body);
      expect(requestBody).toContain('"type":"input_image"');
      expect(requestBody).toContain("data:image/png;base64,");
      expect(requestBody).not.toContain("fixtures/favicon.png");
    } finally {
      server.stop(true);
      rmSync(root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test("stream-json publishes a CLIProxy delta before the response closes", async () => {
    let releaseResponse = () => {};
    const responseGate = new Promise<void>((resolve) => {
      releaseResponse = resolve;
    });
    let responseReleased = false;
    const encoder = new TextEncoder();
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch(request) {
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/v1/models") {
          return Response.json({ data: [{ id: "gpt-5.6-sol" }] });
        }
        if (request.method !== "POST" || url.pathname !== "/v1/responses") {
          return new Response("unexpected route", { status: 404 });
        }
        return new Response(
          new ReadableStream<Uint8Array>({
            async start(controller) {
              controller.enqueue(encoder.encode(
                'data: {"type":"response.output_text.delta","delta":"EARLY_CLIPROXY_DELTA"}\n\n',
              ));
              await responseGate;
              responseReleased = true;
              controller.enqueue(encoder.encode(
                'data: {"type":"response.completed","response":{"id":"resp_early","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}\n\n',
              ));
              controller.close();
            },
          }),
          { headers: { "content-type": "text/event-stream" } },
        );
      },
    });
    const root = mkdtempSync(join(tmpdir(), "nfx-cliproxyapi-stream-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home);
    mkdirSync(workspace);
    const env = isolatedCliproxyEnv(home, `http://127.0.0.1:${server.port}`);
    for (const [key, value] of Object.entries(env)) {
      if (value === undefined) delete env[key];
    }
    const child = nodeSpawn(
      FX_BIN,
      ["ask", "--stream-json", "--no-save", "Stream immediately."],
      { cwd: workspace, env: env as NodeJS.ProcessEnv, stdio: ["ignore", "pipe", "pipe"] },
    );
    let stdout = "";
    let stderr = "";
    let sawEarlyDelta = false;
    let resolveEarly: (value: boolean) => void = () => {};
    const early = new Promise<boolean>((resolve) => {
      resolveEarly = resolve;
    });
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      if (!sawEarlyDelta && stdout.includes("EARLY_CLIPROXY_DELTA")) {
        sawEarlyDelta = true;
        resolveEarly(true);
      }
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    const closed = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
      child.on("close", (code, signal) => resolve({ code, signal }));
    });

    try {
      const observedBeforeClose = await Promise.race([
        early,
        Bun.sleep(5_000).then(() => false),
      ]);
      expect(observedBeforeClose).toBe(true);
      expect(responseReleased).toBe(false);
      expect(child.exitCode).toBe(null);
      releaseResponse();
      const exit = await closed;
      expect(exit).toEqual({ code: 0, signal: null });
      expect(stderr).toBe("");
      const events = stdout.trim().split("\n").map((line) => JSON.parse(line));
      expect(events.at(-1)).toMatchObject({
        t: "run_end",
        exit_code: 0,
        output: "EARLY_CLIPROXY_DELTA",
      });
    } finally {
      releaseResponse();
      if (child.exitCode === null) child.kill("SIGKILL");
      await closed;
      server.stop(true);
      rmSync(root, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
