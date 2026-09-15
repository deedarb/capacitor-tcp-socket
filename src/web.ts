import { WebPlugin } from '@capacitor/core';

import type {
  ConnectOptions,
  ConnectResult,
  DisconnectOptions,
  DisconnectResult,
  ListenOptions,
  ListenResult,
  ReadOptions,
  ReadResult,
  SendOptions,
  StopListeningOptions,
  TcpSocketPlugin,
} from './definitions';

export class TcpSocketWeb extends WebPlugin implements TcpSocketPlugin {
  connect(options: ConnectOptions): Promise<ConnectResult> {
    console.log('connect', options);
    throw new Error('Method not implemented.');
  }
  send(options: SendOptions): Promise<void> {
    console.log('send', options);
    throw new Error('Method not implemented.');
  }
  read(options: ReadOptions): Promise<ReadResult> {
    console.log('read', options);
    throw new Error('Method not implemented.');
  }
  disconnect(options: DisconnectOptions): Promise<DisconnectResult> {
    console.log('disconnect', options);
    throw new Error('Method not implemented.');
  }
  // Browsers cannot accept inbound TCP connections at all — this is not a gap
  // in the web implementation, there is no API to build it on.
  listen(options: ListenOptions): Promise<ListenResult> {
    console.log('listen', options);
    throw new Error('Method not implemented.');
  }
  stopListening(options: StopListeningOptions): Promise<void> {
    console.log('stopListening', options);
    throw new Error('Method not implemented.');
  }
}
