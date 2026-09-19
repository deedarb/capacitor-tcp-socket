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
   * Subscribe to `connection` before calling `listen`. A peer that connects before the
   * first listener is attached is not lost — its event is retained and delivered to
   * that listener — but there is no reason to rely on it.
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
   * Prefers the Wi-Fi interface (`en0` on iOS, `wlan0` on Android) and IPv4. `ip` is undefined when
   * the device has no local-network address (airplane mode, cellular only).
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
}

export interface ReadOptions {
  client: number;
  /** Upper bound for one read, in bytes. */
  expectLen: number;
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
   * Port to accept connections on.
   *
   * default: 9100
   */
  port?: number;
}

export interface ListenResult {
  /** Handle of the listening socket, for {@link TcpSocketPlugin.stopListening}. */
  server: number;
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
