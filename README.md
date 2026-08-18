# n-fx

An experimental fork of [fx](https://github.com/vercel-labs/fx) with native
CLIProxyAPI routing. The project remains command-compatible with fx: the
executable is still named `fx`, and configuration stays under `~/.fx`.

```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             n-fx · native CLIProxyAPI routing
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

n-fx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Install n-fx

```bash
curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh | bash
```

The installer detects Linux or macOS on x86_64 or ARM64, downloads the latest
GitHub Release, verifies its SHA-256 checksum, and installs the command as
`~/.local/bin/fx`. Install a specific release or choose another directory with:

```bash
curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh | bash -s -- v0.0.4
N_FX_INSTALL_DIR="$HOME/bin" \
  bash <(curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh)
```

## Run fx

To get started, sign in with Vercel:

```bash
fx login
```

Or add an AI Gateway API key:

```bash
fx setup
```

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

## CLIProxyAPI provider

This fork adds a native CLIProxyAPI provider based on the connection, model
catalog, Responses API, reasoning, and Fast-mode behavior from
[`pi-cliproxyapi-provider`](https://github.com/router-for-me/pi-cliproxyapi-provider).

Enable it in `~/.fx/settings.json`:

```json
{
  "provider": "cliproxyapi",
  "model": "gpt-5.6-sol"
}
```

Configure the connection in `~/.fx/cliproxyapi.json`:

```json
{
  "baseUrl": "http://127.0.0.1:8317",
  "apiKey": "your-cli-proxy-api-key"
}
```

For compatibility with the Pi extension, the provider falls back to
`~/.pi/agent/cliproxyapi.json` when the fx-specific file is absent. Environment
variables take precedence over both files:

```bash
export FX_PROVIDER=cliproxyapi
export CLIPROXYAPI_BASE_URL=http://127.0.0.1:8317
export CLIPROXYAPI_API_KEY=your-cli-proxy-api-key
```

The provider discovers models from `/v1/models?client_version=fx` and sends
inference requests to `/backend-api/codex/responses`. Models with advertised
reasoning levels and service tiers expose the corresponding fx effort and Fast
controls.

fx starts in `auto` permission mode, which reviews unresolved sensitive actions. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend fx

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Project instruction files may link within their scope, and read-only workspace or compatibility skill directories may link within their owning workspace or home; managed skills, `SKILL.md` files, resources, and escaping links remain no-follow. `fx status` and `fx doctor` report an invalid trusted MCP profile without starting its servers.

## Documentation

Most upstream behavior remains compatible with the [fx documentation](https://fx.sh/docs).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/Justar96/n-fx.git
cd n-fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
