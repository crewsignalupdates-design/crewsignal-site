#!/usr/bin/env node
/**
 * CrewSignal internal-link preflight. Read-only, dependency-free, no network.
 * Usage: node scripts/audit-site-links.mjs [--strict] [--json] [public-directory]
 *
 * Checks href/src/action, srcset, CSS URLs/imports, meta refresh, fragment IDs,
 * empty HTML, and duplicate IDs. Models ordered _redirects rules, file shadowing,
 * forced redirects, direct 200 rewrites, and lowercase public routes for HTML
 * stored under mixed-case paths. External destinations and PDF fragments are
 * outside this local check. Conditional redirects are reported for review.
 * --strict exits 1 on confirmed errors; review findings do not fail the run.
 */
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const json = args.includes("--json");
const options = args.filter(x => x.startsWith("--"));
if (args.includes("--help")) {
  console.log("Usage: node scripts/audit-site-links.mjs [--strict] [--json] [public-directory]");
  process.exit(0);
}
const unknown = options.filter(x => !["--strict", "--json"].includes(x));
const roots = args.filter(x => !x.startsWith("--"));
if (unknown.length || roots.length > 1) {
  console.error("Unknown option or extra path. Use --help for usage.");
  process.exit(2);
}
const root = path.resolve(roots[0] || "public");
const origin = "https://crewsignal.org";
const hosts = new Set(["crewsignal.org", "www.crewsignal.org"]);
const findings = [];
const slashes = value => value.replace(/\\/g, "/");
const relative = file => slashes(path.relative(root, file));
const isHtml = file => /\.html?$/i.test(file);
const displayFile = file => slashes(path.relative(process.cwd(), path.join(root, file)));
function add(kind, detail, severity = "ERROR") {
  findings.push({ severity, kind, ...detail });
}
function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if ([".git", "node_modules", "dist"].includes(entry.name)) return [];
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? walk(file) : entry.isFile() ? [file] : [];
  });
}
if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
  console.error("Public directory not found: " + root);
  process.exit(2);
}
// Lookups use exact spellings even when the script runs on Windows.
const files = new Map(walk(root).map(file => [relative(file), file]));
const htmlFiles = [...files.keys()].filter(isHtml).sort();
const documentCache = new Map();
const namedEntities = {
  amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", nbsp: "\u00a0",
  colon: ":", sol: "/", num: "#", percnt: "%", period: ".", quest: "?",
  ndash: "–", mdash: "—", rsquo: "’", lsquo: "‘", rdquo: "”", ldquo: "“"
};
function decodeEntities(value) {
  return value.replace(/&(#x[\da-f]+|#\d+|[a-z][a-z\d]+);/gi, (all, name) => {
    if (name[0] !== "#") return namedEntities[name.toLowerCase()] ?? all;
    const number = name[1].toLowerCase() === "x" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
    return number > 0 && number <= 0x10ffff && !(number >= 0xd800 && number <= 0xdfff)
      ? String.fromCodePoint(number) : "\ufffd";
  });
}
function decodeUrl(value) {
  try { return decodeURIComponent(value); } catch { return value; }
}
function routeFor(file) {
  return "/" + (file === "index.html" ? "" : file.endsWith("/index.html") ? file.slice(0, -10) : file);
}
function diskFile(urlPath) {
  const decoded = decodeUrl(urlPath).replace(/^\/+/, "");
  if (decoded.split("/").includes("..") || decoded.includes("\0") || decoded.includes("\\")) return null;
  if (files.has(decoded)) return decoded;
  const stem = decoded.replace(/\/+$/, "");
  const index = stem ? stem + "/index.html" : "index.html";
  if (files.has(index)) return index;
  if (!path.posix.extname(stem) && files.has(stem + ".html")) return stem + ".html";
  return null;
}
function attributes(tag) {
  const result = {};
  const inside = tag.replace(/^<[\w:-]+\b/i, "").replace(/>$/, "");
  const pattern = /([^\s"'<>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
  for (const match of inside.matchAll(pattern)) {
    const name = match[1].toLowerCase();
    if (!(name in result)) result[name] = decodeEntities(match[2] ?? match[3] ?? match[4] ?? "");
  }
  return result;
}
function mask(text) { return text.replace(/[^\r\n]/g, " "); }
function lineAt(text, index) { return text.slice(0, index).split("\n").length; }
function cssReferences(text, source, offset = 0, fullText = text) {
  const safe = text.replace(/\/\*[\s\S]*?\*\//g, mask);
  const result = [];
  const patterns = [
    /url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]+))\s*\)/gi,
    /@import\s+(?:"([^"]*)"|'([^']*)')/gi
  ];
  for (const pattern of patterns) for (const match of safe.matchAll(pattern)) {
    result.push({ source, line: lineAt(fullText, offset + match.index), tag: "css", attr: "url", value: match[1] ?? match[2] ?? match[3] ?? "" });
  }
  return result;
}
function srcsetUrls(value) {
  // URLs can contain commas (notably data: URLs). Descriptors end at the next
  // comma outside parentheses; a comma at the end of a URL ends that candidate.
  const result = [];
  let cursor = 0;
  while (cursor < value.length) {
    while (/[\s,]/.test(value[cursor] || "") && cursor < value.length) cursor++;
    const start = cursor;
    while (cursor < value.length && !/\s/.test(value[cursor])) cursor++;
    let url = value.slice(start, cursor);
    const ended = url.endsWith(",");
    url = url.replace(/,+$/, "");
    if (url) result.push(url);
    if (ended) continue;
    let parentheses = 0;
    while (cursor < value.length) {
      const character = value[cursor++];
      if (character === "(") parentheses++;
      else if (character === ")") parentheses = Math.max(0, parentheses - 1);
      else if (character === "," && !parentheses) break;
    }
  }
  return result;
}
function document(file) {
  if (documentCache.has(file)) return documentCache.get(file);
  const text = fs.readFileSync(files.get(file), "utf8");
  const result = { text, ids: new Set(), idCounts: new Map(), references: [], base: new URL(routeFor(file), origin) };
  documentCache.set(file, result);
  let safe = text.replace(/<!--[\s\S]*?-->/g, mask);
  for (const match of safe.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi)) {
    const start = match.index + match[0].indexOf(">") + 1;
    result.references.push(...cssReferences(match[1], file, start, text));
  }
  // Keep opening script tags so script[src] is checked, but not JS text as HTML.
  safe = safe.replace(/(<(script|style|textarea)\b[^>]*>)([\s\S]*?)(<\/\2\s*>)/gi,
    (_, opening, name, contents, closing) => opening + mask(contents) + closing);
  safe = safe.replace(/<template\b[^>]*>[\s\S]*?<\/template\s*>/gi, mask);
  let hasBase = false;
  for (const match of safe.matchAll(/<([a-z][\w:-]*)\b(?:[^>"']|"[^"]*"|'[^']*')*>/gi)) {
    const tag = match[1].toLowerCase(), attrs = attributes(match[0]);
    const line = lineAt(text, match.index);
    if (attrs.id) {
      result.ids.add(attrs.id);
      const old = result.idCounts.get(attrs.id);
      result.idCounts.set(attrs.id, { count: (old?.count ?? 0) + 1, line: old?.line ?? line });
    }
    if (tag === "a" && attrs.name) result.ids.add(attrs.name);
    if (tag === "base" && attrs.href && !hasBase) {
      try { result.base = new URL(attrs.href, result.base); hasBase = true; }
      catch { add("invalid-base-url", { source: file, line, href: attrs.href }); }
    }
    for (const attr of ["href", "src", "xlink:href", "poster", ...(tag === "form" ? ["action"] : [])]) {
      if (attrs[attr] !== undefined) result.references.push({ source: file, line, tag, attr, value: attrs[attr], ...(tag === "base" ? { base: new URL(routeFor(file), origin) } : {}) });
    }
    if (attrs.srcset) {
      for (const value of srcsetUrls(attrs.srcset)) result.references.push({ source: file, line, tag, attr: "srcset", value });
    }
    if (attrs.style) result.references.push(...cssReferences(attrs.style, file).map(ref => ({ ...ref, line })));
    if (tag === "meta" && attrs["http-equiv"]?.toLowerCase() === "refresh") {
      const refresh = (attrs.content ?? "").match(/^\s*\d+(?:\.\d+)?\s*;\s*(?:url\s*=\s*)?(.*?)\s*$/i);
      if (refresh?.[1]) result.references.push({ source: file, line, tag, attr: "refresh", value: refresh[1].replace(/^(['"])([\s\S]*)\1$/, "$2") });
    }
  }
  return result;
}

function escapeRegex(value) { return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
function routePattern(source) {
  const names = [];
  let expression = "", cursor = 0;
  for (const match of source.matchAll(/\*|:([a-z][\w]*)/gi)) {
    // Do not mistake the protocol colon in an absolute URL for a placeholder.
    expression += escapeRegex(source.slice(cursor, match.index));
    names.push(match[1] || "splat");
    expression += match[0] === "*" ? "(.*)" : "([^/]+)";
    cursor = match.index + match[0].length;
  }
  expression += escapeRegex(source.slice(cursor));
  return { regex: new RegExp("^" + expression + "$"), names };
}
const rules = [];
if (files.has("_redirects")) {
  const source = fs.readFileSync(files.get("_redirects"), "utf8");
  source.split(/\r?\n/).forEach((line, index) => {
    const parts = line.trim().split(/\s+/);
    if (!parts[0] || parts[0].startsWith("#")) return;
    const [from, to, value = "301", ...conditions] = parts;
    if (!to || !/^\d{3}!?$/.test(value)) {
      add("invalid-redirect-rule", { source: "_redirects", line: index + 1, rule: line.trim() }); return;
    }
    if (conditions.length && !conditions[0].startsWith("#")) {
      add("conditional-redirect", { source: "_redirects", line: index + 1, rule: line.trim(), message: "Conditional rules require a separate request-specific check." }, "REVIEW"); return;
    }
    rules.push({ from, to, status: Number(value.slice(0,3)), forced: value.endsWith("!"), line: index + 1, absolute: /^https?:\/\//i.test(from), ...routePattern(from) });
  });
}
function internal(url) { return ["http:", "https:"].includes(url.protocol) && hosts.has(url.hostname); }
function resolve(start) {
  let url = new URL(start);
  const seen = new Set(), chain = [], matchedRules = [];
  for (let depth = 0; depth < 32; depth++) {
    if (!internal(url)) return { status: "external", file: null, url, chain, matchedRules };
    const key = url.origin + url.pathname + url.search;
    chain.push(url.pathname + url.search + url.hash);
    if (seen.has(key)) return { status: "redirect-loop", file: null, url, chain, matchedRules };
    seen.add(key);
    const file = diskFile(url.pathname);
    let redirect = false;
    for (const rule of rules) {
      const request = rule.absolute ? url.origin + url.pathname : url.pathname;
      const match = request.match(rule.regex);
      if (!match) continue;
      if (file && !rule.forced) return { status: "file", file, url, chain, matchedRules };
      matchedRules.push(rule.line);
      let destination = rule.to;
      rule.names.forEach((name, index) => { destination = destination.replaceAll(":" + name, match[index + 1]); });
      let next;
      try { next = new URL(destination, url); }
      catch { return { status: "invalid-redirect-target", file: null, url, chain, matchedRules }; }
      if (!destination.includes("#")) next.hash = url.hash;
      if (!destination.includes("?")) next.search = url.search;
      if (rule.status === 200) {
        chain.push(next.pathname + next.search + next.hash);
        if (!internal(next)) return { status: "external", file: null, url: next, chain, matchedRules };
        const target = diskFile(next.pathname);
        return { status: target ? "rewrite" : "missing-rewrite-target", file: target, url: next, chain, matchedRules };
      }
      if ([404, 410].includes(rule.status)) return { status: "gone-target", file: null, url: next, chain, matchedRules };
      if (![301, 302, 303, 307, 308].includes(rule.status)) return { status: "unsupported-redirect-status", file: null, url: next, chain, matchedRules };
      url = next; redirect = true; break;
    }
    if (!redirect) return { status: file ? "file" : "missing-target", file, url, chain, matchedRules };
  }
  return { status: "redirect-loop", file: null, url, chain, matchedRules };
}

let references = 0, externalReferences = 0, routeProbes = 0, cssFiles = 0;
const uniquePaths = new Set();
function checkResolution(url, context, result = resolve(url)) {
  if (result.status === "external") return result;
  const detail = { ...context, path: url.pathname, target: result.file, chain: result.chain, redirectLines: result.matchedRules };
  if (!result.file) { add(result.status, detail); return result; }
  if (/\.pdf$/i.test(decodeUrl(url.pathname)) && isHtml(result.file)) add("pdf-resolves-to-html", detail);
  if (isHtml(result.file)) {
    const fragment = decodeUrl(result.url.hash.slice(1)).split(":~:", 1)[0];
    if (fragment && fragment.toLowerCase() !== "top" && !document(result.file).ids.has(fragment)) {
      add("missing-fragment", { ...detail, fragment });
    }
  }
  return result;
}
function checkReference(ref, base) {
  const value = ref.value.trim();
  if (!value || /^(?:mailto|tel|data|javascript|about|blob):/i.test(value)) return;
  let url;
  try { url = new URL(value, base); }
  catch { add("invalid-url", { source: ref.source, line: ref.line, tag: ref.tag, attr: ref.attr, href: value }); return; }
  if (!internal(url)) { externalReferences++; return; }
  references++; uniquePaths.add(url.pathname);
  const context = { source: ref.source, line: ref.line, tag: ref.tag, attr: ref.attr, href: value };
  if (value.includes("\\")) add("backslash-in-url", context);
  checkResolution(url, context);
}
for (const file of htmlFiles) {
  const doc = document(file);
  if (!doc.text.replace(/<!--[\s\S]*?-->/g, "").trim()) add("empty-html", { source: file, line: 1 });
  for (const [id, info] of doc.idCounts) if (info.count > 1) add("duplicate-id", { source: file, line: info.line, id, count: info.count });
  for (const ref of doc.references) checkReference(ref, ref.base || doc.base);
}
for (const [file, disk] of files) if (/\.css$/i.test(file)) {
  cssFiles++;
  const base = new URL("/" + file, origin);
  for (const ref of cssReferences(fs.readFileSync(disk, "utf8"), file)) checkReference(ref, base);
}

// Probe exact aliases even if no current page happens to link to them.
const probed = new Set();
for (const rule of rules) {
  if (rule.names.length) continue;
  const url = new URL(rule.from, origin), key = url.href;
  if (probed.has(key)) continue;
  probed.add(key); routeProbes++;
  const result = resolve(url);
  // Explicit 404/410 aliases can intentionally retire a URL. Reader links to
  // them still fail above, but the retirement rule itself is not an error.
  if (result.status !== "gone-target") checkResolution(url, { source: "_redirects", line: rule.line, tag: "redirect", href: rule.from }, result);
}
for (const file of htmlFiles) {
  const route = routeFor(file), lower = route.toLowerCase();
  if (route === lower) continue;
  routeProbes++;
  const original = resolve(new URL(route, origin));
  const result = resolve(new URL(lower, origin));
  const redirectsToStoredCase = result.file === file && result.status === "file" && result.url.pathname !== lower;
  if (!result.file || (original.file && result.file !== original.file) || redirectsToStoredCase) {
    add("case-route-coverage", { source: file, line: 1, path: lower, target: result.file, expectedTarget: original.file || file, resolution: result.status, chain: result.chain, message: redirectsToStoredCase
      ? "The lowercase route redirects back to a mixed-case path; use a 200 content rewrite to keep the lowercase public URL stable."
      : "The lowercase public route does not reach the same page as its stored-case route." });
  }
}

const errors = findings.filter(x => x.severity === "ERROR").length;
const review = findings.length - errors;
const kinds = {};
for (const finding of findings) kinds[finding.kind] = (kinds[finding.kind] || 0) + 1;
const report = { root, network: false, htmlFiles: htmlFiles.length, cssFiles, references, uniquePaths: uniquePaths.size, externalReferencesSkipped: externalReferences, routeProbes, errors, review, kinds, findings };
if (json) console.log(JSON.stringify(report, null, 2));
else {
  console.log(`CrewSignal internal-link preflight: ${htmlFiles.length} HTML files, ${references} internal references, ${uniquePaths.size} unique paths, ${routeProbes} route probes, ${errors} errors, ${review} review findings.`);
  for (const finding of findings) {
    const target = finding.href || finding.path || finding.id || finding.rule || "";
    console.log(`${finding.severity} ${displayFile(finding.source)}:${finding.line ?? 1} [${finding.kind}] ${target}${finding.fragment ? " #" + finding.fragment : ""}${finding.message ? " — " + finding.message : ""}`);
  }
  if (externalReferences) console.log(`External destinations (${externalReferences} references) and PDF fragments require separate checks; no network requests were made.`);
}
if (strict && errors) process.exitCode = 1;
