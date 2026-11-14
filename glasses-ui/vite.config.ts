import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The glasses runtime is a web view that loads a URL from the paired phone,
// so during development we just serve this with `vite` and iterate in Chrome.
// Later: `vite build` produces static assets that deploy to the device.
export default defineConfig({
  plugins: [react()],
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: true,
  },
});
