# CrewSignal — Deploy with SPA redirects
- Vite + React app
- Netlify Functions proxy to Mailchimp (double opt-in)
- SPA redirects via `public/_redirects` and `netlify.toml`

## Deploy (GitHub method recommended)
1. Push this folder to a new GitHub repo.
2. In Netlify: Add new site → Import from Git → select repo.
3. Set env vars: MAILCHIMP_API_KEY, MAILCHIMP_DC, MAILCHIMP_LIST_ID.
4. Deploy.

## Manual build (if needed)
- npm install
- npm run build
- Upload the `dist/` folder contents to Netlify (manual deploy).
