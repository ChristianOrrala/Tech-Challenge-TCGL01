import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Dev-only convenience: proxy /api to a locally running API so `npm run
// dev` works without a CORS setup. In production the SPA is served by
// CloudFront with /api/* routed to the same origin, so no proxy applies.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': 'http://localhost:8000',
    },
  },
})
