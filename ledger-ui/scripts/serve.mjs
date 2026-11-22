#!/usr/bin/env node
// A throwaway Ledger for looking at a UI change: a scratch database with the
// schema and migrations applied, the real server on a local port serving
// frontend/build, one user, and (with --seed) a few accounts, a customer, a
// vendor and entries so pages aren't empty.
//
//   LEDGER_DIR=<checkout> node serve.mjs [--seed] [--port 8140]
//
// Needs PostgreSQL on 127.0.0.1 (postgres/postgres, or TEST_DATABASE_URL) and
// `npm ci` done in backend/ and `npm run build` in frontend/. Ctrl-C (or
// kill) stops it and drops the database. Log in as tester / correct horse battery.
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { readdir, readFile, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const repo = path.resolve(process.env.LEDGER_DIR || process.cwd());
const args = process.argv.slice(2);
const port = Number(args[args.indexOf("--port") + 1]) || 8140;
const adminURL = process.env.TEST_DATABASE_URL || "postgres://postgres:postgres@127.0.0.1:5432/postgres";
const src = (f) => path.join(repo, "backend", "src", f);
const pg = createRequire(path.join(repo, "backend", "package.json"))("pg");
const { newApp } = await import(src("app.ts"));
const { connectDB } = await import(src("db.ts"));
const { createHandler } = await import(src("http.ts"));
const { createUser, login, SESSION_COOKIE } = await import(src("auth.ts"));

const dbName = `ledger_ui_${port}`;
const admin = new pg.Client({ connectionString: adminURL });
await admin.connect();
await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
await admin.query(`CREATE DATABASE ${dbName}`);
const u = new URL(adminURL);
u.pathname = "/" + dbName;
const db = await connectDB({ databaseUrl: u.toString(), dbMaxConns: 4 });
await db.query(await readFile(path.join(repo, "db", "schema.sql"), "utf8"));
for (const f of (await readdir(path.join(repo, "db", "migrations"))).filter((n) => /^\d+.*\.sql$/.test(n)).sort()) {
	await db.query(await readFile(path.join(repo, "db", "migrations", f), "utf8"));
}
const dir = await mkdtemp(path.join(tmpdir(), "ledger-ui-"));
const app = newApp(db, { csvDir: dir, cookieSecure: "auto", webDir: path.join(repo, "frontend", "build"), databaseUrl: u.toString(), backupDir: path.join(dir, "b"), integrationsDir: path.join(dir, "i") });
await createUser(app, "tester", "correct horse battery");
const server = createServer(createHandler(app));
await new Promise((r) => server.listen(port, "127.0.0.1", r));

if (args.includes("--seed")) {
	const { token } = await login(app, "tester", "correct horse battery");
	const call = async (method, p, body) => {
		const r = await fetch(`http://127.0.0.1:${port}/api/v1${p}`, { method, headers: { "Content-Type": "application/json", Cookie: `${SESSION_COOKIE}=${token}` }, body: JSON.stringify(body) });
		if (!r.ok) throw new Error(`${method} ${p}: ${r.status} ${await r.text()}`);
		return r.json();
	};
	const acct = (code, name, type, kind = null, parent_code = null) => call("POST", "/accounts", { code, name, type, currency: "CAD", description: "", kind, parent_code });
	await acct("1000", "Chequing", "asset", "chequing");
	await acct("1200", "Accounts receivable", "asset", "receivable");
	await acct("2000", "Accounts payable", "liability", "payable");
	await acct("2100", "Visa", "liability", "credit_card");
	await acct("4000", "Sales", "revenue");
	await acct("6100", "Supplies", "expense");
	await acct("6110", "Office supplies", "expense", null, "6100");
	const acme = await call("POST", "/entities", { name: "Acme Ltd", is_customer: true });
	const hydro = await call("POST", "/entities", { name: "Hydro One", is_vendor: true });
	const post = (date, description, dr, cr, cents, entity_id = null) =>
		call("POST", "/journal-entries", { entry_date: date, description, entity_id, lines: [{ account_code: dr, debit_cents: cents, credit_cents: 0 }, { account_code: cr, debit_cents: 0, credit_cents: cents }] });
	const day = (n) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
	await post(day(20), "Invoice 101", "1200", "4000", 125000, acme.id);
	await post(day(18), "Hydro bill", "6100", "2000", 23050, hydro.id);
	await call("POST", `/entities/${acme.id}/payments`, { role: "customer", account_code: "1000", entry_date: day(10), amount_cents: 50000 });
	for (let i = 1; i <= 8; i++) await post(day(i), `Cash sale ${i}`, "1000", "4000", 1000 * i);
	await post(day(3), "Paper", "6110", "2100", 4599);
}
console.log(`ledger ui server: http://127.0.0.1:${port}  (tester / correct horse battery)`);

const stop = async () => {
	server.close();
	await app.orgs.end().catch(() => {});
	const a = new pg.Client({ connectionString: adminURL });
	await a.connect();
	await a.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`).catch(() => {});
	await a.end();
	process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
