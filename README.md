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

The interactive app also offers **Custom provider** during first-run onboarding.
To configure or replace the connection later, run `nfx`, enter `/login`, open
**Connections**, and choose **Custom provider**. The URL defaults to
`http://127.0.0.1:8317`; the API key is masked, validated, and saved through the
same flow as `nfx login cliproxyapi`. This custom provider route uses n-fx's
CLIProxyAPI-compatible adapter for the OpenAI-compatible `/v1/models` and
`/v1/responses` endpoints.

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

nfx uses CLIProxyAPI's OpenAI-compatible `/v1/models` and `/v1/responses`
interfaces for model discovery, live streaming, tools, and image input when the
selected model advertises it. Plain HTTP is accepted only for loopback servers
such as the default `127.0.0.1` endpoint. Use HTTPS for remote servers.

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

## Develop the fork

n-fx keeps fork-owned behavior separate from shared upstream integration
points. The development guide documents path ownership, feature boundaries,
the upstream sync workflow, and required verification:

- [Fork development and upstream integration](docs/fork-development.md)
- [Machine-readable fork boundary](docs/fork-manifest.json)

Inspect the current patch before starting or reviewing fork work:

```bash
python3 scripts/fork_status.py --fetch --check
```

## License

Apache-2.0. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
