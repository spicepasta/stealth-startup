# ClassicScroll

A TikTok-style feed for excerpts from classic, public-domain literature.
Swipe through hand-picked passages from books like *Frankenstein* and
*The Picture of Dorian Gray*, tuned to the "vibes" you pick.

**Live site:** https://spicepasta.github.io/stealth-startup/

## Stack
- **Frontend:** a single static `index.html` (Tailwind + Supabase JS via CDN — no build step).
- **Backend:** [Supabase](https://supabase.com) (Postgres + Auth + auto REST/RPC), free tier.
- **Ingestion (local only):** a Python pipeline pulls public-domain texts from
  Project Gutenberg and uses an LLM to pick + tag excerpts.

## How it's hosted
GitHub Pages serves `index.html` directly. Supabase is already hosted in the
cloud, and the browser talks to it with the **publishable (anon)** key, which is
safe to ship publicly. No server to run for the live site.

## Contributing
The app is just `index.html` — edit it and open it in a browser to test, or push
and let GitHub Pages redeploy. The Supabase config block is near the top of the
`<script>` section.

To run locally: open `index.html` in any browser (no server needed).
Demo login: `reader@classicscroll.app` / `classic123`.

## Security note
The ingestion pipeline and the admin dashboard server use the Supabase
**service-role secret key**, which bypasses all access control. Those files
(`pipeline.py`, `admin_server.py`, `admin.html`) are intentionally **kept out of
this repo** (see `.gitignore`) and live only on the maintainer's machine. Never
commit the secret key to a public repository.

## Database schema
`schema.sql` is the full Postgres schema (tables, row-level security policies,
and the `get_feed_for_user` ranking function). Run it in the Supabase SQL editor
to recreate the backend.
