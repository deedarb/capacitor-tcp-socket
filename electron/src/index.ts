import type { ElectronPluginContext } from '@capawesome/capacitor-electron/plugin';
import { createConnection, createServer } from 'node:net';
import type { Server, Socket } from 'node:net';
import { networkInterfaces } from 'node:os';

import type {
  ConnectOptions,
  ConnectResult,
  DisconnectOptions,
  DisconnectResult,
  ListenOptions,
  ListenResult,
  LocalAddressResult,
  ReadOptions,
  ReadResult,
  SendOptions,
  StopListeningOptions,
} from '../../src/definitions';

const DEFAULT_PORT = 9100;
const DEFAULT_TIMEOUT_SECONDS = 10;
const DEFAULT_EXPECT_LEN = 1024;
const SOCKET_CLOSED = 'Socket closed';

/**
 * Unread bytes a client may buffer before the socket is paused. The kernel
 * receive buffer then fills up and the peer is slowed down — the backpressure
 * iOS and Android get for free by reading straight off the socket.
 */
const MAX_BUFFERED_BYTES = 256 * 1024;

const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/** Virtual, tunnel and cellular interfaces: useless to peers on the LAN. */
const IGNORED_INTERFACE_PREFIX = /^(utun|awdl|llw|ppp|tun|tap|rmnet|docker|veth|br-|bridge)/i;
// `lo` / `lo0` is anchored: as a prefix it would also swallow the Windows
// adapter named `Local Area Connection`.
const IGNORED_INTERFACE_NAME =
  /^lo\d*$|virtual|vmware|virtualbox|hyper-v|bluetooth|loopback|tailscale|zerotier|vpn|wsl/i;
/** `Wi-Fi` on Windows, `wlan*` on Linux, `en0` on macOS. */
const WIFI_INTERFACE = /wi-?fi|wlan|wireless|^wl\d|airport|^en0$/i;
const ETHERNET_INTERFACE = /ethernet|^eth\d|^en\d|^lan/i;

/**
 * A pooled connection: one from `connect` or one accepted by a listening socket.
 *
 * Node hands out a stream, not a socket to recv from, so the bytes are buffered
 * here and handed out one `read` at a time — at most `expectLen` per call, the
 * same shape a single recv has on iOS and Android.
 */
class Client {
  readonly socket: Socket;

  private readonly chunks: Buffer[] = [];
  private bufferedBytes = 0;
  private paused = false;
  private waiters: (() => void)[] = [];
  /** Serialises reads: two concurrent reads would split one message between them. */
  private readTail: Promise<unknown> = Promise.resolve();

  /** The peer sent FIN, or the connection is gone: nothing follows the buffer. */
  private endOfStream = false;
  private failure?: Error;
  /** Closed by `disconnect`, or after the peer was reported gone. */
  private closed = false;
  private peerReported = false;

  constructor(socket: Socket) {
    this.socket = socket;
    socket.on('data', (chunk) => this.push(chunk));
    socket.on('end', () => this.markEndOfStream());
    // An unhandled 'error' on a socket takes the whole main process down.
    socket.on('error', (error) => this.markFailure(error));
    socket.on('close', () => this.markEndOfStream());
  }

  get isClosed(): boolean {
    return this.closed;
  }

  get isExhausted(): boolean {
    return this.bufferedBytes === 0 && this.endOfStream;
  }

  /** Runs `read` bodies one at a time, in call order. */
  runExclusive<T>(body: () => Promise<T>): Promise<T> {
    const result = this.readTail.then(body, body);
    this.readTail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  /** Up to `maxBytes` off the head of the buffer, or undefined when it is empty. */
  take(maxBytes: number): Buffer | undefined {
    if (this.bufferedBytes === 0) {
      return undefined;
    }
    const parts: Buffer[] = [];
    let taken = 0;
    while (taken < maxBytes && this.chunks.length > 0) {
      const head = this.chunks[0];
      const wanted = maxBytes - taken;
      if (head.length <= wanted) {
        parts.push(head);
        taken += head.length;
        this.chunks.shift();
      } else {
        parts.push(head.subarray(0, wanted));
        this.chunks[0] = head.subarray(wanted);
        taken = maxBytes;
      }
    }
    this.bufferedBytes -= taken;
    if (this.paused && this.bufferedBytes < MAX_BUFFERED_BYTES) {
      this.paused = false;
      this.socket.resume();
    }
    return parts.length === 1 ? parts[0] : Buffer.concat(parts, taken);
  }

  /** The pending socket error, handed out once. */
  takeFailure(): Error | undefined {
    const failure = this.failure;
    this.failure = undefined;
    return failure;
  }

  /** Resolves on the next data / end / error, or after `timeoutMs`. */
  wait(timeoutMs: number): Promise<void> {
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.waiters = this.waiters.filter((waiter) => waiter !== done);
        resolve();
      };
      const timer = setTimeout(done, timeoutMs);
      // A pending read must not keep the process alive on its own.
      timer.unref?.();
      this.waiters.push(done);
    });
  }

  /** Closes the socket without reporting a peer event — `disconnect` is a local event. */
  close(): void {
    if (!this.closed) {
      this.closed = true;
      this.socket.destroy();
      // Nothing can read these any more, and the client keeps its slot forever.
      this.chunks.length = 0;
      this.bufferedBytes = 0;
    }
    this.wake();
  }

  /** Closes the client; true the first time, so `disconnection` is fired once. */
  reportPeerGone(): boolean {
    if (this.peerReported) {
      return false;
    }
    this.peerReported = true;
    this.close();
    return true;
  }

  private push(chunk: Buffer): void {
    this.chunks.push(chunk);
    this.bufferedBytes += chunk.length;
    if (!this.paused && this.bufferedBytes >= MAX_BUFFERED_BYTES) {
      this.paused = true;
      this.socket.pause();
    }
    this.wake();
  }

  private markEndOfStream(): void {
    this.endOfStream = true;
    this.wake();
  }

  private markFailure(error: Error): void {
    this.failure ??= error;
    this.endOfStream = true;
    this.wake();
  }

  private wake(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const waiter of waiters) {
      waiter();
    }
  }
}

