# capacitor-tcp-socket

A TCP Socket Plugin for capacitor

Thanks [@ottimis](https://www.npmjs.com/package/@ottimis/tcp-socket)

## Install

```bash
npm install @deedarb/capacitor-tcp-socket
npx cap sync
```

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

### Reading

`read` returns one recv of at most `expectLen` bytes, base64-encoded, on both
platforms. `result` is `''` when nothing arrived within `timeout`, and once more
when the peer closed the connection — that close also fires `disconnection`,
and from then on `read` / `send` on that client reject with `Socket closed`,
so a read loop stops instead of spinning. A peer that drops is noticed on the
next `read` / `send`; nobody watches idle clients in the background.

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

The implementation uses only Node built-ins, so `capacitor-electron vendor`
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

| Prop         | Type                |
| ------------ | ------------------- |
| **`client`** | <code>number</code> |
| **`data`**   | <code>string</code> |


#### ReadResult

| Prop         | Type                | Description                                                                                                                                                                                                                                                                                                                |
| ------------ | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`result`** | <code>string</code> | Bytes received, base64-encoded (one recv: whatever the socket had, at most `expectLen`). Empty when nothing arrived within `timeout`, and — once — when the peer closed the connection; that close also fires `disconnection`, and every later `read` on the client rejects with `Socket closed`. Other I/O errors reject. |


#### ReadOptions

| Prop            | Type                | Description                                                                       |
| --------------- | ------------------- | --------------------------------------------------------------------------------- |
| **`client`**    | <code>number</code> |                                                                                   |
| **`expectLen`** | <code>number</code> | Upper bound for one read, in bytes.                                               |
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

| Prop         | Type                | Description                                                                |
| ------------ | ------------------- | -------------------------------------------------------------------------- |
| **`server`** | <code>number</code> | Handle of the listening socket, for {@link TcpSocketPlugin.stopListening}. |


#### ListenOptions

| Prop       | Type                | Description                                  |
| ---------- | ------------------- | -------------------------------------------- |
| **`port`** | <code>number</code> | Port to accept connections on. default: 9100 |


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
