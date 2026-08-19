# n-fx

n-fx is an experimental fork of [Vercel's fx](https://github.com/vercel-labs/fx)
with native [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) support.
It installs as the `nfx` command. Provider credentials live in `~/.nfx`, while
fx-compatible sessions and history remain in `~/.fx`.

## What n-fx adds

- CLIProxyAPI model discovery and OpenAI Responses transport
- Reasoning effort, Fast service tiers, vision metadata, and tool calls
- Configuration shared with
  [`pi-cliproxyapi-provider`](https://github.com/router-for-me/pi-cliproxyapi-provider)
- Verified binaries and upgrades from
  [n-fx GitHub Releases](https://github.com/Justar96/n-fx/releases)

## Install

Linux and macOS on x86_64 and ARM64 are supported:

```bash
curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh | bash
```

The installer verifies the release checksum and writes `nfx` to
`~/.local/bin`. Install a specific version with:

```bash
curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh | bash -s -- v0.0.4
```

Set `NFX_INSTALL_DIR` to choose a different directory.

## Configure CLIProxyAPI

Run the validated login flow:

```bash
nfx login cliproxyapi
```

This checks the server's model endpoint before writing
`~/.nfx/settings.json` and `~/.nfx/cliproxyapi.json`. For scripts:

```bash
printf '%s\n' "$CLIPROXYAPI_API_KEY" | \
  nfx login cliproxyapi --base-url http://127.0.0.1:8317 --api-key-stdin
```

To import only CLIProxyAPI credentials from an older fx setup:

```bash
nfx login cliproxyapi --migrate-from-fx
```

Migration reads `~/.fx/cliproxyapi.json`, with environment variables filling
missing values. It does not move or rewrite fx sessions, history, or OAuth
credentials.

The resulting nfx settings are:

```json
{
  "provider": "cliproxyapi"
}
```

and:

```json
{
  "baseUrl": "http://127.0.0.1:8317",
  "apiKey": "your-cli-proxy-api-key"
}
```

Environment variables take precedence over saved values. When no nfx provider
file exists, nfx reads legacy `~/.fx/cliproxyapi.json`, then
`~/.pi/agent/cliproxyapi.json`.

## Use

```bash
nfx status
nfx models
nfx ask "explain this repository"
nfx
```

The final command starts the interactive coding agent in the current directory.
Most behavior remains compatible with the [fx documentation](https://fx.sh/docs).

## Drive n-fx from another agent

```bash
nfx help --json                       # machine-readable command contract
nfx ask --stream-json "fix the test"  # one JSON event per line while running
```

See [docs/agent-cli.md](docs/agent-cli.md) for the event schema, error codes,
exit codes, and path handling.

## Build from source

Requires Zig 0.16.0 or newer:

```bash
git clone https://github.com/Justar96/n-fx.git
cd n-fx
zig build -Doptimize=ReleaseSafe
install -m 755 zig-out/bin/fx ~/.local/bin/nfx
nfx
```

## License

Apache-2.0. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
