# ClassicScroll — Product Vision & Build Plan

> Goal: rebuild the live app's frontend to match the high-fidelity design in
> `prototype.html`, wire it to the real Supabase data ("shorts" = the extracted
> literary excerpts), and ship it as an installable, offline-capable PWA.

---

## Two artifacts, one target

| File | What it is | Role |
|---|---|---|
| `index.html` | **Current** live app — 772 lines, real Supabase auth + feed, Georgia/amber styling, 3 screens (auth, vibe picker, snap-feed). | The thing we are replacing. |
| `prototype.html` | **Target** design — a DesignSync export (914 KB: 10 embedded woff2 fonts + a gzipped React runtime). It is a *visual mock with hardcoded sample books and no backend*. | The look + IA we are building toward. |

### Important: how to actually read the prototype

`prototype.html` is **not hand-editable HTML**. The real design lives in a
JS-escaped `<x-dc>` template inside the bundle. To recover the source of truth
(inline-styled markup for every screen):

```python
# extract the design template from the DesignSync bundle
import re
html = open('prototype.html', encoding='utf-8').read()
start = html.find('<x-dc>'); end = html.find('<\\u002Fx-dc>')
chunk = html[start:end]
tpl = (chunk.replace('\\u002F','/').replace('\\n','\n')
            .replace('\\"','"').replace("\\'","'").replace('\\/','/'))
open('template.html','w').write(tpl)   # ~983 lines of real markup
```

We rebuild from `template.html` by hand. We do **not** ship the DesignSync
runtime, the React dependency, or the phone-bezel chrome (device frame, the
`9:41` status bar, the notch, the home indicator) — those are design-canvas
scaffolding, not app UI.

---

## The gap is a rebuild, not a restyle

The prototype is a much larger product than today's app. It introduces a full
onboarding flow, a 4-tab app shell, and several overlays:

| Area | Current `index.html` | Prototype |
|---|---|---|
| Onboarding | — | Welcome screen → Vibe picker → Auth |
| Auth | Email/password tab switcher | Google OAuth + email/password, login/signup toggle |
| App shell | Single feed screen | Bottom nav: **Feed · Discover · Saved · Profile** |
| Feed | One card layout | **3 switchable variants**: Immersive (A), Cover Card (B), Editorial (C) |
| Reading | Inline scroll in card | Dedicated **Reading View** (drop cap, progress bar, share toast) |
| Book detail | — | **Book Detail** overlay (hero, stats, "more like this") |
| Comments | Simple overlay | Bottom-sheet **Comments** with avatars, likes, reply |
| Profile | — | Stats, day-streak calendar, favorite vibes, recently viewed |
| Extras | — | Design System reference screen |

Treat Phase 1 as **the largest phase**, not a quick coat of paint.

---

## Design tokens (extracted from the prototype)

```
Fonts
  Display / excerpts : 'Newsreader'      (serif; weights 300–600, italic used heavily)
  UI / labels        : 'Hanken Grotesk'  (sans; weights 400–700)
  Both loaded from Google Fonts (the bundle embeds woff2; for the live app, link
  the Google Fonts CSS or self-host the two families).

Color
  Iris    #8B6FC9   primary accent / CTAs
  Lavender#B8A2E6 / #C8B4F0   highlight text ("vibes"), gradients
  Rose    #E6A2C2   like accent
  Gilt    #E6C79A   bookmark/save accent
  Ink     #0B0A0E   app background
  Surface #141218   cards / sheets
  Paper   #F4F2F7   primary text
  Muted   #A09CAB / #8C8794 / #6E6A78   secondary/tertiary text
  Stage bg: radial-gradient(#16131D → #0A0810 → #060509)

Motion (keyframes already named in the prototype)
  csFeedIn / csFeedDown  feed card swap
  csRise                 overlay rise (detail, reading, design)
  csSheet                comments sheet slide-up
  csPop                  like/bookmark tap pop
```

Per our data-quality rules, every vibe tag must be **humanized** before render:
`class-conflict → "Class Conflict"`, `coming-of-age → "Coming of Age"`. Build a
`humanizeVibe()` map keyed off the 20-item taxonomy. Never show the raw
snake-case enum.

---

## Phase 1 — Rebuild the frontend from the prototype

Re-author `index.html` (or split into modules) to reproduce every prototype
screen with the real design tokens, keeping the existing Supabase wiring intact.

**Order of work (each independently demoable):**
1. Global shell: fonts, color tokens, keyframes, screen-stack router (the
   prototype's `sc-if` blocks become show/hide screens like today's `showScreen`).
2. Onboarding: Welcome → Vibe picker (reuse current `renderVibeGrid` /
   `toggleVibe` / `saveOnboarding` logic, restyled) → Auth.
