# MCP server

The Swift executable uses the official Swift MCP SDK and supports protocol version `2025-11-25`.

## Stdio

Configure your agent's MCP client to launch `assistantctl mcp stdio`. The process writes only MCP frames to stdout; diagnostics go to stderr. Closing stdin ends the session. The CLI and MCP tools share the same Keychain sessions and SQLite cache.

## Streamable HTTP

```sh
assistantctl mcp token
assistantctl mcp serve --port 8765
```

Connect to `http://127.0.0.1:8765/mcp`. Send `Authorization: Bearer TOKEN` on every request. `assistantctl mcp token --rotate` replaces the Keychain token and immediately rejects the previous token. Do not log token output. The server checks Host and Origin. If an HTTP client sends Origin, it must be `http://127.0.0.1:8765` for the default binding.

To allow LAN clients, explicitly bind a concrete interface address, for example `assistantctl mcp serve --host 192.168.1.10 --port 8765`; clients use that address in Host and Origin. This is plain HTTP. Network observers can see the bearer token and login codes/passwords; use it only on a trusted network or through a private encrypted tunnel. Wildcard bind addresses are rejected.

## Tools

| Tool | Inputs | Result |
| --- | --- | --- |
| `sources` | none | Provider IDs. |
| `connection_status` | `provider` | Connection state without credentials. |
| `conversations` | `provider` | Telegram chats or email Inbox. |
| `messages_list` | optional `source`, `conversation`, `limit` | Cached messages. |
| `messages_get` | `id` | One cached message. |
| `messages_search` | `query`, optional `limit` | Cached matches. |
| `sync` | `provider` | New-message import count. |
| `backfill` | `provider`, `limit`; Telegram also `conversation` | Older-message import count and `hasMore`. |
| `login_start` | `provider`; Telegram `api_id`, `api_hash`, `phone`; email optional `oauth_config` | Session ID and required human action. |
| `login_complete` | `session_id`, `value` | Submit requested Telegram code or two-factor password. |
| `login_status` | `session_id` | Pending, connected, failed, or expired status. |

For email, `login_start` opens the system browser on the server Mac and waits for its loopback callback. Poll `login_status`. For Telegram, poll `login_status`; when action is `telegram_code` or `telegram_password`, have the person provide the requested value through `login_complete`. Login sessions live in server memory and expire after five minutes. Never send a code or password to a different tool. Server restart discards pending sessions.

## Troubleshooting

An HTTP 401 means the bearer is missing or stale; obtain the current token
privately with `assistantctl mcp token`. HTTP 403 means Host or Origin does not
match the address bound with `--host` and `--port`. If `login_status` says the
session is expired, start login again. Read tools return cached data; run
`sync` first when current provider data is required. Cache and Keychain
locations are in the [CLI guide](cli.md#storage-and-agent-use).
