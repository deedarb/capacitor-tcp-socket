# capacitor-tcp-socket

A TCP Socket Plugin for capacitor

Thanks [@ottimis](https://www.npmjs.com/package/@ottimis/tcp-socket)

## Install

```bash
npm install @deedarb/capacitor-tcp-socket
npx cap sync
```

## Version compatibility

| Plugin | Capacitor | iOS   | Android            |
| ------ | --------- | ----- | ------------------ |
| 8.x    | 8.x       | 15.0+ | minSdk 24, Java 21 |
| 7.x    | 7.x       | 14.0+ | minSdk 23, Java 21 |

## Server mode

Besides connecting out, a device can accept incoming connections — useful when
two devices on the same Wi-Fi need to talk to each other directly, with no
server in between.

```ts
import { TcpSocket } from '@deedarb/capacitor-tcp-socket';

// device A — listen
const { server } = await TcpSocket.listen({ port: 9100 });
await TcpSocket.addListener('connection', async ({ client, address }) => {
  console.log('peer connected', address);
  await TcpSocket.send({ client, data: btoa('hello') });
});

// device B — connect as usual
const { client } = await TcpSocket.connect({ ipAddress: '192.168.1.42', port: 9100 });
```

Accepted connections join the same pool as `connect`, so `send`, `read` and
`disconnect` take the `client` from the `connection` event unchanged.

`stopListening({ server })` stops accepting; clients already accepted stay open.

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

## API

<docgen-index>

* [`connect(...)`](#connect)
* [`send(...)`](#send)
* [`read(...)`](#read)
* [`disconnect(...)`](#disconnect)
* [`listen(...)`](#listen)
* [`stopListening(...)`](#stoplistening)
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

A peer closed the connection, or it dropped.

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

| Prop         | Type                |
| ------------ | ------------------- |
| **`result`** | <code>string</code> |


#### ReadOptions

| Prop            | Type                | Description                     |
| --------------- | ------------------- | ------------------------------- |
| **`client`**    | <code>number</code> |                                 |
| **`expectLen`** | <code>number</code> |                                 |
| **`timeout`**   | <code>number</code> | timeout in seconds. default: 10 |


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

| Prop         | Type                |
| ------------ | ------------------- |
| **`client`** | <code>number</code> |

</docgen-api>