3. App shell + bottom nav (Feed / Discover / Saved / Profile).
4. Feed — start with **Variant A (Immersive)** only; add the A/B/C variant
   switcher last (it's a presentation toggle over the same data).
5. Reading View, Book Detail, Comments sheet overlays.
6. Discover + Profile tabs.

**Keep, do not rewrite:** the Supabase client init, `get_feed_for_user` RPC
call, `logInteraction`, `logView` view-tracking, `loadComments`. The data layer
already works; Phase 1 is presentation.

**File-size rule:** today's single 772-line file will balloon. Split into
`index.html` + `app.js` + `styles.css` (still no build step — plain `<script>`
/`<link>`). Keep each file under 800 lines.

---

## Phase 2 — Wire real excerpt data ("shorts") into the new UI

The prototype renders hardcoded sample books. This phase replaces every mock
with real rows from Supabase. The pipeline already extracts excerpts into the
`excerpts` table; "integrating the shorts" = binding that data to the new
components.

### 2a — Field mapping (prototype → real source)

| Prototype field | Real source | Notes |
|---|---|---|
| `excerpt` | `excerpts.body` | already wired today |
| `title` / `author` | `excerpts.book_title` / `author` | direct |
| `vibesLine`, `vibeChips` | `excerpts.vibe_tags[]` | via `humanizeVibe()` |
| `accent`, `c1`, `c2`, `initial`, cover gradients | **derived client-side** | `initial` = first letter of title; colors = deterministic hash(title) → token palette. No DB change. |
| `read` (e.g. "3 min") | **derived** | `ceil(word_count(body) / 220)` min |
| `likeDisplay`, `comDisplay`, `rating`, `pages`, `year`, `statStreak` | **no data source yet** | see 2b. Until available, **omit** — never render `0` for a missing count (data-quality rule: missing ≠ zero). |
| `similar` / "More like this" | **new query** | excerpts sharing ≥1 `vibe_tag`, excluding current. |

### 2b — Schema additions for the prototype's social/stats surfaces

These are optional but unlock the prototype's full UI. Add as nullable / new
objects (non-blocking migrations, `IF NOT EXISTS`):

- **Like & comment counts** — a `get_excerpt_stats(ids uuid[])` RPC returning
  `(excerpt_id, like_count, comment_count)` aggregated from `interactions` /
  `comments`. Batch-fetch for the visible feed (no N+1). Render `—` when a
  count is genuinely unknown, `0` only when truly zero.
- **Saved tab** — query `interactions` where `action='bookmark'` for the user,
  joined to `excerpts`. No schema change needed; the table already exists.
- **Profile stats** — `excerpts read` = count of `action='view'`; `saved` =
  count of `action='bookmark'`. **Day streak** is the only genuinely new
  concept; defer it or compute from distinct `date(created_at)` of the user's
  `view` interactions.
- **Comment likes / replies** — the prototype shows them; current `comments`
  table has neither. Defer (display without like/reply affordance) unless we
  add a `comment_likes` table and a `parent_id`.

### 2c — Discover & curated collections

The prototype's Discover tab shows "Curated collections", "Browse by vibe"
(grid of all 20 taxonomy vibes with counts), and "Trending this week".
- *Browse by vibe* and the per-vibe count: `GROUP BY` over `excerpts` unnested
  `vibe_tags`. Cache (taxonomy changes rarely → long TTL on the client).
- *Trending*: most-liked excerpts in the last 7 days (`interactions` where
  `action='like'`). New lightweight RPC.
- *Curated collections*: no data model yet. Either hand-curate a small static
  list keyed by vibe, or defer. Don't fake it with random rows.

---

## Phase 3 — Progressive Web App

Make the rebuilt app installable and offline-capable. All static files (no
build step); paths scoped to GitHub Pages' `/stealth-startup/`.

### 3a — Web App Manifest (`manifest.json`)
```json
{
  "name": "ClassicScroll",
  "short_name": "ClassicScroll",
  "description": "Discover books through vibes.",
  "start_url": "/stealth-startup/",
  "scope": "/stealth-startup/",
  "display": "standalone",
  "background_color": "#0B0A0E",
  "theme_color": "#8B6FC9",
  "icons": [
    { "src": "icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icons/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
  ]
}
```
Use the prototype's "C" mark (iris square, italic Newsreader C) as the icon.
Add iOS meta tags (`apple-mobile-web-app-capable`, status-bar-style,
`apple-touch-icon`) — Safari ignores parts of the manifest.

### 3b — Service Worker (`sw.js`)

| Request | Strategy | Why |
|---|---|---|
| App shell (HTML/JS/CSS, fonts) | Cache-first, update in background | Instant boot; fonts are large woff2 |
| Supabase REST/RPC (feed, excerpts) | Network-first, fallback to cache | Auth-gated; must not serve another user's cache |
| Google Fonts CSS/woff2 | Cache-first | Stable, immutable URLs |

Pre-cache the shell on `install`; clean old cache versions on `activate`;
register at `/stealth-startup/sw.js` with matching scope. Because there's no
build step, version the caches with a manual `const VERSION = 'v1'` constant
bumped on each deploy.

### 3c — Offline empty state
When offline with a cold cache, show a branded empty state (reuse the welcome
gradient + "C" mark), not a blank screen. Excerpts cached from the last session
should still be swipeable read-only.

---

## Explicitly out of scope (corrects the earlier draft)

- **Audio/video "shorts", TTS, video generation, Supabase Storage buckets.**
  "Shorts" here means the extracted *text* excerpts, not media clips. If we ever
  want narrated audio, it's a separate future initiative — the feed card type is
  built extensibly enough to add it later, but it is not in this plan.

---

## Open decisions to confirm before building

1. **Google OAuth** — the prototype leads with "Continue with Google". This
   requires enabling the Google provider in Supabase Auth + an OAuth client.
   Email/password already works. Ship Google now or keep email-only for v1?
2. **Feed variants A/B/C** — is the 3-way switcher a real shipped feature, or
   was it just the designer comparing options? If the latter, pick one
   (Immersive A reads as the primary) and drop the switcher.
3. **Streak / ratings / pages / year** — these have no data source. Confirm
   whether to add the schema for them or omit those UI bits for v1.

---

## Milestones

| Phase | Deliverable | Effort |
|---|---|---|
| 1 | Prototype UI rebuilt in `index.html` (+ split files), data layer preserved | Large |
| 2a | Real excerpts bound to feed/detail/reading via field mapping | Medium |
| 2b | `get_excerpt_stats` + Saved tab + profile stats | Medium |
| 2c | Discover: browse-by-vibe + trending | Medium |
| 3a | `manifest.json` + icons → installable | Small |
| 3b | `sw.js` → offline shell + caching | Medium |
| 3c | Offline empty state | Small |
