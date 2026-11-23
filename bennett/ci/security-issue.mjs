#!/usr/bin/env node
// One GitHub issue tracks every finding in the built image, like the JUD
// repository's "Security: dependency updates need review" queue.
//   node bennett/ci/security-issue.mjs TRIVY_JSON SCAN_OUTCOME
// Opens (or reopens) the issue when the image has findings of any severity,
// edits it in place on later runs, comments only when the set of findings
// changes, and closes it after a clean scan. A scan that did not produce a
// report never closes it. Needs GH_TOKEN (issues: write) and the standard
// GITHUB_* variables. Fixes arrive as Dependabot security PRs, upstream
// merges, the image's apk upgrade, or a change in bennett/Dockerfile.bennett.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

const [reportPath, outcome = 'unknown'] = process.argv.slice(2);
const repo = process.env.GITHUB_REPOSITORY;
const runUrl = `${process.env.GITHUB_SERVER_URL}/${repo}/actions/runs/${process.env.GITHUB_RUN_ID}`;
const label = 'image-security';
const title = 'Security: image findings need review';
const gh = (...args) => execFileSync('gh', [...args, '--repo', repo], { encoding: 'utf8' }).trim();

let report;
try {
  report = existsSync(reportPath) ? JSON.parse(readFileSync(reportPath, 'utf8')) : null;
} catch {
  report = null;
}

const order = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3, UNKNOWN: 4 };
const findings = [];
for (const result of report?.Results ?? []) {
  for (const v of result.Vulnerabilities ?? []) {
    findings.push({ severity: v.Severity, id: v.VulnerabilityID, pkg: `${v.PkgName} ${v.InstalledVersion}`,
      fixed: v.FixedVersion || 'no fix yet', where: v.PkgPath || result.Target });
  }
}
findings.sort((a, b) => (order[a.severity] ?? 9) - (order[b.severity] ?? 9) || a.id.localeCompare(b.id));
const key = findings.map(f => `${f.id}|${f.pkg}|${f.where}`).join('\n');

gh('label', 'create', label, '--color', 'D93F0B', '--description', 'Findings in the DocuSeal production image', '--force');
const existing = JSON.parse(gh('issue', 'list', '--label', label, '--state', 'all', '--limit', '1',
  '--json', 'number,state,body', '--search', `in:title "${title}"`) || '[]')[0];

if (!report) {
  // No report: keep whatever the issue says and record that this run could not check.
  if (existing) gh('issue', 'comment', String(existing.number), '--body', `The image scan did not complete (${outcome}): ${runUrl}`);
  console.log('No scan report; issue left as it was.');
  process.exit(0);
}

if (findings.length === 0) {
  if (existing?.state === 'OPEN') {
    gh('issue', 'close', String(existing.number), '--comment', `Clean image scan: ${runUrl}`);
    console.log(`Closed issue #${existing.number}`);
  }
  process.exit(0);
}

const counts = Object.keys(order).map(s => `${s} ${findings.filter(f => f.severity === s).length}`).join(' · ');
const rows = findings.slice(0, 80).map(f => `| ${f.severity} | ${f.id} | ${f.pkg} | ${f.fixed} | \`${f.where}\` |`).join('\n');
const body = `The DocuSeal production image has findings (${counts}). The nightly build refuses to publish while any is HIGH or CRITICAL.

| Severity | ID | Package | Fixed in | Where |
|---|---|---|---|---|
${rows}${findings.length > 80 ? `\n\n…and ${findings.length - 80} more in the run's trivy.json artifact.` : ''}

How to fix: merge the Dependabot security PR for the package, or take the upstream DocuSeal release that fixes it, or remove or upgrade the package in \`bennett/Dockerfile.bennett\`. Don't add exceptions to \`bennett/ci/trivyignore.yaml\` without the owner's sign-off.

Latest scan: ${runUrl}

<!-- findings
${key}
-->`;

if (!existing) {
  console.log(gh('issue', 'create', '--title', title, '--label', label, '--body', body));
} else {
  const changed = !existing.body?.includes(`<!-- findings\n${key}\n-->`);
  gh('issue', 'edit', String(existing.number), '--body', body);
  if (existing.state !== 'OPEN') gh('issue', 'reopen', String(existing.number), '--comment', `Findings are back: ${runUrl}`);
  else if (changed) gh('issue', 'comment', String(existing.number), '--body', `Findings changed (${counts}): ${runUrl}`);
  console.log(`Updated issue #${existing.number}`);
}
