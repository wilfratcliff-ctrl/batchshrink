#!/usr/bin/env node
/*
 * VideoShrink call-site check - a source scan, not a compiler.
 *
 * This machine has no Swift toolchain, and every Swift compile has to happen in the cloud,
 * where the minutes are rationed. Two classes of mistake have already cost a cloud build and
 * both are visible by reading the source, so they are checked here instead.
 *
 * RULE A - argument label order.
 *   Swift requires a call's labelled arguments to appear in the declaration's order. For every
 *   `func`, explicit `init`, synthesised struct memberwise initialiser and enum case in the
 *   scanned tree, the ordered parameter labels are recorded. A call is only judged when exactly
 *   one declaration of that name can accept the labels the call supplies; if none or several
 *   can, the call is skipped rather than guessed. When a supplied label exists in the resolved
 *   declaration but sits before a label the call already consumed, that is the definite compile
 *   error "argument 'x' must precede argument 'y'".
 *
 * RULE B - an optional parameter shadowing a non-Optional stored property inside `init`.
 *   Inside an init body a bare name resolves to the parameter, not the stored property, so
 *   `libraryChanges.onChange = ...` silently writes to the optional argument. Reported only when
 *   the parameter's type is Optional, a stored property of the same name is non-Optional, and
 *   the body declares no local of that name. `self.`, `.` and `??` uses are left alone.
 *
 * WHAT THIS DOES NOT COVER - do not mistake it for a compiler:
 *   - types, generics, protocol conformance, availability, access control, actor isolation,
 *     effects, and overload resolution beyond the narrow uniqueness rule above;
 *   - argument COUNT: a call that omits a required parameter, or passes too many, is silent;
 *   - anything not declared in the scanned tree (SwiftUI, Foundation, XCTest, the standard
 *     library), so a wrong label on an external API is invisible;
 *   - string interpolation contents, macros, operators, subscripts and key paths;
 *   - Rule B only fires when the parameter and the stored property share an exact name and both
 *     live in a type this scan can parse.
 *   A clean run is evidence, never proof. A finding is a very strong hint.
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

const SWIFT_KEYWORDS = new Set([
  'if', 'else', 'guard', 'while', 'repeat', 'for', 'in', 'switch', 'case', 'default', 'where',
  'return', 'break', 'continue', 'fallthrough', 'throw', 'throws', 'rethrows', 'try', 'catch',
  'defer', 'do', 'as', 'is', 'await', 'async', 'some', 'any', 'self', 'super', 'nil', 'true',
  'false', 'inout', 'let', 'var', 'func', 'init', 'deinit', 'subscript', 'typealias', 'import',
  'operator', 'precedencegroup', 'convenience', 'required', 'lazy', 'weak', 'unowned', 'static',
  'class', 'struct', 'enum', 'protocol', 'extension', 'actor', 'associatedtype', 'macro',
  'consuming', 'borrowing', 'borrow', 'consume', 'discard', 'copy',
]);

// ---------------------------------------------------------------------------------------------
// Lexing helpers. Everything below works on a copy of the source where comments and string
// literals have been replaced by spaces, so no rule can be fooled by text inside them.
// ---------------------------------------------------------------------------------------------

function endOfString(text, quoteAt, hashes) {
  const n = text.length;
  if (text.startsWith('"""', quoteAt)) {
    let j = quoteAt + 3;
    while (j < n) {
      if (text.startsWith('"""', j)) { j += 3; break; }
      if (text[j] === '\\') { j += 2; continue; }
      j++;
    }
    return Math.min(j + hashes, n);
  }
  let j = quoteAt + 1;
  while (j < n) {
    const ch = text[j];
    if (ch === '\\') { j += 2; continue; }
    if (ch === '"') { j++; break; }
    if (ch === '\n') break; // unterminated on one line: stop here, do not eat the file
    j++;
  }
  return Math.min(j + hashes, n);
}

/** Replace comments and string literals with spaces, keeping every offset and newline. */
function blankOut(text) {
  const out = text.split('');
  const n = text.length;
  const blank = (from, to) => {
    for (let k = from; k < to && k < n; k++) if (out[k] !== '\n') out[k] = ' ';
  };
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === '/' && text[i + 1] === '/') {
      let j = i;
      while (j < n && text[j] !== '\n') j++;
      blank(i, j);
      i = j;
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      let depth = 1;
      let j = i + 2;
      while (j < n && depth > 0) {
        if (text[j] === '/' && text[j + 1] === '*') { depth++; j += 2; }
        else if (text[j] === '*' && text[j + 1] === '/') { depth--; j += 2; }
        else j++;
      }
      blank(i, j);
      i = j;
      continue;
    }
    if (c === '#' || c === '"') {
      let j = i;
      let hashes = 0;
      while (text[j] === '#') { hashes++; j++; }
      if (text[j] === '"') {
        const end = endOfString(text, j, hashes);
        blank(i, end);
        i = end;
        continue;
      }
      i++;
      continue;
    }
    i++;
  }
  return out.join('');
}

