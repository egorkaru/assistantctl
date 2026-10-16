# assistantctl

`assistantctl` imports Telegram, Gmail, and Microsoft Mail into a local SQLite cache. The CLI and MCP server let people and agents read cached messages. Provider access is read-only. Requires macOS 15+.

## Install

Download `assistantctl-macos-universal.tar.gz` from the latest GitHub release, then:

```sh
tar -xzf assistantctl-macos-universal.tar.gz
install assistantctl /usr/local/bin/assistantctl
```

Use an existing directory in your `PATH` if `/usr/local/bin` is unavailable. See [installation](docs/install.md) for source builds.

## First use

Set up [provider credentials](docs/providers.md), then authorize a source and read its cache:

```sh
assistantctl email gmail login --oauth-config /path/to/oauth-clients.json
assistantctl email gmail sync
assistantctl messages list --source gmail --limit 25
assistantctl messages get 'gmail:MESSAGE_ID'
```

Telegram supports phone login with `assistantctl telegram login --api-id ID --api-hash HASH --phone NUMBER` or QR login with `assistantctl telegram login --api-id ID --api-hash HASH --qr`. Microsoft Mail uses `assistantctl email microsoft login --oauth-config PATH`.

## MCP

For a local agent, launch `assistantctl mcp stdio` as its MCP command. For Streamable HTTP, run `assistantctl mcp serve --port 8765` and connect to `http://127.0.0.1:8765/mcp` with `Authorization: Bearer <token>`; obtain the token privately with `assistantctl mcp token`. The server implements MCP `2025-11-25`. See [MCP setup and security](docs/mcp.md).

## Guides

- [Installation and release archive](docs/install.md)
- [Telegram and email setup](docs/providers.md)
- [CLI commands, sync, backfill, and cache](docs/cli.md)
- [MCP tools and transports](docs/mcp.md)
- [Local build checks](docs/testing.md)
