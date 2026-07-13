// Public surface monitor. Only genuinely-public web pages (marketing + dashboard).
// No secrets, no internal hosts, no endpoints. Writes data/live-health.json.
const { chromium } = require('playwright');
const fs = require('fs');
const CHECKS = [
  { name: 'os-dashboard', url: 'https://starfireos.pages.dev/', marker: 'STARFIRE' },
  { name: 'os-crm', url: 'https://starfireos.pages.dev/starfire-crm/index.html', marker: 'STARFIRE', optional: true },
  { name: 'opsjuice-assessment', url: 'https://opsjuice.com/ai-assessment', marker: 'assessment', optional: true },
  { name: 'bs-comply', url: 'https://comply.bettersocieties.world/', marker: 'compliance', optional: true },
];
(async () => {
  fs.mkdirSync('screens', { recursive: true });
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1280, height: 900 } });
  const results = [];
  for (const c of CHECKS) {
    const r = { name: c.name, url: c.url, ok: false, status: 0, note: '' };
    try {
      const resp = await p.goto(c.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      r.status = resp ? resp.status() : 0;
      await p.waitForTimeout(2000);
      const body = (await p.content()).toLowerCase();
      const hasMarker = c.marker ? body.includes(c.marker.toLowerCase()) : true;
      r.ok = r.status === 200 && hasMarker;
      if (!hasMarker) r.note += 'marker-missing;';
      await p.screenshot({ path: `screens/${c.name}.png`, fullPage: true });
    } catch (e) { r.note += String(e && e.message ? e.message.slice(0,100) : e); }
    if (c.optional && !r.ok) r.note += 'optional;';
    results.push(r);
    console.log(JSON.stringify(r));
  }
  await b.close();
  const out = { ts: new Date().toISOString(), all_ok: results.filter(r=>!r.note.includes('optional;')).every(r=>r.ok), checks: results };
  fs.mkdirSync('data', { recursive: true });
  fs.writeFileSync('data/live-health.json', JSON.stringify(out, null, 1));
})();
