# n-fx

n-fx is a fork of [Vercel's fx](https://github.com/vercel-labs/fx) with native
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) support. It installs
as `nfx` and adds model discovery, reasoning controls, tool calls, and streaming
JSON output.

CLIProxyAPI credentials live in `~/.nfx`. Sessions and history remain in
`~/.fx`.

## Install

Linux and macOS on x86_64 and ARM64 are supported.

```bash
curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh | bash
```

The installer verifies the release checksum and writes `nfx` to
`~/.local/bin`. Set `NFX_INSTALL_DIR` to use another directory.

## CLIProxyAPI

Save and validate the server URL and API key:

```bash
nfx login cliproxyapi
```

For scripts:

```bash
printf '%s\n' "$CLIPROXYAPI_API_KEY" | \
  nfx login cliproxyapi --base-url http://127.0.0.1:8317 --api-key-stdin
```

Use `CLIPROXYAPI_BASE_URL` and `CLIPROXYAPI_API_KEY` to override saved values.
Import an older fx CLIProxyAPI configuration with:

```bash
nfx login cliproxyapi --migrate-from-fx
```

## Use

```bash
nfx models
nfx ask "explain this repository"
nfx
```

For automation:

```bash
nfx help --json
nfx ask --stream-json "fix the test"
```

See [docs/agent-cli.md](docs/agent-cli.md) for the JSON event schema and exit
codes. Most commands remain compatible with the
[fx documentation](https://fx.sh/docs).

## License

Apache-2.0. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
