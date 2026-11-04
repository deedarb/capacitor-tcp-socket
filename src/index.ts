import { registerPlugin } from '@capacitor/core';

import { withContract } from './contract';
import type { TcpSocketPlugin } from './definitions';

const TcpSocket = withContract(
  registerPlugin<TcpSocketPlugin>('TcpSocket', {
    web: () => import('./web').then((m) => new m.TcpSocketWeb()),
  }),
);

export * from './definitions';
export { TcpSocket };
