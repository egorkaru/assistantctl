# Provider authorization

Authorize only the sources you use. The CLI uses macOS Keychain for Telegram
credentials and email OAuth sessions. Message bodies are stored separately in
a local SQLite cache; see [data storage](cli.md#data-storage).

## Telegram

Get an API ID and hash at [my.telegram.org](https://my.telegram.org). Run:

```sh
assistantctl telegram login --api-id YOUR_ID --api-hash YOUR_HASH --phone YOUR_PHONE
assistantctl telegram chats
assistantctl telegram sync
```

Each `telegram login` attempt requests a new code unless the session is already
authorized. Login reports the delivery channel before prompting. A code sent
to another Telegram session appears in the Telegram service chat in that app;
it may not arrive by SMS. Login may also prompt for a two-factor password.
`telegram chats`, `sync`, `backfill`, and `watch` require an authorized session;
they do not start login.

To log in without a code, use an already authorized Telegram app to scan a QR
code displayed in the terminal:

```sh
assistantctl telegram login --api-id YOUR_ID --api-hash YOUR_HASH --qr
```

The QR code is refreshed when TDLib replaces its login link. Scan the newest
code and approve the session in Telegram. QR login does not need `--phone` and
cannot be combined with it. Existing Keychain or embedded API credentials work
without repeating `--api-id` and `--api-hash`.

Values passed as options or environment variables are saved in Keychain for
later Telegram commands. You can provide
`ASSISTANTCTL_TELEGRAM_API_ID`, `ASSISTANTCTL_TELEGRAM_API_HASH`, and
`ASSISTANTCTL_TELEGRAM_PHONE` as environment variables.
For the API ID and hash, precedence is command options, environment, Keychain,
then an optional pair embedded by the source builder. The phone number always
comes from an option, environment variable, or Keychain. To replace a stored
API ID and hash, pass both values to `assistantctl telegram login` again.

To embed your Telegram app registration in a source build:

```sh
mkdir -p .assistantctl-private
cp Config/telegram-app.example.json .assistantctl-private/telegram-app.json
# Edit apiId and apiHash in .assistantctl-private/telegram-app.json.
swift build -c release --disable-build-manifest-caching
```

The ignored JSON file contains only the app registration pair:

```json
{"version":1,"apiId":123456,"apiHash":"replace-me"}
```

Replace both example values before building. If the file is absent, the build
contains no Telegram app credentials. An existing Keychain pair takes priority
over the embedded pair; a partial external pair is an error and is never mixed
with embedded values. Anyone with the binary can extract embedded app values.
Never put a phone number, login code, or two-factor password in this file.
After removing a previously embedded file, rebuild with
`swift build -c release --disable-build-manifest-caching` so SwiftPM discards
its cached reference to the deleted file. The static build script does this
automatically.

## Email OAuth client configuration

Create the provider app registrations below. Copy the example and replace its
placeholder values. Pass the file at login; rebuilding is unnecessary:

```sh
mkdir -p .assistantctl-private
cp Config/oauth-clients.example.json .assistantctl-private/oauth-clients.json
assistantctl email gmail login --oauth-config .assistantctl-private/oauth-clients.json
```

The `.assistantctl-private` directory is ignored by Git. The JSON contains
application client values, never account access or refresh tokens. An
installed binary can use any readable path:

```sh
assistantctl email gmail login --oauth-config /path/to/oauth-clients.json
ASSISTANTCTL_OAUTH_CONFIG=/path/to/oauth-clients.json assistantctl email microsoft login
```

Configuration precedence is `--oauth-config`,
`ASSISTANTCTL_OAUTH_CONFIG`, then the embedded configuration. A user supplied
client configuration is retained with the Keychain session for refreshes.
An embedded client configuration is read from the binary and is not copied to
Keychain. Issued access and refresh tokens are saved in Keychain.
Source builders may embed a configuration through the SwiftPM build plugin,
but public release binaries do not include one.

### Gmail

1. Create a Google Cloud project and enable the Gmail API.
2. Configure the OAuth consent screen. Add test accounts while the app is in
   testing.
3. Create a **Desktop app** OAuth client, not a Web application, iOS, or Android
   client. Put that client's ID and desktop client secret in the `gmail` entry
   of the JSON file. Google does not ask you to enter a redirect URI when
   creating a Desktop app client; see [Google's client setup](https://support.google.com/cloud/answer/15549257).
4. Run `assistantctl email gmail login` and complete browser consent.

Login uses PKCE and sends `http://127.0.0.1:<random-port>` as the redirect URI,
with no path. The port changes for each login. A Web application client with a
fixed registered redirect URI does not match this flow. If Google shows
`Error 400: redirect_uri_mismatch`, check that the `clientId` belongs to the
**Desktop app** client in the Google Cloud project you configured. The JSON
file has no `redirectUri` field; the CLI creates the loopback URI when login
starts. It requests
`https://www.googleapis.com/auth/gmail.readonly` and offline access. Google
classifies `gmail.readonly` as a restricted scope; broad production use needs
the appropriate [OAuth verification](https://developers.google.com/workspace/gmail/api/auth/scopes).
See [Google's installed-app flow](https://developers.google.com/identity/protocols/oauth2/native-app).

### Microsoft Mail

1. Register an app in Microsoft Entra ID for the accounts you intend to
   support. The example uses tenant `common`.
2. Under **App registrations → Authentication**, add the **Mobile and desktop
   applications** platform with the exact redirect URI `http://localhost`.
   Enable public client flows; do not create a client secret. Microsoft ignores
   the random port in the CLI's `http://localhost:<random-port>` callback when
   matching this registered URI. Do not register `https://localhost`,
   `http://127.0.0.1`, or a Web platform redirect for this flow.
3. Add delegated Microsoft Graph `Mail.Read`, put the client ID under
   `microsoft` in the JSON, and run `assistantctl email microsoft login`.

Login uses PKCE and requests `Mail.Read` and `offline_access`. The JSON file
has no `redirectUri` field. See [Microsoft desktop app configuration](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-configuration),
[localhost redirect matching](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url#localhost-exceptions),
and [Graph permissions](https://learn.microsoft.com/en-us/graph/permissions-reference#mailread).

## Email access tokens

An already valid bearer token can replace browser login. A token supplied for
`sync` or `watch` is saved in Keychain for later commands:

```sh
ASSISTANTCTL_GMAIL_ACCESS_TOKEN=TOKEN assistantctl email gmail sync
ASSISTANTCTL_MICROSOFT_ACCESS_TOKEN=TOKEN assistantctl email microsoft sync
```

`--access-token TOKEN` also works, but can expose the token in shell history
or process listings. Browser login replaces a saved manual token. `logout`
removes both the saved manual token and OAuth session. Gmail app passwords,
API keys, client IDs, and client secrets are not bearer tokens.

## Troubleshooting

If email login says the OAuth configuration is missing, pass
`--oauth-config /absolute/path/to/oauth-clients.json` and confirm the file has
the matching `gmail` or `microsoft` entry. If browser consent fails, check the
provider app's client type and redirect configuration above, then retry login
on the same Mac running the CLI; the callback listens on loopback. Google needs
a Desktop app client ID, while Microsoft needs `http://localhost` on the
Mobile and desktop applications platform. `email gmail status` or
`email microsoft status` should print `"connected": true` after consent.

If sync reports an authorization error, log in again; a saved local session
does not prove provider consent is still valid. If Telegram asks for a code or
two-factor password, supply it to the CLI prompt or MCP login session. Cache
and Keychain locations are in the [CLI guide](cli.md#storage-and-agent-use).
