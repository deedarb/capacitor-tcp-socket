import type {
  ConnectOptions,
  DisconnectOptions,
  ListenOptions,
  ReadOptions,
  SendOptions,
  StopListeningOptions,
  TcpSocketError,
  TcpSocketPlugin,
} from './definitions';

/**
 * Checks the options once, here, before a call reaches iOS, Android or Electron: each of them
 * would otherwise read a malformed value its own way (a string port, a negative timeout, a
 * fractional id). Rejections carry `INVALID_ARGUMENT`; messages match the native ones where
 * those exist. The native checks stay as well, for callers that go around this wrapper.
 */

/** Largest value every platform reads as a 32-bit int (Android reads options with getInt). */
const INT_MAX = 2147483647;

/**
 * Base64 alphabet with up to two trailing `=`; the length is checked apart. Not a `(?:x{4})*`
 * group: V8 backtracks through one stack frame per group and overflows on a payload of a few
 * megabytes.
 */
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

function invalid(message: string): never {
  const error = new Error(message) as TcpSocketError;
  error.code = 'INVALID_ARGUMENT';
  throw error;
}

function isInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value);
}

/** Missing options are an empty object: the required fields then report themselves. */
function optionsOf(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null) {
    return {};
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    invalid('Options must be an object');
  }
  return value as Record<string, unknown>;
}

function idOf(value: unknown, name: 'client' | 'server'): number {
  if (value === undefined || value === null) {
    invalid(`No ${name} specified`);
  }
  if (!isInteger(value) || value < 0 || value > INT_MAX) {
    invalid(`Invalid ${name} index`);
  }
  return value;
}

function portOf(value: unknown, min: number): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (!isInteger(value) || value < min || value > 65535) {
    invalid(`Port out of range: ${String(value)}`);
  }
  return value;
}

/**
 * Whole seconds, 0 or more. Past INT_MAX it is clamped, not refused: a huge timeout is a
 * deliberate "as long as it takes", and every platform clamps it the same way anyway.
 */
function secondsOf(value: unknown, name: string): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (!isInteger(value) || value < 0) {
    invalid(`${name} must be a whole number of seconds, 0 or more`);
  }
  return Math.min(value, INT_MAX);
}

function hostOf(value: unknown): string {
  if (typeof value !== 'string' || value === '') {
    invalid('Must provide ip address to connect');
  }
  if (/[\s\0]/.test(value)) {
    invalid('Invalid ip address');
  }
  return value;
}

/**
 * Base64 every platform decodes alike: line breaks and spaces dropped and the padding restored
 * (Android took both, iOS neither, Electron only the first). Electron runs it again on its side.
 */
export function base64Of(value: unknown): string {
  if (value === undefined || value === null) {
    invalid('No data provided');
  }
  if (typeof value !== 'string') {
    invalid('Invalid base64 data');
  }
  let compact = value.replace(/\s/g, '');
  if (compact.length % 4 !== 0 && !compact.endsWith('=')) {
    compact += '='.repeat(4 - (compact.length % 4));
  }
  if (compact.length % 4 !== 0 || !BASE64.test(compact)) {
    invalid('Invalid base64 data');
  }
  return compact;
}

/** Wraps the registered plugin; methods with no options to check, and listeners, pass through. */
export function withContract(native: TcpSocketPlugin): TcpSocketPlugin {
  const checked: Partial<TcpSocketPlugin> = {
    async connect(input: ConnectOptions) {
      const options = optionsOf(input);
      return native.connect({
        ipAddress: hostOf(options.ipAddress),
        port: portOf(options.port, 1),
        timeout: secondsOf(options.timeout, 'timeout'),
      });
    },
    async send(input: SendOptions) {
      const options = optionsOf(input);
      return native.send({
        client: idOf(options.client, 'client'),
        data: base64Of(options.data),
        timeout: secondsOf(options.timeout, 'timeout'),
      });
    },
    async read(input: ReadOptions) {
      const options = optionsOf(input);
      const expectLen = options.expectLen;
      if (
        expectLen !== undefined &&
        expectLen !== null &&
        (!isInteger(expectLen) || expectLen < 1 || expectLen > INT_MAX)
      ) {
        invalid(`expectLen must be an integer from 1 to ${INT_MAX}`);
      }
      return native.read({
        client: idOf(options.client, 'client'),
        expectLen: expectLen as number,
        timeout: secondsOf(options.timeout, 'timeout'),
      });
    },
    async disconnect(input: DisconnectOptions) {
      return native.disconnect({ client: idOf(optionsOf(input).client, 'client') });
    },
    async listen(input: ListenOptions) {
      return native.listen({ port: portOf(optionsOf(input).port, 0) });
    },
    async stopListening(input: StopListeningOptions) {
      return native.stopListening({ server: idOf(optionsOf(input).server, 'server') });
    },
  };

  // A proxy, not a copy: registerPlugin's object answers any method name (addListener,
  // removeAllListeners, ones added later), and all of them must keep working.
  return new Proxy(native, {
    get(target, property) {
      if (typeof property === 'string' && Object.prototype.hasOwnProperty.call(checked, property)) {
        return checked[property as keyof TcpSocketPlugin];
      }
      return Reflect.get(target, property);
    },
  });
}
