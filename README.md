# n-fx

n-fx is an experimental fork of [Vercel's fx](https://github.com/vercel-labs/fx)
with native [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) support.
It keeps the `fx` command and `~/.fx` configuration layout.

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

The installer verifies the release checksum and writes `fx` to
`~/.local/bin`. Install a specific version with:

```bash
curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh | bash -s -- v0.0.4
```

Set `N_FX_INSTALL_DIR` to choose a different directory.

## Configure CLIProxyAPI

Select the provider in `~/.fx/settings.json`:

```json
{
  "provider": "cliproxyapi",
  "model": "gpt-5.6-sol"
}
```

Add the connection to `~/.fx/cliproxyapi.json`:

```json
{
  "baseUrl": "http://127.0.0.1:8317",
  "apiKey": "your-cli-proxy-api-key"
}
```

You can instead set `CLIPROXYAPI_BASE_URL` and `CLIPROXYAPI_API_KEY`. If the
n-fx file is absent, n-fx also reads `~/.pi/agent/cliproxyapi.json`.

## Use

```bash
fx status
fx models
fx ask "explain this repository"
fx
```

The final command starts the interactive coding agent in the current directory.
Most behavior remains compatible with the [fx documentation](https://fx.sh/docs).

## Build from source

Requires Zig 0.16.0 or newer:

```bash
git clone https://github.com/Justar96/n-fx.git
cd n-fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

## License

Apache-2.0. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
