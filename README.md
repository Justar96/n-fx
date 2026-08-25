```
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⣿⣿⣷⣶⣶⣶⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
⠀⣿⣿⡟⠉⠉⠻⣿⣦⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀
⠀⣿⣿⡇⠀⠀⠀⢻⣿⣧⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
⠀⣿⣿⡇⠀⠀⠀⢸⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀
⠀⣿⣿⡇⠀⠀⠀⢸⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
⠀⣿⣿⡇⠀⠀⠀⢸⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

# n-fx

n-fx is [fx](https://github.com/vercel-labs/fx) with a custom
OpenAI-compatible provider. Its adapter is built for
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), and the command is
installed as `nfx`.

## Install

Linux and macOS on x86_64 and ARM64 are supported.

```bash
curl -fsSL https://raw.githubusercontent.com/Justar96/n-fx/main/install.sh | bash
```

The installer verifies the release checksum and writes `nfx` to
`~/.local/bin`. Set `NFX_INSTALL_DIR` to use another directory.

## Connect a provider

Start `nfx` and choose **Custom provider** during onboarding. To change it
later, enter `/login`, open **Connections**, and choose **Custom provider**.
The URL defaults to `http://127.0.0.1:8317`.

You can also configure the connection directly:

```bash
nfx login cliproxyapi
```

For scripts:

```bash
printf '%s\n' "$CLIPROXYAPI_API_KEY" | \
  nfx login cliproxyapi --base-url http://127.0.0.1:8317 --api-key-stdin
```

Set `CLIPROXYAPI_BASE_URL` and `CLIPROXYAPI_API_KEY` to override saved values.
Plain HTTP is accepted only for loopback servers; remote servers require HTTPS.

## Run

```bash
nfx models
nfx ask "explain this repository"
nfx
```

Most commands remain compatible with the [fx documentation](https://fx.sh/docs).
For JSON output and automation, see [the agent CLI guide](docs/agent-cli.md).

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