/** Depth of every offset, counting ()[]{} only. A block's interior is depth + 1. */
function computeDepths(clean) {
  const depths = new Array(clean.length);
  let depth = 0;
  for (let i = 0; i < clean.length; i++) {
    const c = clean[i];
    if (c === ')' || c === ']' || c === '}') depth = Math.max(0, depth - 1);
    depths[i] = depth;
    if (c === '(' || c === '[' || c === '{') depth++;
  }
  return depths;
}

function matchBracket(text, openIndex) {
  const open = text[openIndex];
  const close = open === '(' ? ')' : open === '[' ? ']' : '}';
  let depth = 0;
  for (let i = openIndex; i < text.length; i++) {
    const c = text[i];
    if (c === open) depth++;
    else if (c === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

const isIdentChar = ch => !!ch && /[A-Za-z0-9_]/.test(ch);

function opensGeneric(text, i) {
  if (text[i] !== '<') return false;
  const prev = text[i - 1];
  const next = text[i + 1];
  if (next === '=' || next === '<') return false;
  return isIdentChar(prev) || prev === ')' || prev === ']' || prev === '>';
}

function closesGeneric(text, i) {
  if (text[i] !== '>') return false;
  const prev = text[i - 1];
  return isIdentChar(prev) || prev === '>' || prev === ']' || prev === ')';
}

/** Split on a separator that is not nested inside ()[]{}<> . */
function splitTopLevel(text, separator) {
  const parts = [];
  let depth = 0;
  let angle = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === '<' && opensGeneric(text, i)) angle++;
    else if (c === '>' && angle > 0 && closesGeneric(text, i)) angle--;
    else if (c === separator && depth === 0 && angle === 0) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

function topLevelColon(text) {
  let depth = 0;
  let angle = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === '<' && opensGeneric(text, i)) angle++;
    else if (c === '>' && angle > 0 && closesGeneric(text, i)) angle--;
    else if (c === ':' && depth === 0 && angle === 0 && text[i + 1] !== ':') return i;
  }
  return -1;
}

function topLevelEquals(text) {
  let depth = 0;
  let angle = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === '<' && opensGeneric(text, i)) angle++;
    else if (c === '>' && angle > 0 && closesGeneric(text, i)) angle--;
    else if (c === '=' && depth === 0 && angle === 0 && text[i + 1] !== '=' &&
             !/[=!<>+\-*/%&|^~]/.test(text[i - 1] ?? '')) return i;
  }
  return -1;
}

/** The '(' that opens a declaration's parameter list, skipping a generic clause before it. */
function findArgParen(text, from) {
  let angle = 0;
  const limit = Math.min(text.length, from + 400);
  for (let i = from; i < limit; i++) {
    const c = text[i];
    if (c === '<' && opensGeneric(text, i)) { angle++; continue; }
    if (c === '>' && angle > 0 && closesGeneric(text, i)) { angle--; continue; }
    if (angle === 0) {
      if (c === '(') return i;
      if (c === '{' || c === '}' || c === ';') return -1;
    }
  }
  return -1;
}

const isOptionalType = t => /\?\s*$/.test(t) || /\bOptional\s*</.test(t);
const escapeRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// ---------------------------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------------------------

