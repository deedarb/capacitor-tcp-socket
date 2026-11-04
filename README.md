# capacitor-tcp-socket

A TCP Socket Plugin for capacitor

Thanks [@ottimis](https://www.npmjs.com/package/@ottimis/tcp-socket)

## Install

```bash
npm install @deedarb/capacitor-tcp-socket
npx cap sync
```

On iOS the plugin supports both Swift Package Manager and CocoaPods. New Capacitor 8 iOS projects use Swift
Package Manager by default, and `npx cap sync` adds the plugin as the `DeedarbCapacitorTcpSocket` product.

On Electron the platform has to be synced by its full package name — see
[Electron](#electron-windows-macos-linux):

```bash
npx cap sync @capawesome/capacitor-electron
```

## Version compatibility

| Plugin | Capacitor | iOS   | Android            | Electron                             |
| ------ | --------- | ----- | ------------------ | ------------------------------------ |
| 8.x    | 8.x       | 15.0+ | minSdk 24, Java 21 | `@capawesome/capacitor-electron` 0.1+ |
| 7.x    | 7.x       | 14.0+ | minSdk 23, Java 21 | —                                    |

## Server mode

Besides connecting out, a device can accept incoming connections — useful when
two devices on the same Wi-Fi need to talk to each other directly, with no
server in between.

```ts
import { TcpSocket } from '@deedarb/capacitor-tcp-socket';

// device A — subscribe first, then listen
await TcpSocket.addListener('connection', async ({ client, address }) => {
  console.log('peer connected', address);
  await TcpSocket.send({ client, data: btoa('hello') });
});
await TcpSocket.addListener('disconnection', ({ client }) => {
  console.log('peer gone', client);
});
const { server } = await TcpSocket.listen({ port: 9100 });

// device B — connect as usual
const { client } = await TcpSocket.connect({ ipAddress: '192.168.1.42', port: 9100 });
```

Accepted connections join the same pool as `connect`, so `send`, `read` and
`disconnect` take the `client` from the `connection` event unchanged.

`stopListening({ server })` stops accepting; clients already accepted stay open.

### Page reloads

Sockets belong to the page that opened them. When the web view starts a new
page — `location.reload()`, a live update — every client and server is closed
(8.3.1+), without `disconnection` events: the old page's listeners are gone
anyway. The new page starts clean and can `listen` on the same port again.
In-app routing (`history.pushState`, hash changes) is not a new page and
leaves the sockets alone, and so does a navigation that never happens (an
external link the app opens in the browser instead). On Electron, a new page
in any window showing the app's own pages counts; popups and windows showing
websites do not.

### Reading

`read` returns one recv of at most `expectLen` bytes, base64-encoded, on both
platforms. `result` is `''` when nothing arrived within `timeout`, and once more
when the peer closed the connection — that close also fires `disconnection`,
and from then on `read` / `send` on that client reject with `Socket closed`,
so a read loop stops instead of spinning. A peer that drops is noticed on the
next `read` / `send`; nobody watches idle clients in the background.

### Sending, threads and timeouts

`connect`, `send` and `read` never run on the bridge's shared thread (Android) /
queue (iOS): a `connect` to an address that is down, or a `send` to a peer that
stopped reading, does not hold up other plugin calls meanwhile. Sends on one
client go out one at a time, in call order, on every platform.

`send({ client, data, timeout })` (8.3.0+): with `timeout` (seconds) a write
the peer does not drain in time rejects with `Send timed out` and the
connection is closed — `disconnection` fires, later calls on the client reject
with `Socket closed`; sends queued behind it on that client reject too. The
timeout counts from the call, so a send queued behind a stuck one still
times out. Without it (or `0`) the write waits for as long as the peer does,
as in 8.2.

A failed `accept` on a listening socket (aborted handshake, out of descriptors)
does not end `listen` on iOS and Android: the socket retries, backing off up
to 5 s between attempts. Only one that keeps failing for a whole minute is
closed (logged, no event); `listen` again to recover.

### Errors

Every rejection carries a `code` (8.4.0+), the same on iOS, Android and
Electron — branch on it, not on the message, which is diagnostic text:

| `code`             | When                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------- |
| `INVALID_ARGUMENT` | The options are not valid, or the client / server id was never handed out.           |
| `CLOSED`           | The client is closed: by `disconnect`, after `disconnection`, or with its page.        |
| `TIMEOUT`          | `send` timed out; the client is closed with it.                                       |
| `CONNECT_FAILED`   | `connect` failed: refused, unreachable, unknown host, or timed out.                   |
| `LISTEN_FAILED`    | `listen` could not bind the port.                                                     |
| `IO_ERROR`         | A `read` / `send` failed (reset, broken pipe); `disconnection` has fired.             |
| `UNIMPLEMENTED`    | Not available on this platform (the browser).                                         |

```ts
try {
  await TcpSocket.send({ client, data });
} catch (error) {
  if ((error as TcpSocketError).code === 'CLOSED') {
    // reconnect
  }
}
```

Options are checked before the call reaches the native side, so a malformed
value is refused the same way everywhere: ports must be integers in range,
timeouts and ids whole numbers, 0 or more (a timeout past 2³¹−1 seconds is
clamped). `data` may contain line breaks and may omit its `=` padding; both
are normalised before sending.

### Upgrading to 8.4

- Values the platforms used to coerce silently are now refused with
  `INVALID_ARGUMENT`: a negative or fractional timeout or id, a port given as
  a string or out of range (`connect` to port 0 included), and `send` without
  `data` (Android used to send nothing and resolve).
- Electron: `error.code` used to be Node's own (`ECONNREFUSED`, `EADDRINUSE`,
  `ECONNRESET`, …); it is now one of the codes above, and Node's code stays in
  the message (`connect ECONNREFUSED 127.0.0.1:9100`).
- Android: `disconnect` and `stopListening` no longer reject when closing the
  socket fails — it is unusable either way, and its id is released.
- `listen` resolves with the bound `port` as well, so `port: 0` lets the
  system pick a free one.
- The browser implementation rejects with `UNIMPLEMENTED` and no longer logs
  the options (`send` used to print its payload to the console).

### iOS: local network permission

iOS 14+ **silently** blocks local network access unless the app declares it —
there is no error, connections simply never establish. Add to `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Explain here why your app talks to devices on the local network</string>
```

### Backgrounding

iOS suspends a backgrounded app, and the listening socket stops accepting.
Keep the app in the foreground while it needs to serve peers.

## Electron (Windows, macOS, Linux)

The desktop implementation runs in the Electron main process on Node's `net`
module, and speaks the same API as iOS and Android — base64 in, base64 out,
the same client ids, the same events.

It targets the [`@capawesome/capacitor-electron`](https://github.com/capawesome-team/capacitor-electron)
platform. The older `@capacitor-community/electron` uses a different plugin
contract and does not load this implementation.

```bash
npm install @capawesome/capacitor-electron
npx cap add @capawesome/capacitor-electron
cd electron && npm install && cd ..
npx cap sync @capawesome/capacitor-electron
```

That is the whole setup: the platform registers the plugin under its native
path, so `TcpSocket` works in the renderer with no extra wiring. A plain
`npx cap sync` skips Electron — pass the full package name.

The implementation uses only Node built-ins (and Electron itself), so `capacitor-electron vendor`
has nothing to rebuild when packaging.

Two things behave differently from mobile:

- **`connection` events are not retained.** On iOS and Android an event fired
  before the first listener is attached is delivered once the listener shows
  up; the Electron platform drops it. Subscribe before calling `listen` — which
  is the right order everywhere.
- **`getLocalAddress` skips virtual adapters.** Hyper-V, WSL, VM bridges, VPN
  tunnels and Bluetooth are ignored; `Wi-Fi` / `wlan*` / `en0` wins over
  Ethernet, and IPv4 over IPv6. `interfaceName` is the adapter name the OS
  reports — on Windows a friendly name such as `Wi-Fi` or `Ethernet`.

On Windows, the first `listen` raises the Windows Defender Firewall prompt;
without it inbound connections are blocked. In development the prompt names
Electron, in production the packaged app.

## API

<docgen-index>

* [`connect(...)`](#connect)
* [`send(...)`](#send)
* [`read(...)`](#read)
* [`disconnect(...)`](#disconnect)
* [`listen(...)`](#listen)
* [`stopListening(...)`](#stoplistening)
* [`getLocalAddress()`](#getlocaladdress)
* [`addListener('connection', ...)`](#addlistenerconnection-)
* [`addListener('disconnection', ...)`](#addlistenerdisconnection-)
* [Interfaces](#interfaces)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### connect(...)

```typescript
connect(options: ConnectOptions) => Promise<ConnectResult>
```

| Param         | Type                                                      |
| ------------- | --------------------------------------------------------- |
| **`options`** | <code><a href="#connectoptions">ConnectOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#connectresult">ConnectResult</a>&gt;</code>

--------------------


### send(...)

```typescript
send(options: SendOptions) => Promise<void>
```

| Param         | Type                                                |
| ------------- | --------------------------------------------------- |
| **`options`** | <code><a href="#sendoptions">SendOptions</a></code> |

--------------------


### read(...)

```typescript
read(options: ReadOptions) => Promise<ReadResult>
```

| Param         | Type                                                |
| ------------- | --------------------------------------------------- |
| **`options`** | <code><a href="#readoptions">ReadOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#readresult">ReadResult</a>&gt;</code>

--------------------


### disconnect(...)

```typescript
disconnect(options: DisconnectOptions) => Promise<DisconnectResult>
```

| Param         | Type                                                            |
| ------------- | --------------------------------------------------------------- |
| **`options`** | <code><a href="#disconnectoptions">DisconnectOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#disconnectresult">DisconnectResult</a>&gt;</code>

--------------------


### listen(...)

```typescript
listen(options: ListenOptions) => Promise<ListenResult>
```

Start accepting incoming connections on the given port.

Accepted connections join the same pool as {@link TcpSocketPlugin.connect},
so `send`, `read` and `disconnect` work with them unchanged — the `client`
handed out by the `connection` event is an ordinary client id.

Subscribe to `connection` before calling `listen`. On iOS and Android a peer that
connects before the first listener is attached is not lost — its event is retained
and delivered to that listener. On Electron it is not: the event is dropped, so
attaching the listener first is the only way to see that peer.

Servers and clients belong to the page that opened them: when the web view starts a
new page (reload, live update) they are all closed, without events (8.3.1+), so the
new page can listen on the same port again.

On iOS the app must declare `NSLocalNetworkUsageDescription` in Info.plist,
otherwise iOS 14+ silently blocks local network access.

| Param         | Type                                                    |
| ------------- | ------------------------------------------------------- |
| **`options`** | <code><a href="#listenoptions">ListenOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#listenresult">ListenResult</a>&gt;</code>

--------------------


### stopListening(...)

```typescript
stopListening(options: StopListeningOptions) => Promise<void>
```

Stop accepting connections. Clients already accepted stay open.

| Param         | Type                                                                  |
| ------------- | --------------------------------------------------------------------- |
| **`options`** | <code><a href="#stoplisteningoptions">StopListeningOptions</a></code> |

--------------------


### getLocalAddress()

```typescript
getLocalAddress() => Promise<LocalAddressResult>
```

Address of this device in the local network — the one peers can reach it at.

Prefers the Wi-Fi interface (`en0` on iOS, `wlan0` on Android, `Wi-Fi` / `wlan*` / `en0`
on Electron) and IPv4; virtual adapters (Hyper-V, WSL, VPN, VM bridges) are skipped.
`ip` is undefined when the device has no local-network address (airplane mode,
cellular only).

**Returns:** <code>Promise&lt;<a href="#localaddressresult">LocalAddressResult</a>&gt;</code>

--------------------


### addListener('connection', ...)

```typescript
addListener(eventName: 'connection', listenerFunc: (event: ConnectionEvent) => void) => Promise<PluginListenerHandle>
```

A peer connected to a listening socket.

| Param              | Type                                                                            |
| ------------------ | ------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'connection'</code>                                                       |
| **`listenerFunc`** | <code>(event: <a href="#connectionevent">ConnectionEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('disconnection', ...)

```typescript
addListener(eventName: 'disconnection', listenerFunc: (event: DisconnectionEvent) => void) => Promise<PluginListenerHandle>
```

The peer closed the connection, or it dropped.

Detected on the next `read` / `send` on that client — there is no background watchdog, so a
client nobody reads from or writes to reports nothing. Fired once per client; after it every
`read` / `send` on that client rejects with `Socket closed`. A local `disconnect` does not
fire it.

| Param              | Type                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'disconnection'</code>                                                          |
| **`listenerFunc`** | <code>(event: <a href="#disconnectionevent">DisconnectionEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### Interfaces


#### ConnectResult

| Prop         | Type                |
| ------------ | ------------------- |
| **`client`** | <code>number</code> |


#### ConnectOptions

| Prop            | Type                | Description                     |
| --------------- | ------------------- | ------------------------------- |
| **`ipAddress`** | <code>string</code> |                                 |
| **`port`**      | <code>number</code> |                                 |
| **`timeout`**   | <code>number</code> | Timeout in seconds. default: 10 |


#### SendOptions

| Prop          | Type                | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Since |
| ------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| **`client`**  | <code>number</code> |                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |       |
| **`data`**    | <code>string</code> |                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |       |
| **`timeout`** | <code>number</code> | Timeout in seconds for the whole write. A peer that does not read lets the send buffers fill up, and the write then waits for it; past the timeout the call rejects with `Send timed out` and the connection is closed (as when the peer is gone: `disconnection` fires, later calls on the client reject with `Socket closed`) — part of the data may already have been sent. 0 or not set: no limit, the write waits for as long as the peer does. default: 0 | 8.3.0 |


#### ReadResult

| Prop         | Type                | Description                                                                                                                                                                                                                                                                                                                |
| ------------ | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`result`** | <code>string</code> | Bytes received, base64-encoded (one recv: whatever the socket had, at most `expectLen`). Empty when nothing arrived within `timeout`, and — once — when the peer closed the connection; that close also fires `disconnection`, and every later `read` on the client rejects with `Socket closed`. Other I/O errors reject. |


#### ReadOptions

| Prop            | Type                | Description                                                                       |
| --------------- | ------------------- | --------------------------------------------------------------------------------- |
| **`client`**    | <code>number</code> |                                                                                   |
| **`expectLen`** | <code>number</code> | Upper bound for one read, in bytes. default: 1024                                 |
| **`timeout`**   | <code>number</code> | timeout in seconds; 0 returns at once with whatever is already there. default: 10 |


#### DisconnectResult

| Prop         | Type                |
| ------------ | ------------------- |
| **`client`** | <code>number</code> |


#### DisconnectOptions

| Prop         | Type                |
| ------------ | ------------------- |
| **`client`** | <code>number</code> |


#### ListenResult

| Prop         | Type                | Description                                                                         | Since |
| ------------ | ------------------- | ----------------------------------------------------------------------------------- | ----- |
| **`server`** | <code>number</code> | Handle of the listening socket, for {@link TcpSocketPlugin.stopListening}.          |       |
| **`port`**   | <code>number</code> | Port the socket is bound to: the one asked for, or the one the system picked for 0. | 8.4.0 |


#### ListenOptions

| Prop       | Type                | Description                                                                                                      |
| ---------- | ------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **`port`** | <code>number</code> | Port to accept connections on; 0 lets the system pick a free one, reported in `ListenResult.port`. default: 9100 |


#### StopListeningOptions

| Prop         | Type                |
| ------------ | ------------------- |
| **`server`** | <code>number</code> |


#### LocalAddressResult

| Prop                | Type                | Description                                                            |
| ------------------- | ------------------- | ---------------------------------------------------------------------- |
| **`ip`**            | <code>string</code> | IPv4 (or IPv6 if that is all there is) of the local-network interface. |
| **`interfaceName`** | <code>string</code> | Interface the address belongs to, e.g. `en0` / `wlan0`.                |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### ConnectionEvent

| Prop          | Type                | Description                                            |
| ------------- | ------------------- | ------------------------------------------------------ |
| **`server`**  | <code>number</code> | Listening socket that accepted this peer.              |
| **`client`**  | <code>number</code> | Client id, usable with `send` / `read` / `disconnect`. |
| **`address`** | <code>string</code> | Peer address, e.g. `192.168.1.42`.                     |


#### DisconnectionEvent

| Prop         | Type                | Description                                              |
| ------------ | ------------------- | -------------------------------------------------------- |
| **`client`** | <code>number</code> | Client whose peer is gone; the socket is already closed. |

</docgen-api>
