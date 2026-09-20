#!/usr/bin/env node
// Every onclick="…" the page renders, taken the way a browser takes it — the attribute
// value ends at the first unescaped double quote, entities decoded — must be valid
// JavaScript. A repo path or url dropped in with raw quotes cuts the attribute short and
// the button does nothing; that happened, and this is what would have said so.
//
//   node test/ui-onclicks.js <state.json>     state as /api/state gives it
'use strict';
const fs = require('fs');
const html = fs.readFileSync(`${__dirname}/../ui/index.html`, 'utf8');
const script = html.replace(/^[\s\S]*?<script>\n/, '').replace(/<\/script>[\s\S]*$/, '');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

const els = {}; const el = (id) => (els[id] ||= { id, innerHTML: '', textContent: '', hidden: false, dataset: {}, scrollTop: 0, scrollHeight: 0, value: '' });
global.document = { getElementById: el, addEventListener: () => {}, hidden: false };
global.window = {}; global.confirm = () => false; global.alert = () => {}; global.setInterval = () => {};
global.localStorage = { getItem: () => null, setItem() {} };
global.EventSource = class { constructor() { setTimeout(() => { this.onopen(); this.onmessage({ data: JSON.stringify(state) }); }, 0); } };
new Function(script)();

setTimeout(() => {
  const all = Object.values(els).map((e) => e.innerHTML).join('\n');
  const decode = (s) => s.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  let n = 0, bad = 0;
  for (const m of all.matchAll(/onclick="([^"]*)"/g)) {
    n++;
    const code = decode(m[1]);
    try { new Function(code); } catch (e) { bad++; console.error(`bad onclick: ${code.slice(0, 120)}\n  ${e.message}`); }
  }
  // Every act(...) call must name a lever the page knows: the attribute was not cut off.
  for (const m of all.matchAll(/onclick="act\('(\w+)'/g)) if (!/^(abort|tick|stop|timer|lane|gpu|reopen|escalate|answer|claude_login|claude_code|claude_cancel)$/.test(m[1])) { bad++; console.error(`unknown lever: ${m[1]}`); }
  console.log(`${n} onclick attributes, ${bad} bad`);
  process.exit(bad ? 1 : 0);
}, 20);
