---
name: ledger-ui
description: Make small changes to the web pages of Ledger, the self-hosted bookkeeping app (mastifdogo/Bookeeping), with as little reading as possible (layout, spacing, wording, a button or toggle, a column, colours, a page's look on a phone). Use when asked to tweak, tidy, move, hide, rename or restyle something on a Ledger page, and the change needs nothing new from the server. Not for modules' pages (use ledger-module) or anything that needs a new API field.
---

# Ledger UI tweaks

A UI tweak touches only `frontend/`. Such a release replaces just the pages
on a running server: no backup, no restart. Keep it that way: **if the
change needs a file outside `frontend/` (other than `README.md`, `docs/`,
`.claude/`, `CLAUDE.md`, `backend/test/`), it is not a UI tweak**; say so
and do it as an ordinary change instead.

The whole point of this skill is to spend few tokens. So:

- **Don't explore.** Find the one file with the map below, open only the
  part you need (`Grep` for the words on the screen, then `Read` with
  `offset`/`limit`), edit, check, look, ship.
- **Never read** `frontend/src/lib/api/schema.d.ts` (7,700 generated lines),
  `package-lock.json`, `backend/`, `api/openapi.yaml` or the docs. For an
  API type, grep the one schema name in `schema.d.ts`.
- **Don't run the backend tests.** They don't cover pages.
- **No agents, no plans, no summaries of what the file does.** One short
  sentence before the edit, the result after.

## 1. Find the file

Pages are `frontend/src/routes/<path>/+page.svelte` (data in `+page.ts`
beside it). The page's URL is its path.

| Page | File under `frontend/src/routes/` |
|---|---|
| Sidebar, windows (title bar, close, side-by-side panes), search button | `+layout.svelte` |
| Dashboard and its tiles | `+page.svelte` (tile layout: `lib/dashboard-layout.ts`) |
| Journal list / one entry / New entry | `journal/+page.svelte`, `journal/[id]/+page.svelte`, `journal/new/+page.svelte` |
| Accounts list / one account's ledger | `accounts/+page.svelte`, `accounts/[code]/+page.svelte` |
| Entities (customers, vendors) | `entities/+page.svelte` |
| Reconcile list / one reconciliation (statement beside the lines) | `reconcile/+page.svelte`, `reconcile/[id]/+page.svelte` |
| Documents | `documents/+page.svelte` |
| Reports | `reports/<name>/+page.svelte`, shared `lib/components/ReportSection.svelte` |
| Settings pages | `settings/<name>/+page.svelte`; a module's settings `settings/m/[id]/+page.svelte` |
| A module's page (just the frame around it) | `apps/[id]/+page.svelte` |

Shared pieces in `frontend/src/lib/components/`: `AccountSelect` (every
account dropdown), `ExpenseForm` and `PaymentForm` (New entry's Expense,
Pay bill, Receive payment tabs), `TagFields`, `StatementPicker`,
`NewAccountDialog`, `SearchPalette`, `ErrorNotice`, `Amount`,
`EntryTotals`, `DashboardLayoutEditor`. Helpers in `frontend/src/lib/`:
`money.ts` (`formatCents`, `parseAmount`, `naturalBalance`), `tags.ts`
(`tagLabel`, `tagKey`), `nav.ts` (sidebar entries and `ICONS`),
`panes.svelte.ts` (side-by-side windows), `rows.ts` (`openRow`),
`api/client.ts` (`api()`, `unwrap`, the type names, `kindLabel`).

Fastest way in: `Grep` the visible text (a button's label, a heading) under
`frontend/src`, `output_mode: "content"`, then read 30 lines around the hit.

## 2. House style (so you don't have to read other files to match it)

- **Svelte 5 runes**: `$state`, `$derived`, `$derived.by`, `$effect`,
  `$props`; events are attributes (`onclick={...}`); lists are keyed
  (`{#each rows as r (r.id)}`). Tabs for indentation, single quotes.
- **Global classes** (`frontend/src/app.css`, don't re-invent them): `card`,
  `toolbar` (a flex row; `<span class="spacer">` pushes right), `button`
  (a link that looks like one), `primary`, `link` (a button that looks like
  a link), `badge` (+ `ok`, `warn`, `danger`, `tag <name>`), `notice` (+
  `ok`, `warn`, `error`), `muted`, `small`, `mono`, `num` (right-aligned
  number cell), `amount` (number input), `table-wrap`, `empty`, `inline`
  (a label with its checkbox on one line), `clickable` (a row that opens).
- **Colours and sizes are variables, never literals**: `--bg`, `--surface`,
  `--text`, `--muted`, `--border`, `--accent`, `--accent-text`, `--ok`,
  `--ok-bg`, `--warn`, `--warn-bg`, `--danger`, `--danger-bg`,
  `--row-hover`, `--radius`, `--win-gap`, `--win-radius`. Dark mode comes
  from these; a literal colour breaks it.
- A page's own styles go in its `<style>` block (scoped). Only something
  used on several pages goes in `app.css`.
- **A choice the user makes about how a page looks** (hidden, expanded,
  which side, sort order) is remembered per browser: `localStorage` under a
  key like `ledger.<page>.<what>`, read and written inside `try`/`catch`
  (storage can be blocked), with a sensible default.
- Icon-only buttons get `aria-label` and `title`; a toggle gets
  `aria-pressed` or `aria-expanded`. Text hidden for screen readers
  (`sr-only`) exists only in `+layout.svelte`: elsewhere use `aria-label`.
- Money is integer cents: show with `formatCents` or `<Amount>`, read with
  `parseAmount`. Never do arithmetic on formatted text.
- Wording: plain sentences, sentence case, no jargon; say what a button
  does in its `title`.
- Phones: pages collapse under 720–900px with a `@media (max-width: …)`
  block in the page's own style. A wide table gets `table-wrap`.

## 3. Check, look, ship

```sh
cd frontend && npm run check          # must end "0 ERRORS 0 WARNINGS"
npm test                              # 6 small unit tests
```

Look at it when the change is visual (it nearly always is). Two scripts in
this skill's `scripts/` do it without writing any setup:

```sh
(pg_isready -q || service postgresql start)            # PostgreSQL, postgres/postgres
cd frontend && npm run build && cd ..
LEDGER_DIR=$PWD node <skill>/scripts/serve.mjs --seed &   # http://127.0.0.1:8140, tester / correct horse battery
node <skill>/scripts/shot.cjs <outdir> /accounts /journal/new@390
kill %1                                                # stops it and drops its scratch database
```

- `serve.mjs` runs the real server on a scratch database with a few
  accounts, a customer, a vendor and entries (`--seed`). `--port N` for
  another port (then `BASE=http://127.0.0.1:N` for `shot.cjs`).
- `shot.cjs <outdir> <path>[@width] …` logs in, screenshots each page
  (`@390` for a phone), and reports page errors and sideways scrolling.
  To click through something first, `STEPS=steps.cjs` with
  `module.exports = async (page, shot) => { await page.click('text=Hide'); await shot('hidden'); }`.
- Rebuild (`npm run build`) after each edit; the server reads the pages
  from disk, so it needn't restart.
- Read **one or two** screenshots with the Read tool, at the widths that
  matter. Don't screenshot pages you didn't touch.
- The headless browser can't render PDFs: a statement pane shows blank.
  Say so rather than claiming you saw it.
- If PostgreSQL has no password yet:
  `runuser -u postgres -- psql -qc "ALTER USER postgres PASSWORD 'postgres'"`.

Ship, following the repository's `CLAUDE.md`:

1. One line in `README.md` where the page is described, if the change is
   something a person would look for (a new toggle, a moved control).
2. Commit; push the work branch, then `main`.
3. Ask which version to tag. A release that only changes the web UI raises
   only the **last** number, whatever it adds.
4. Run the Release workflow (`release.yml` on `main` with the tag) and
   check the release published. For a UI-only release the workflow says
   "pages only: true", takes about a minute, and its `UPDATE.json` names
   the earlier release as `server`. If it names the new tag instead,
   something outside `frontend/` changed: find out what.

## When it stops being a tweak

Stop and say so, instead of working around it, when the change needs:

- a field the API doesn't return, or a new endpoint (`api/openapi.yaml`,
  `backend/`): a server change, a full release;
- something remembered per user across browsers (the server's settings);
- a module's own page: that lives in the module's repository
  (`ledger-module` skill). Only the frame around it is Ledger's.