function findOpenBrace(text, from) {
  const limit = Math.min(text.length, from + 400);
  let depth = 0;
  for (let i = from; i < limit; i++) {
    const c = text[i];
    if (c === '(' || c === '[') depth++;
    else if (c === ')' || c === ']') depth--;
    else if (c === '<' && opensGeneric(text, i)) depth++;
    else if (c === '>' && depth > 0 && closesGeneric(text, i)) depth--;
    else if (c === '{' && depth === 0) return i;
    else if ((c === '}' || c === ';') && depth === 0) return -1;
  }
  return -1;
}

function collectTypes(clean) {
  const types = [];
  const re = /\b(struct|class|enum|actor|extension|protocol)\s+([A-Za-z_][A-Za-z0-9_.]*)/g;
  let m;
  while ((m = re.exec(clean))) {
    const bodyStart = findOpenBrace(clean, m.index + m[0].length);
    if (bodyStart < 0) continue;
    const bodyEnd = matchBracket(clean, bodyStart);
    if (bodyEnd < 0) continue;
    types.push({
      kind: m[1],
      name: m[2].split('.').pop(),
      declStart: m.index,
      bodyStart,
      bodyEnd,
      end: bodyEnd,
    });
  }
  return types;
}

function innermostType(types, offset) {
  let best = null;
  for (const t of types) {
    if (offset > t.bodyStart && offset < t.bodyEnd) {
      if (!best || t.bodyStart > best.bodyStart) best = t;
    }
  }
  return best;
}

/** Scan one property statement, deciding stored vs computed from the first top-level token. */
function scanPropertyStatement(clean, depths, from, baseDepth) {
  for (let i = from; i < clean.length; i++) {
    const c = clean[i];
    if (depths[i] < baseDepth) return { end: i, computed: false };
    if (depths[i] !== baseDepth) continue;
    if (c === '{') return { end: i, computed: true };
    if (c === '=' && clean[i + 1] !== '=' &&
        !/[=!<>+\-*/%&|^~]/.test(clean[i - 1] ?? '')) {
      return { end: i, computed: false, hasDefault: true };
    }
    if (c === ',' || c === '}' || c === '\n') return { end: i, computed: false };
  }
  return { end: clean.length, computed: false };
}

