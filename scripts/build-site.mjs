import { cpSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = join(root, 'public');
const output = join(root, 'dist');
const measurementApproved = process.env.CREWSIGNAL_GA4_APPROVED === '1';
const consentScript = '/assets/js/analytics-consent.js';
const redirect = /<meta\b[^>]*\bhttp-equiv\s*=\s*["']?refresh\b/i;
const exclusions = new Set(['assets/analytics-frame.html', 'reports/mediation/_template/index.html']);

// Use the public lowercase URL for exact case rewrites already declared by Netlify.
const caseAliases = new Map();
for (const line of readFileSync(join(source, '_redirects'), 'utf8').split(/\r?\n/)) {
  const [from, to, status] = line.trim().split(/\s+/);
  if (status === '200' && from === from.toLowerCase() && to.toLowerCase() === from + 'index.html') {
    caseAliases.set(to.slice(1), from);
  }
}

function instrument(directory, coverage) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const filename = join(directory, entry.name);
    if (entry.isDirectory()) {
      instrument(filename, coverage);
      continue;
    }
    if (!/\.html?$/i.test(entry.name)) continue;

    const path = relative(output, filename).split(sep).join('/');
    const bytes = readFileSync(filename);
    const html = bytes.toString('utf8');
    if (!Buffer.from(html).equals(bytes)) throw new Error(`Invalid UTF-8: ${path}`);

    const reason = exclusions.has(path) ? 'support file' :
      !html.trim() ? 'empty placeholder' :
      redirect.test(html) ? 'redirect' : '';
    if (reason) {
      coverage.skipped.push({ path, reason });
      continue;
    }

    const heads = html.match(/<\/head\s*>/gi);
    if (heads?.length !== 1 || html.includes(consentScript)) {
      throw new Error(`Expected one HTML head without a consent script: ${path}`);
    }
    const route = caseAliases.get(path) ?? '/' + path.replace(/(^|\/)index\.html$/, '$1');
    const page = route
      .split('/').map(encodeURIComponent).join('/');
    const tag = `<link rel="stylesheet" href="/assets/css/analytics-consent.css"><script defer src="${consentScript}" data-page="${page}" data-measurement="${measurementApproved ? 'on' : 'off'}"></script>`;
    writeFileSync(filename, html.replace(/<\/head\s*>/i, (head) => tag + '\n' + head));
    coverage.instrumented.push(path);
  }
}

rmSync(output, { recursive: true, force: true });
cpSync(source, output, { recursive: true });
const coverage = { instrumented: [], skipped: [] };
instrument(output, coverage);
if (process.argv.includes('--coverage-json')) {
  console.log(JSON.stringify(coverage, null, 2));
} else {
  console.log(`Analytics consent: ${coverage.instrumented.length} pages instrumented, ${coverage.skipped.length} excluded.`);
}