/**
 * TCP sockets for the Electron platform.
 *
 * Client ids are indexes into `clients`, server ids indexes into `servers`: a
 * closed entry keeps its slot so ids stay stable, exactly as on iOS and Android.
 */
class TcpSocketElectron {
  static readonly __capacitorElectronPlugin = {
    name: 'TcpSocket',
    methods: ['connect', 'send', 'read', 'disconnect', 'listen', 'stopListening', 'getLocalAddress'],
  };

  private readonly context: ElectronPluginContext;
  private readonly clients: Client[] = [];
  private readonly servers: (Server | undefined)[] = [];

  constructor(context: ElectronPluginContext) {
    this.context = context;
  }

  async connect(options: ConnectOptions): Promise<ConnectResult> {
    const ipAddress = options?.ipAddress;
    if (!ipAddress) {
      throw new Error('Must provide ip address to connect');
    }
    const port = options.port ?? DEFAULT_PORT;
    // 0 means no timeout, as on Android.
    const timeoutMs = Math.max(0, options.timeout ?? DEFAULT_TIMEOUT_SECONDS) * 1000;

    const socket = await new Promise<Socket>((resolve, reject) => {
      const pending = createConnection({ host: ipAddress, port });
      const onTimeout = () => {
        cleanUp();
        pending.destroy();
        reject(new Error(`Connection to ${ipAddress}:${port} timed out after ${timeoutMs}ms`));
      };
      const onError = (error: Error) => {
        cleanUp();
        pending.destroy();
        reject(error);
      };
      const cleanUp = () => {
        // setTimeout() is an idle timer: armed before the connection is up it
        // times out the connect, but left armed it would kill an idle socket.
        pending.setTimeout(0);
        pending.removeListener('timeout', onTimeout);
        pending.removeListener('error', onError);
      };
      pending.setTimeout(timeoutMs);
      pending.once('timeout', onTimeout);
      pending.once('error', onError);
      pending.once('connect', () => {
        cleanUp();
        resolve(pending);
      });
    });

    return { client: this.addClient(socket) };
  }

  async send(options: SendOptions): Promise<void> {
    const { index, client } = this.openClient(options?.client);
    const data = decodeBase64(options?.data);

    await new Promise<void>((resolve, reject) => {
      client.socket.write(data, (error) => {
        if (!error) {
          resolve();
        } else if (client.isClosed) {
          reject(new Error(SOCKET_CLOSED));
        } else {
          // Broken pipe / connection reset: the peer is gone.
          this.peerGone(index, client);
          reject(error);
        }
      });
    });
  }

