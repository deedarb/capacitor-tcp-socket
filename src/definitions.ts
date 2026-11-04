import type { PluginListenerHandle } from '@capacitor/core';

export interface TcpSocketPlugin {
  connect(options: ConnectOptions): Promise<ConnectResult>;
  send(options: SendOptions): Promise<void>;
  read(options: ReadOptions): Promise<ReadResult>;
  disconnect(options: DisconnectOptions): Promise<DisconnectResult>;

  /**
   * Start accepting incoming connections on the given port.
   *
   * Accepted connections join the same pool as {@link TcpSocketPlugin.connect},
   * so `send`, `read` and `disconnect` work with them unchanged — the `client`
   * handed out by the `connection` event is an ordinary client id.
   *
   * Subscribe to `connection` before calling `listen`. On iOS and Android a peer that
   * connects before the first listener is attached is not lost — its event is retained
   * and delivered to that listener. On Electron it is not: the event is dropped, so
   * attaching the listener first is the only way to see that peer.
   *
   * Servers and clients belong to the page that opened them: when the web view starts a
   * new page (reload, live update) they are all closed, without events (8.3.1+), so the
   * new page can listen on the same port again.
   *
   * On iOS the app must declare `NSLocalNetworkUsageDescription` in Info.plist,
   * otherwise iOS 14+ silently blocks local network access.
   */
  listen(options: ListenOptions): Promise<ListenResult>;

  /** Stop accepting connections. Clients already accepted stay open. */
  stopListening(options: StopListeningOptions): Promise<void>;

  /**
   * Address of this device in the local network — the one peers can reach it at.
   *
   * Prefers the Wi-Fi interface (`en0` on iOS, `wlan0` on Android, `Wi-Fi` / `wlan*` / `en0`
   * on Electron) and IPv4; virtual adapters (Hyper-V, WSL, VPN, VM bridges) are skipped.
   * `ip` is undefined when the device has no local-network address (airplane mode,
   * cellular only).
   */
  getLocalAddress(): Promise<LocalAddressResult>;

  /** A peer connected to a listening socket. */
  addListener(eventName: 'connection', listenerFunc: (event: ConnectionEvent) => void): Promise<PluginListenerHandle>;

  /**
   * The peer closed the connection, or it dropped.
   *
   * Detected on the next `read` / `send` on that client — there is no background watchdog, so a
   * client nobody reads from or writes to reports nothing. Fired once per client; after it every
   * `read` / `send` on that client rejects with `Socket closed`. A local `disconnect` does not
   * fire it.
   */
  addListener(
    eventName: 'disconnection',
    listenerFunc: (event: DisconnectionEvent) => void,
  ): Promise<PluginListenerHandle>;
}

// types

/**
 * `code` of a rejected call, the same on iOS, Android and Electron. Branch on it, not on the
 * message: that is diagnostic text and differs between platforms.
 *
 * - `INVALID_ARGUMENT`: the options are not valid (checked before the call reaches the native
 *   side), or the client / server id was never handed out.
 * - `CLOSED`: the client is closed — by `disconnect`, after `disconnection`, or with the page
 *   that opened it.
 * - `TIMEOUT`: `send` timed out; the client is closed with it.
 * - `CONNECT_FAILED`: `connect` failed: refused, unreachable, unknown host, or timed out.
 * - `LISTEN_FAILED`: `listen` could not bind the port.
 * - `IO_ERROR`: a `read` / `send` failed (connection reset, broken pipe); the peer is gone and
 *   `disconnection` has fired.
 * - `UNIMPLEMENTED`: not available on this platform (the browser).
 *
 * @since 8.4.0
 */
export type TcpSocketErrorCode =
  'INVALID_ARGUMENT' | 'CLOSED' | 'TIMEOUT' | 'CONNECT_FAILED' | 'LISTEN_FAILED' | 'IO_ERROR' | 'UNIMPLEMENTED';

/**
 * Shape of a rejection from this plugin.
 *
 * @since 8.4.0
 */
export interface TcpSocketError extends Error {
  code: TcpSocketErrorCode;
}

export interface ConnectOptions {
  ipAddress: string;
  port?: number;
  /**
   * Timeout in seconds.
   *
   * default: 10
   */
  timeout?: number;
}
export interface ConnectResult {
  client: number;
}

export interface SendOptions {
  client: number;
  data: string;
  /**
   * Timeout in seconds for the whole write. A peer that does not read lets the send
   * buffers fill up, and the write then waits for it; past the timeout the call rejects
   * with `Send timed out` and the connection is closed (as when the peer is gone:
   * `disconnection` fires, later calls on the client reject with `Socket closed`) —
   * part of the data may already have been sent.
   *
   * 0 or not set: no limit, the write waits for as long as the peer does.
   *
   * default: 0
   * @since 8.3.0
   */
  timeout?: number;
}

export interface ReadOptions {
  client: number;
  /**
   * Upper bound for one read, in bytes.
   *
   * default: 1024
   */
  expectLen?: number;
  /**
   * timeout in seconds; 0 returns at once with whatever is already there.
   *
   * default: 10
   */
  timeout?: number;
}

export interface ReadResult {
  /**
   * Bytes received, base64-encoded (one recv: whatever the socket had, at most `expectLen`).
   *
   * Empty when nothing arrived within `timeout`, and — once — when the peer closed the
   * connection; that close also fires `disconnection`, and every later `read` on the client
   * rejects with `Socket closed`. Other I/O errors reject.
   */
  result?: string;
}

export interface DisconnectOptions {
  client: number;
}

export interface DisconnectResult {
  client: number;
}

export interface ListenOptions {
  /**
   * Port to accept connections on; 0 lets the system pick a free one, reported in
   * `ListenResult.port`.
   *
   * default: 9100
   */
  port?: number;
}

export interface ListenResult {
  /** Handle of the listening socket, for {@link TcpSocketPlugin.stopListening}. */
  server: number;
  /**
   * Port the socket is bound to: the one asked for, or the one the system picked for 0.
   *
   * @since 8.4.0
   */
  port: number;
}

export interface StopListeningOptions {
  server: number;
}

export interface ConnectionEvent {
  /** Listening socket that accepted this peer. */
  server: number;
  /** Client id, usable with `send` / `read` / `disconnect`. */
  client: number;
  /** Peer address, e.g. `192.168.1.42`. */
  address: string;
}

export interface DisconnectionEvent {
  /** Client whose peer is gone; the socket is already closed. */
  client: number;
}

export interface LocalAddressResult {
  /** IPv4 (or IPv6 if that is all there is) of the local-network interface. */
  ip?: string;
  /** Interface the address belongs to, e.g. `en0` / `wlan0`. */
  interfaceName?: string;
}
