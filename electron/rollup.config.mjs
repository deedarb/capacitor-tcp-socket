export default {
  // tsc keeps the repo layout (the implementation type-imports ../../src/definitions).
  input: 'electron/build/electron/src/index.js',
  output: [
    {
      // The platform loads the implementation as an ES module from this path.
      file: 'electron/dist/plugin.mjs',
      format: 'es',
      sourcemap: true,
      inlineDynamicImports: true,
    },
  ],
  external: ['node:net', 'node:os'],
};
