import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  root: __dirname,
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        room: resolve(__dirname, 'index.html'),
        phone: resolve(__dirname, 'phone.html'),
      },
    },
  },
  test: {
    environment: 'jsdom',
  },
})
