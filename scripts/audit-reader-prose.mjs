#!/usr/bin/env node
/**
 * CrewSignal reader-facing prose preflight.
 * Read-only; scans visible HTML text, browser titles, metadata and accessible labels.
 * Scripts, styles, templates, comments, URLs and markup are excluded.
 * Run: npm run audit:reader-prose -- [--strict] [--json] [public-or-specific-path ...]
 * ERROR is a narrow, high-confidence internal-note signal; REVIEW requires
 * a human decision because source limitations and historical dates are often
 * essential reader information. No source text is automatically rewritten.
 */
import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const strict = argv.includes("--strict");
const json = argv.includes("--json");
const roots = argv.filter(x => !x.startsWith("--"));
if (!roots.length) roots.push("public");

const checks = [
  { severity: "ERROR", id: "private-review", re: /\b(?:private review only|private editorial audit|private draft|not approved for publication|do not publish|internal editorial (?:note|audit|review)|internal use only|reader-facing draft for review)\b/gi },
  { severity: "ERROR", id: "workflow-in-page", re: /\b(?:editorial (?:handoff|audit|queue)|research handoff|reviewer instructions?|publication checklist|QA (?:PASS|FAIL)|FIXME|TODO:)\b/gi },
  { severity: "ERROR", id: "production-instruction", re: /\b(?:CrewSignal should|the right editorial move|the (?:correct|proper) (?:(?:reader-facing|weekly|public) )?fram(?:e|ing)|placeholder consistency (?:week|file)|(?:page|file|tracker|report) should stay (?:live|active|narrow)|reader-facing (?:framing|shorthand|explanation)|proposed method|next review triggers|fresh publisher-byte identity|in this pass|release checks|the page should be blunt|the next report should begin|report should end|should be developed there|next CrewSignal marker should)\b/gi },
  { severity: "REVIEW", id: "process-label", re: /\b(?:publication status:|method preview|validation and version history|drafting watch items|pending research|work queue|review cutoff|research cutoff|evidence cutoff|evidence reviewed through|source-status ledger|proposed criteria|forthcoming analysis)\b/gi },
  { severity: "REVIEW", id: "editorial-direction", re: /\b(?:do not invent|must not be described as|must be acknowledged rather than|should therefore be evaluated)\b/gi },
  { severity: "REVIEW", id: "editorial-voice", re: /\b(?:we should (?:revise|publish|update|check|verify)|for internal review|proposed editorial change|needs editorial approval|(?:being finalized|will be added) (?:line-by-line|after (?:separate )?verification))\b/gi }
];

function getFiles(target) {
  if (!fs.existsSync(target)) throw new Error("Missing path: " + target);
  const stat = fs.statSync(target);
  if (stat.isFile()) return target.endsWith(".html") ? [target] : [];
  return fs.readdirSync(target, { withFileTypes: true }).flatMap(ent => {
    if (ent.name === "node_modules" || ent.name === "dist" || ent.name === ".git") return [];
    return getFiles(path.join(target, ent.name));
  });
}
function mask(match) { return match.replace(/[^\r\n]/g, " "); }
function fields(html) {
  const safe = html
    .replace(/<(script|style|template)\b[^>]*>[\s\S]*?<\/\1>/gi, mask)
    .replace(/<!--[^]*?-->/g, mask);
  // Retain <title> text. Metadata is also reader-facing in previews and search results.
  const result = [{ area: "text/title", text: safe.replace(/<[^>]*>/g, mask), offset: 0 }];
  for (const tag of safe.matchAll(/<([a-z][\w:-]*)\b[^>]*>/gi)) {
    for (const attr of tag[0].matchAll(/\b(alt|title|aria-label|content)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)) {
      if (attr[1].toLowerCase() === "content" && tag[1].toLowerCase() !== "meta") continue;
      const value = attr[2] ?? attr[3] ?? attr[4] ?? "";
      const valueIndex = attr.index + attr[0].indexOf(value, attr[0].indexOf("=") + 1);
      result.push({ area: `${tag[1].toLowerCase()}[${attr[1].toLowerCase()}]`, text: value, offset: tag.index + valueIndex });
    }
  }
  return result;
}
function normalize(field) {
  const named = { nbsp: " ", amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", ndash: "–", mdash: "—", rsquo: "’", lsquo: "‘" };
  const characters = [];
  const positions = [];
  let lastSpace = false;
  for (let i = 0; i < field.text.length;) {
    let value = field.text[i], length = 1;
    if (value === "&") {
      const entity = field.text.slice(i).match(/^&(#x[\da-f]+|#\d+|[a-z]+);/i);
      if (entity) {
        const key = entity[1];
        let decoded = named[key.toLowerCase()];
        if (key[0] === "#") {
          const code = key[1].toLowerCase() === "x" ? parseInt(key.slice(2), 16) : parseInt(key.slice(1), 10);
          if (Number.isInteger(code) && code > 0 && code <= 0x10ffff) decoded = String.fromCodePoint(code);
        }
        if (decoded !== undefined) { value = decoded; length = entity[0].length; }
      }
    }
    if (/^\s+$/.test(value)) value = " ";
    if (!(value === " " && lastSpace)) {
      characters.push(value);
      for (let j = 0; j < value.length; j++) positions.push(field.offset + i);
    }
    lastSpace = value === " ";
    i += length;
  }
  return { text: characters.join(""), positions };
}
const issues = [];
let n = 0;
for (const file of [...new Set(roots.flatMap(getFiles))].sort()) {
  n++;
  const source = fs.readFileSync(file, "utf8");
  for (const field of fields(source)) {
    const projected = normalize(field);
    for (const rule of checks) {
      for (const match of projected.text.matchAll(rule.re)) {
        const index = projected.positions[match.index];
        const line = source.slice(0, index).split("\n").length;
        const excerpt = projected.text.slice(Math.max(0, match.index - 65), Math.min(projected.text.length, match.index + match[0].length + 100)).trim();
        issues.push({ severity: rule.severity, rule: rule.id, file: file.replace(/\\/g,"/"), line, area: field.area, match: match[0].trim(), excerpt });
      }
    }
  }
}
const errors = issues.filter(x => x.severity === "ERROR").length;
const review = issues.filter(x => x.severity === "REVIEW").length;
if (json) {
  process.stdout.write(JSON.stringify({ scanned: n, errors, review, findings: issues }, null, 2) + "\n");
} else {
  process.stdout.write("CrewSignal reader-facing prose preflight: " + n + " HTML files, " + errors + " high-confidence flags, " + review + " editorial-review flags.\n");
  for (const item of issues) process.stdout.write(item.severity + " " + item.file + ":" + item.line + " [" + item.rule + "; " + item.area + "] " + item.match + " | " + item.excerpt + "\n");
  if (review) process.stdout.write("REVIEW findings are not automatic defects; verify context and preserve necessary contract/source qualifications.\n");
}
if (strict && errors) process.exitCode = 1;