  async read(options: ReadOptions): Promise<ReadResult> {
    const { index, client } = this.openClient(options?.client);
    const expectLen = Math.max(1, options?.expectLen ?? DEFAULT_EXPECT_LEN);
    // 0 = only what is already there.
    const timeoutMs = Math.max(0, options?.timeout ?? DEFAULT_TIMEOUT_SECONDS) * 1000;

    return client.runExclusive(async () => {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        if (client.isClosed) {
          // disconnect() closed it while this read was queued or waiting.
          throw new Error(SOCKET_CLOSED);
        }
        // Buffered bytes first: what already arrived is owed to the caller even
        // when the peer has since closed the connection.
        const chunk = client.take(expectLen);
        if (chunk) {
          // Raw bytes as base64: the caller decides how to decode them.
          return { result: chunk.toString('base64') };
        }
        const failure = client.takeFailure();
        if (failure) {
          // Connection reset and the like: the peer is gone.
          this.peerGone(index, client);
          throw failure;
        }
        if (client.isExhausted) {
          // End of stream: the peer closed. Report it once; further reads are rejected.
          this.peerGone(index, client);
          return { result: '' };
        }
        const remaining = deadline - Date.now();
        if (remaining <= 0) {
          // Peer connected and went silent: not an error for the caller, just nothing to read.
          return { result: '' };
        }
        await client.wait(remaining);
      }
    });
  }

  async disconnect(options: DisconnectOptions): Promise<DisconnectResult> {
    const { index, client } = this.client(options?.client);
    // Idempotent: closing a closed socket is a no-op. A read waiting on this
    // socket gets "Socket closed" from its own turn.
    client.close();
    return { client: index };
  }

  async listen(options: ListenOptions): Promise<ListenResult> {
    const port = options?.port ?? DEFAULT_PORT;
    const server = createServer();
    const serverIndex = this.servers.push(server) - 1;

    // Attached before listen(): a peer that connects the instant the socket is
    // bound would otherwise find no handler and be dropped.
    server.on('connection', (socket) => {
      this.context.notifyListeners('connection', {
        server: serverIndex,
        client: this.addClient(socket),
        address: normalizeAddress(socket.remoteAddress),
      });
    });

    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => {
        // The slot of a server that never bound is freed: `stopListening` on
        // its id must report an invalid server, not a silent success.
        this.servers[serverIndex] = undefined;
        server.close();
        reject(error);
      };
      server.once('error', onError);
      try {
        server.listen(port, () => {
          server.removeListener('error', onError);
          // From here on an error on the listening socket (and the one close()
          // reports when the server is already down) has nowhere to go — but
          // unhandled it would take the main process with it.
          server.on('error', () => undefined);
          resolve();
        });
      } catch (error) {
        // A port outside 0..65535 throws here instead of emitting 'error'.
        onError(error as Error);
      }
    });

    return { server: serverIndex };
  }

  async stopListening(options: StopListeningOptions): Promise<void> {
    const serverIndex = options?.server ?? -1;
    if (serverIndex === -1) {
      throw new Error('No server specified');
    }
    const server = this.servers[serverIndex];
    if (!server) {
      throw new Error('Invalid server index');
    }
    // Stops accepting at once; clients already accepted stay open, so the
    // callback (fired once they are all gone) is not waited for. The server
    // keeps its slot and closing a closed server is a no-op, so a second
    // stopListening resolves, as on iOS and Android.
    server.close();
  }

  async getLocalAddress(): Promise<LocalAddressResult> {
    let best: { score: number; ip: string; name: string } | undefined;

    for (const [name, addresses] of Object.entries(networkInterfaces())) {
      if (!addresses || IGNORED_INTERFACE_PREFIX.test(name) || IGNORED_INTERFACE_NAME.test(name)) {
        continue;
      }
      for (const address of addresses) {
        if (address.internal) {
          continue;
        }
        // Node 18 reports the family as a string, older ones as a number.
        const isV4 = address.family === 'IPv4' || (address.family as unknown) === 4;
        const ip = address.address.split('%')[0];
        if (isLinkLocal(ip)) {
          continue;
        }
        const score = (WIFI_INTERFACE.test(name) ? 4 : 0) + (isV4 ? 2 : 0) + (ETHERNET_INTERFACE.test(name) ? 1 : 0);
        if (!best || score > best.score) {
          best = { score, ip, name };
        }
      }
    }

    return best ? { ip: best.ip, interfaceName: best.name } : {};
  }

  private addClient(socket: Socket): number {
    return this.clients.push(new Client(socket)) - 1;
  }

  private client(clientIndex: number | undefined): { index: number; client: Client } {
    const index = clientIndex ?? -1;
    if (index === -1) {
      throw new Error('No client specified');
    }
    const client = this.clients[index];
    if (!client) {
      throw new Error('Invalid client index');
    }
    return { index, client };
  }

  private openClient(clientIndex: number | undefined): { index: number; client: Client } {
    const { index, client } = this.client(clientIndex);
    if (client.isClosed) {
      throw new Error(SOCKET_CLOSED);
    }
    return { index, client };
  }

  /**
   * Closes the client and tells the web layer the peer is gone — once: only the
   * close that actually closes the socket emits the event, and a local
   * `disconnect` is not a peer event.
   */
  private peerGone(index: number, client: Client): void {
    if (client.reportPeerGone()) {
      this.context.notifyListeners('disconnection', { client: index });
    }
  }
}

function decodeBase64(data: string | undefined): Buffer {
  if (data === undefined || data === null) {
    throw new Error('No data provided');
  }
  const compact = data.replace(/\s/g, '');
  if (!BASE64.test(compact)) {
    throw new Error('Invalid base64 data');
  }
  return Buffer.from(compact, 'base64');
}

/** `::ffff:192.168.1.42` from a dual-stack listener is the peer's IPv4 address. */
function normalizeAddress(address: string | undefined): string {
  if (!address) {
    return '';
  }
  const withoutZone = address.split('%')[0];
  return withoutZone.startsWith('::ffff:') ? withoutZone.slice('::ffff:'.length) : withoutZone;
}

function isLinkLocal(ip: string): boolean {
  return ip.startsWith('169.254.') || ip.toLowerCase().startsWith('fe80');
}

export { TcpSocketElectron };
