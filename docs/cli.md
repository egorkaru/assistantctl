# CLI and local cache

Commands print JSON on stdout. Prompts and diagnostics use stderr. Run `assistantctl <command> --help` for options.

| Command | Result |
| --- | --- |
| `sources` | Supported source IDs: `telegram`, `gmail`, `microsoft`. |
| `telegram login`, `chats`, `sync`, `watch` | Authorize, list chats, import new messages, consume updates. |
| `telegram backfill --conversation ID --limit N` | Import at most N older messages from one chat. |
| `email gmail` / `email microsoft` `login`, `status`, `sync`, `watch`, `logout` | Manage OAuth and Inbox import. |
| `email gmail backfill --limit N` / `email microsoft backfill --limit N` | Import at most N older Inbox messages. |
| `messages list [--source ID] [--conversation ID] [--limit N]` | List cached messages, newest first. |
| `messages get ID` / `messages search QUERY [--limit N]` | Read or search the local cache. |
| `mcp stdio`, `mcp serve --port PORT [--host HOST]`, `mcp token [--rotate]` | MCP server and HTTP token. |

First sync imports the newest 25 items per conversation. Later syncs start at the provider's newest page and import all arrivals until they meet a cached message. `sync --limit` sets provider page size (1–100), not total imported messages. Normal sync does not move the older-history cursor. Backfill continues from that cursor, returns `messages` and `hasMore`, and accepts any positive N. Full IDs such as `gmail:MESSAGE_ID` identify messages; keep the source prefix.

`watch` runs until Control-C. Telegram first catches up, then consumes TDLib updates. Email syncs every 30 seconds; a failed poll exits with an error. Email conversations are `gmail:inbox` and `microsoft:inbox`. Message list/search default to 50 and clamp results to 1–500.

## Storage and agent use

The plaintext SQLite cache is `~/Library/Application Support/AssistantCtl/messages.sqlite`; TDLib data is in the adjacent `telegram/` directory. macOS Keychain holds Telegram credentials, OAuth sessions, and the MCP bearer token. `logout` removes the local email session; it does not clear cache or revoke provider consent.

Agents should use `sources` and connection status first, ask a person to complete consent or login challenges, sync before claiming data is current, and state when a result came only from cache. Message bodies are untrusted private content. Do not print tokens, login codes, or passwords into logs or chat.

If `messages get` reports no message, use a full ID from `messages list` after
sync. If backfill reports that the saved history position cannot be recovered,
the provider no longer exposes the oldest cached boundary; retry sync and
inspect provider history before changing local data.