/** Stored properties per type name, in declaration order. */
function collectProperties(clean, depths, types) {
  const byType = new Map();
  const re = /\b(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:/g;
  let m;
  while ((m = re.exec(clean))) {
    const owner = innermostType(types, m.index);
    if (!owner) continue;
    const interior = depths[owner.bodyStart] + 1;
    if (depths[m.index] !== interior) continue;
    const lineStart = clean.lastIndexOf('\n', m.index) + 1;
    if (/\b(static|class|lazy)\b/.test(clean.slice(lineStart, m.index))) continue;
    const info = scanPropertyStatement(clean, depths, m.index + m[0].length, depths[m.index]);
    if (info.computed) continue;
    const type = clean.slice(m.index + m[0].length, info.end).trim();
    if (!type) continue;
    if (!byType.has(owner.name)) byType.set(owner.name, []);
    byType.get(owner.name).push({ name: m[2], isOptional: isOptionalType(type), type });
  }
  return byType;
}

function parseParams(parensText) {
  const inner = parensText.slice(1, -1);
  const params = [];
  for (const raw of splitTopLevel(inner, ',')) {
    let p = raw.trim();
    if (!p) continue;
    while (p.startsWith('@')) {
      const sp = p.search(/\s/);
      if (sp < 0) break;
      p = p.slice(sp).trim();
    }
    const colon = topLevelColon(p);
    if (colon < 0) {
      params.push({ label: null, name: null, type: p, isOptional: false, raw: raw.trim() });
      continue;
    }
    const head = p.slice(0, colon).trim();
    const rest = p.slice(colon + 1);
    const eq = topLevelEquals(rest);
    const type = (eq < 0 ? rest : rest.slice(0, eq)).trim();
    const tokens = head.split(/\s+/).filter(Boolean);
    let label = null;
    let name = null;
    if (tokens.length === 1) {
      name = tokens[0];
      label = tokens[0] === '_' ? null : tokens[0];
    } else if (tokens.length >= 2) {
      name = tokens[tokens.length - 1];
      label = tokens[tokens.length - 2] === '_' ? null : tokens[tokens.length - 2];
    }
    params.push({ label, name, type, isOptional: isOptionalType(type), raw: raw.trim() });
  }
  return params;
}

/** The '{' that opens a body after an `init` signature, if the declaration has one. */
function findInitBody(clean, afterParen) {
  let i = afterParen;
  while (i < clean.length) {
    const c = clean[i];
    if (c === '{') return i;
    if (/\s/.test(c)) { i++; continue; }
    if (/[A-Za-z]/.test(c)) {
      let j = i;
      while (j < clean.length && /[A-Za-z]/.test(clean[j])) j++;
      const word = clean.slice(i, j);
      if (word === 'throws' || word === 'async' || word === 'rethrows') { i = j; continue; }
    }
    return -1;
  }
  return -1;
}

function collectDeclarations(clean, depths, types) {
  const decls = [];
  const typesWithExplicitInit = new Set();

  const funcRe = /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let m;
  while ((m = funcRe.exec(clean))) {
    const parenAt = findArgParen(clean, m.index + m[0].length);
    if (parenAt < 0) continue;
    const close = matchBracket(clean, parenAt);
    if (close < 0) continue;
    const params = parseParams(clean.slice(parenAt, close + 1));
    decls.push({
      name: m[1],
      labels: params.map(p => p.label),
      params,
      kind: 'func',
      index: m.index,
      typeName: innermostType(types, m.index)?.name ?? null,
    });
  }

  const initRe = /\binit\b/g;
  while ((m = initRe.exec(clean))) {
    const before = clean[m.index - 1];
    if (before === '.' || isIdentChar(before)) continue;
    let after = m.index + 4;
    while (clean[after] === '?' || clean[after] === '!') after++;
    const parenAt = findArgParen(clean, after);
    if (parenAt < 0) continue;
    const close = matchBracket(clean, parenAt);
    if (close < 0) continue;
    const owner = innermostType(types, m.index);
    if (!owner) continue;
    typesWithExplicitInit.add(owner.name);
    const params = parseParams(clean.slice(parenAt, close + 1));
    const bodyStart = findInitBody(clean, close + 1);
    const bodyEnd = bodyStart < 0 ? -1 : matchBracket(clean, bodyStart);
    decls.push({
      name: owner.name,
      labels: params.map(p => p.label),
      params,
      kind: 'init',
      index: m.index,
      typeName: owner.name,
      body: bodyStart >= 0 && bodyEnd > bodyStart ? { start: bodyStart, end: bodyEnd } : null,
    });
  }

  const properties = collectProperties(clean, depths, types);
  for (const t of types) {
    if (t.kind !== 'struct' || typesWithExplicitInit.has(t.name)) continue;
    const list = properties.get(t.name) ?? [];
    decls.push({
      name: t.name,
      labels: list.map(p => p.name),
      params: list.map(p => ({ label: p.name, name: p.name, type: p.type, isOptional: p.isOptional })),
      kind: 'memberwise',
      index: t.declStart,
      typeName: t.name,
    });
  }

  for (const t of types) {
    if (t.kind !== 'enum') continue;
    const interior = depths[t.bodyStart] + 1;
    const caseRe = /\bcase\s+/g;
    caseRe.lastIndex = t.bodyStart;
    let cm;
    while ((cm = caseRe.exec(clean))) {
      if (cm.index >= t.bodyEnd) break;
      if (depths[cm.index] !== interior) continue;
      if (innermostType(types, cm.index) !== t) continue;
      let end = cm.index + cm[0].length;
      while (end < t.bodyEnd && depths[end] === interior && clean[end] !== '\n') end++;
      for (const rawCase of splitTopLevel(clean.slice(cm.index + cm[0].length, end), ',')) {
        const ct = rawCase.trim();
        if (!ct) continue;
        const shape = /^([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(([\s\S]*)\))?\s*(?:=\s*[\s\S]*)?$/.exec(ct);
        if (!shape) continue;
        const labels = [];
        if (shape[2] !== undefined) {
          for (const v of splitTopLevel(shape[2], ',')) {
            const vt = v.trim();
            if (!vt) continue;
            const vm = /^([A-Za-z_][A-Za-z0-9_]*)\s*:/.exec(vt);
            labels.push(vm ? vm[1] : null);
          }
        }
        decls.push({ name: shape[1], labels, params: [], kind: 'case', index: cm.index, typeName: t.name });
      }
    }
  }

  return { decls, properties };
}

// ---------------------------------------------------------------------------------------------
// Call sites
// ---------------------------------------------------------------------------------------------

function collectCalls(clean) {
  const calls = [];
  const re = /\b([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\(/g;
  let m;
  while ((m = re.exec(clean))) {
    const name = m[1].split('.').pop();
    if (SWIFT_KEYWORDS.has(name)) continue;
    const before = clean[m.index - 1];
    if (before === '.' || before === '@' || before === '#') continue;
    const pre = clean.slice(Math.max(0, m.index - 24), m.index);
    if (/\b(func|case)\s*$/.test(pre)) continue;
    const parenAt = m.index + m[0].length - 1;
    const close = matchBracket(clean, parenAt);
    if (close < 0) continue;
    const labels = splitTopLevel(clean.slice(parenAt + 1, close), ',')
      .map(a => a.trim())
      .filter(a => a.length > 0)
      .map(a => {
        const am = /^([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)/.exec(a);
        return am ? am[1] : null;
      });
    calls.push({ name, labels, index: m.index, parenAt, close });
  }
  return calls;
}

/**
 * Walk the call's labels against the declaration's. Returns { ok } when the order holds,
 * { skip } when this declaration cannot be the one being called, and { ordered: false, label }
 * when a supplied label exists in the declaration but sits before one already consumed.
 */
function checkOrder(declLabels, callLabels) {
  let j = 0;
  for (const label of callLabels) {
    if (label === null) {
      let k = j;
      while (k < declLabels.length && declLabels[k] !== null) k++;
      if (k >= declLabels.length) return { ok: false, skip: true };
      j = k + 1;
      continue;
    }
    let k = j;
    while (k < declLabels.length && declLabels[k] !== label) k++;
    if (k < declLabels.length) { j = k + 1; continue; }
    const behind = declLabels.indexOf(label);
    if (behind >= 0 && behind < j) return { ok: false, ordered: false, label };
    return { ok: false, skip: true };
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------------------------
// Per-file analysis
// ---------------------------------------------------------------------------------------------

function lineAt(clean, offset) {
  let line = 1;
  for (let i = 0; i < offset && i < clean.length; i++) if (clean[i] === '\n') line++;
  return line;
}

function quoteLine(lines, offset) {
  let line = 1;
  let last = 0;
  for (let i = 0; i < offset; i++) {
    if (lines[i] === '\n') { line++; last = i + 1; }
  }
  let end = lines.indexOf('\n', last);
  if (end < 0) end = lines.length;
  return lines.slice(last, end).trim();
}

function describeDeclaration(decl) {
  const labels = decl.labels.map(l => (l === null ? '_' : `${l}:`)).join(', ');
  return `${decl.name}(${labels})${decl.typeName && decl.kind !== 'func' ? ` [${decl.kind} of ${decl.typeName}]` : ''}`;
}

function analyse(source, relPath) {
  const clean = blankOut(source);
  const depths = computeDepths(clean);
  const types = collectTypes(clean);
  const { decls, properties } = collectDeclarations(clean, depths, types);
  const calls = collectCalls(clean);

  const byName = new Map();
  for (const d of decls) {
    if (!byName.has(d.name)) byName.set(d.name, []);
    byName.get(d.name).push(d);
  }

  const findings = [];
  let judged = 0;
  let initsInspected = 0;

  // Rule A
  for (const call of calls) {
    const candidates = byName.get(call.name);
    if (!candidates) continue;
    const supplied = new Set(call.labels.filter(l => l !== null));
    const matching = candidates.filter(d => [...supplied].every(l => d.labels.includes(l)));
    if (matching.length !== 1) continue;
    const decl = matching[0];
    judged++;
    const result = checkOrder(decl.labels, call.labels);
    if (result.ok || result.skip) continue;
    findings.push({
      rule: 'A',
      path: relPath,
      line: lineAt(clean, call.index),
      quote: quoteLine(source, call.index),
      name: call.name,
      label: result.label,
      decl,
      callLabels: call.labels,
    });
  }

  // Rule B
  for (const decl of decls) {
    if (decl.kind !== 'init' || !decl.body) continue;
    const stored = (properties.get(decl.typeName) ?? []).filter(p => !p.isOptional);
    if (stored.length === 0) continue;
    initsInspected++;
    const bodyText = clean.slice(decl.body.start + 1, decl.body.end);
    for (const param of decl.params) {
      if (!param.isOptional || !param.name) continue;
      const property = stored.find(p => p.name === param.name);
      if (!property) continue;
      const shadow = new RegExp(`\\b(?:let|var|for|catch|case)\\s+${escapeRe(param.name)}\\b`);
      if (shadow.test(bodyText)) continue;
      const use = new RegExp(`(^|[^.A-Za-z0-9_])${escapeRe(param.name)}\\s*([.(=])`, 'g');
      let hit;
      while ((hit = use.exec(bodyText))) {
        const nameAt = decl.body.start + 1 + hit.index + hit[1].length;
        if (hit[2] === '=' && bodyText[hit.index + hit[0].length] === '=') continue;
        findings.push({
          rule: 'B',
          path: relPath,
          line: lineAt(clean, nameAt),
          quote: quoteLine(source, nameAt),
          name: param.name,
          paramType: param.type,
          propertyType: property.type,
          owner: decl.typeName,
        });
      }
    }
  }

  findings.sort((a, b) => a.line - b.line);
  return { findings, decls, calls, types, judged, initsInspected };
}

// ---------------------------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------------------------

function collectSwiftFiles(target) {
  const stat = statSync(target);
  if (stat.isFile()) return target.endsWith('.swift') ? [target] : [];
  const out = [];
  for (const entry of readdirSync(target, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
    const full = resolve(target, entry.name);
    if (entry.isDirectory()) out.push(...collectSwiftFiles(full));
    else if (entry.name.endsWith('.swift')) out.push(full);
  }
  return out;
}

function displayPath(file) {
  const rel = relative(repoRoot, file);
  return rel.startsWith('..') ? file.replaceAll('\\', '/') : rel.replaceAll('\\', '/');
}

const args = process.argv.slice(2).filter(a => !a.startsWith('--'));
const targets = args.length > 0 ? args : [resolve(repoRoot, 'VideoShrink'), resolve(repoRoot, 'VideoShrinkTests')];

const files = [];
for (const target of targets) {
  const resolved = resolve(process.cwd(), target);
  for (const file of collectSwiftFiles(resolved)) if (!files.includes(file)) files.push(file);
}
files.sort();

let declCount = 0;
let callCount = 0;
let judgedCount = 0;
let initCount = 0;
const findings = [];
for (const file of files) {
  const relPath = displayPath(file);
  try {
    const { findings: fileFindings, decls, calls, judged, initsInspected } =
      analyse(readFileSync(file, 'utf8'), relPath);
    declCount += decls.length;
    callCount += calls.length;
    judgedCount += judged;
    initCount += initsInspected;
    findings.push(...fileFindings);
  } catch (error) {
    console.log(`SKIP ${relPath}: could not scan (${error.message})`);
  }
}

for (const f of findings) {
  if (f.rule === 'A') {
    console.log(`FAIL ${f.path}:${f.line}: argument '${f.label}' must precede the labels written before it`);
    console.log(`     declared as  ${describeDeclaration(f.decl)}`);
    console.log(`     call labels  (${f.callLabels.map(l => l ?? '_').join(', ')})`);
  } else {
    console.log(`FAIL ${f.path}:${f.line}: bare use of optional parameter '${f.name}: ${f.paramType}' in ${f.owner}'s init`);
    console.log(`     the stored property '${f.name}: ${f.propertyType}' of the same name is not optional`);
  }
  console.log(`     ${f.quote}`);
}

const scanned = `scanned ${files.length} Swift files, ${declCount} declarations, ${callCount} call sites`;
const coverage = `coverage: ${judgedCount} calls resolved to one declaration and were order-checked; ${initCount} initialisers inspected for an optional shadow`;
if (findings.length === 0) {
  console.log(`PASS: swift call-site check; ${scanned}, 0 findings.`);
  console.log(coverage);
  console.log(`NOT CHECKED: types, generics, protocols, availability, argument counts, or any call to something not declared in these files.`);
  process.exitCode = 0;
} else {
  console.log(`FAIL: swift call-site check found ${findings.length} problem(s); ${scanned}.`);
  console.log(coverage);
  process.exitCode = 1;
}
