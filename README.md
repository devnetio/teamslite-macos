# TeamsLite

A small native macOS client for Microsoft Teams **chats** (1:1, group and meeting chats).
Swift + AppKit, no WebView, no Electron, no third-party dependencies.

> Unofficial. TeamsLite is not affiliated with or endorsed by Microsoft. Microsoft Teams is a
> trademark of Microsoft Corporation. It uses only the public Microsoft Graph API.

Features: chat list with unread state, read/send messages, mark as read (synced with Teams),
new 1:1 chat, inline images (view thumbnails, click for full size in Preview; send by paste,
drag & drop or the photo button), “always Available” status, desktop notifications, Dock badge,
per-chat drafts, “Open in Teams” for anything not supported here.
Out of scope on purpose: calls, meetings, calendar, file sharing, search, channels.

## Images

Received images are downloaded one at a time (Graph allows ~1 hosted-content request per second
per chat) and decoded straight to a 640 px thumbnail, never the full bitmap. Thumbnails live in an
LRU capped at 12 MB; message bodies containing images are not kept in the render cache, so the cap
really bounds memory. Outgoing images are sent as Graph `hostedContents`; large ones are scaled to
2560 px / re-encoded so a message stays under Graph's ~4 MB request limit.

## Always Available

While TeamsLite runs it keeps an app presence session at *Available* (`setPresence`, 4 h expiry,
renewed hourly and after wake) and sets the preferred presence to *Available*
(`setUserPreferredPresence`). This overrides Away/Busy everywhere until you turn it off
(TeamsLite menu → *Always Show Me as Available*, or Settings), which clears both. After TeamsLite
quits, the session expires within 4 hours. Needs `Presence.ReadWrite`, granted once in the browser
(TeamsLite asks; also *Grant Status Permission…* in the app menu).

## Memory

Measured with `footprint` on an M1, macOS 26, window open with chats loaded:

| | Footprint |
|---|---|
| Empty AppKit window (baseline) | ~17 MB |
| TeamsLite, demo data | ~26 MB (~32 MB with an image shown) |
| TeamsLite, real account (~50 chats) | ~48 MB (peak ~65 MB during first load) |

Closing the window (⌘W) releases the whole UI; the app keeps running in the Dock for notifications.

## How it works

```
Microsoft Graph ──change notification──▶ relay Worker (Cloudflare) ──WebSocket──▶ TeamsLite
       ▲                                                                              │
       └──────────── GET message / POST message / markChatReadForUser ───────────────┘
```

* **No polling.** Microsoft's Teams API rules allow polling for changes at most once a day,
  so TeamsLite subscribes to `/users/{id}/chats/getAllMessages` change notifications.
  Notifications go to a tiny relay (`relay/worker.js`, a Worker + Durable Object) and are pushed
  to the app over one idle WebSocket. The app then fetches only the message that changed.
* The relay only sees chat and message IDs, never message text, and keeps no data.
  Each install uses a random 256-bit room id, and the app checks Graph's `clientState`.
* The chat list is loaded at start-up, after wake / reconnect, when the app is activated
  (at most every 2 minutes) and on ⌘R.
* Sign-in: OAuth 2.0 authorization code + PKCE in your default browser (loopback redirect), with
  a device-code fallback. The refresh token is stored in the login keychain.
* Client ID: the public *Microsoft Graph Command Line Tools* app (`14d82eec-…`), already
  consented in this tenant. Scopes: `User.Read User.ReadBasic.All Chat.ReadWrite offline_access`.
  You can switch to your own app registration in Settings (redirect URI `http://localhost`, public client).

## Build & install

Requires Xcode Command Line Tools (Swift 5.9+).

```bash
scripts/build.sh            # -> build/TeamsLite.app
scripts/build.sh --install  # also copies it to /Applications
scripts/test.sh             # logic tests
```

Ad-hoc signed: after a rebuild, macOS asks once for keychain access (choose *Always Allow*).

Debug aids: `--demo` (offline sample data), `--snapshot out.png`, `--appearance dark`.
Logs: `log stream --predicate 'subsystem == "com.devnetio.TeamsLite"'`.

## Relay

Live updates need your own relay (free Cloudflare Workers plan is enough):

```bash
cd relay && npx wrangler deploy
```

Then paste the printed URL (e.g. `https://teamslite-relay.<your-subdomain>.workers.dev`) into
Settings → *Relay URL*. Without a relay, chats refresh only on start-up, activation and ⌘R.

## Keyboard

Return sends · Shift/Option-Return adds a new line · ⌘N new chat · ⌘R refresh ·
⇧⌘O open chat in Teams · ⌘0 show window · ⌃⌘Space emoji

## License

MIT. See [LICENSE](LICENSE).
