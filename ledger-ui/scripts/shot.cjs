#!/usr/bin/env node
// Screenshots of Ledger pages, logged in, from the server serve.mjs started.
//
//   node shot.cjs <outdir> <path>[@<width>] [...]      e.g.  node shot.cjs /tmp/s /accounts /journal/new@390
//   STEPS=steps.cjs node shot.cjs <outdir> /reconcile  (steps.cjs: module.exports = async (page, shot) => { await page.click('text=Hide'); await shot('hidden'); })
//
// Prints page errors and, per page, whether it scrolls sideways. BASE=http://127.0.0.1:8140 by default.
const { chromium } = require("playwright");
const path = require("node:path");

(async () => {
	const [out, ...targets] = process.argv.slice(2);
	if (!out || targets.length === 0) throw new Error("usage: node shot.cjs <outdir> <path>[@<width>] [...]");
	const base = process.env.BASE || "http://127.0.0.1:8140";
	const browser = await chromium.launch();
	const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
	const errors = [];
	page.on("pageerror", (e) => errors.push(e.message));
	await page.goto(base + "/login");
	await page.fill('input[autocomplete=username], input[name=username], input[type=text]', "tester");
	await page.fill("input[type=password]", "correct horse battery");
	await page.click("button[type=submit], button.primary");
	await page.waitForTimeout(1200);
	const steps = process.env.STEPS ? require(path.resolve(process.env.STEPS)) : null;
	for (const t of targets) {
		const [p, w] = t.split("@");
		await page.setViewportSize({ width: Number(w) || 1280, height: 800 });
		await page.goto(base + p);
		await page.waitForTimeout(700);
		const name = (p.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") || "home") + (w ? `-${w}` : "");
		const shot = async (label) => {
			const file = path.join(out, `${name}${label ? "-" + label : ""}.png`);
			await page.screenshot({ path: file });
			console.log(file);
		};
		await shot("");
		if (steps) await steps(page, shot);
		const sideways = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
		if (sideways) console.log(`  ${p}: scrolls sideways at ${w || 1280}px`);
	}
	console.log(errors.length ? "page errors: " + JSON.stringify(errors) : "no page errors");
	await browser.close();
})().catch((e) => {
	console.error(e.message);
	process.exit(1);
});
