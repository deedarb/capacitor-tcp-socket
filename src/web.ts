import { WebPlugin } from '@capacitor/core';

import type {
  ConnectResult,
  DisconnectResult,
  ListenResult,
  ReadResult,
  TcpSocketPlugin,
  LocalAddressResult,
} from './definitions';

const NO_TCP = 'TCP sockets are not available in the browser';

// Rejected with code UNIMPLEMENTED. The options are not logged: `send` would print the payload.
export class TcpSocketWeb extends WebPlugin implements TcpSocketPlugin {
  async connect(): Promise<ConnectResult> {
    throw this.unimplemented(NO_TCP);
  }
  async send(): Promise<void> {
    throw this.unimplemented(NO_TCP);
  }
  async read(): Promise<ReadResult> {
    throw this.unimplemented(NO_TCP);
  }
  async disconnect(): Promise<DisconnectResult> {
    throw this.unimplemented(NO_TCP);
  }
  // Browsers cannot accept inbound TCP connections at all — this is not a gap
  // in the web implementation, there is no API to build it on.
  async listen(): Promise<ListenResult> {
    throw this.unimplemented(NO_TCP);
  }
  async stopListening(): Promise<void> {
    throw this.unimplemented(NO_TCP);
  }

  async getLocalAddress(): Promise<LocalAddressResult> {
    // A browser cannot see its own LAN address; callers fall back to a manually entered one.
    return {};
  }
}
