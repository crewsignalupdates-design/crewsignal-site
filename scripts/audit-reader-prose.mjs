#!/usr/bin/env node
/**
 * CrewSignal reader-facing prose preflight.
 * Read-only; scans visible HTML text, not scripts, styles, comments or markup.
 * Run: npm run audit:reader-prose -- [--strict] [public-or-specific-path ...]
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
  { severity: "ERROR", id: "private-review", re: /\b(?:private review only|private editorial audit|not approved for publication|do not publish|internal editorial (?:note|audit|review)|internal use only|reader-facing draft for review)\b/gi },
  { severity: "ERROR", id: "workflow-in-page", re: /\b(?:editorial (?:handoff|audit|queue)|research handoff|reviewer instructions?|publication checklist|QA (?:PASS|FAIL)|FIXME|TODO:)\b/gi },
  { severity: "REVIEW", id: "process-label", re: /\b(?:publication status:|method preview|validation and version history|drafting watch items|pending research|work queue|review cutoff|research cutoff|evidence reviewed through)\b/gi },
  { severity: "REVIEW", id: "editorial-voice", re: /\b(?:we should (?:revise|publish|update|check|verify)|for internal review|proposed editorial change|needs editorial approval)\b/gi }
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
function visible(html) {
  return html
    .replace(/<(script|style|template)\b[^>]*>[\s\S]*?<\/\1>/gi, mask)
    .replace(/<!--[^]*?-->/g, mask)
    .replace(/<head\b[^>]*>[\s\S]*?<\/head>/gi, mask)
    .replace(/<[^>]*>/g, mask);
}
const issues = [];
let n = 0;
for (const file of [...new Set(roots.flatMap(getFiles))].sort()) {
  n++;
  const source = fs.readFileSync(file, "utf8");
  const text = visible(source);
  for (const rule of checks) {
    for (const match of text.matchAll(rule.re)) {
      const line = source.slice(0, match.index).split("\n").length;
      const snippet = text.slice(Math.max(0, match.index - 65), Math.min(text.length, match.index + match[0].length + 100)).replace(/\s+/g, " ").trim();
      issues.push({ severity: rule.severity, rule: rule.id, file: file.replace(/\\/g,"/"), line, match: match[0].trim(), excerpt: snippet });
    }
  }
}
const errors = issues.filter(x => x.severity === "ERROR").length;
const review = issues.filter(x => x.severity === "REVIEW").length;
if (json) {
  process.stdout.write(JSON.stringify({ scanned: n, errors, review, findings: issues }, null, 2) + "\n");
} else {
  process.stdout.write("CrewSignal reader-facing prose preflight: " + n + " HTML files, " + errors + " high-confidence flags, " + review + " editorial-review flags.\n");
  for (const item of issues) process.stdout.write(item.severity + " " + item.file + ":" + item.line + " [" + item.rule + "] " + item.match + " | " + item.excerpt + "\n");
  if (review) process.stdout.write("REVIEW findings are not automatic defects; verify context and preserve necessary contract/source qualifications.\n");
}
if (strict && errors) process.exitCode = 1;
