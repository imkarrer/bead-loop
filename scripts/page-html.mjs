#!/usr/bin/env node
// The page is ui/index.html, a plain file you edit and a browser opens. The binary serves
// it from a BAML constant, which this writes: baml_src/ns_page/page_html.baml. A BAML
// double-quoted string keeps `${` as it is and takes \\, \" and \n, so the file goes in
// whole, nothing in it rewritten by hand.
//
//   node scripts/page-html.mjs           write it
//   node scripts/page-html.mjs --check   fail if it is not what ui/ says (the gate)
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const quote = (name, text) => {
  // eslint-disable-next-line no-control-regex
  const bad = text.match(/[\u0000-\u0008\u000b-\u001f]/);
  if (bad) throw new Error(`${name}: a control character the BAML string cannot carry (code ${bad[0].charCodeAt(0)})`);
  return `"${text.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\t/g, '\\t').replace(/\n/g, '\\n')}"`;
};
const out = `// Written by scripts/page-html.mjs from ui/index.html and ui/favicon.svg: edit those, then
// run it. The gate fails when this is not what they say.

const PAGE_HTML: string = ${quote('ui/index.html', readFileSync(join(root, 'ui/index.html'), 'utf8'))};

const FAVICON_SVG: string = ${quote('ui/favicon.svg', readFileSync(join(root, 'ui/favicon.svg'), 'utf8'))};
`;
const target = join(root, 'baml_src/ns_page/page_html.baml');
if (process.argv.includes('--check')) {
  let have = '';
  try { have = readFileSync(target, 'utf8'); } catch { /* missing: not current */ }
  if (have !== out) { console.error('baml_src/ns_page/page_html.baml is not ui/: run node scripts/page-html.mjs'); process.exit(1); }
} else writeFileSync(target, out);
