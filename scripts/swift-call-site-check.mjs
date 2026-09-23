#!/usr/bin/env node
/*
 * VideoShrink call-site check - a source scan, not a compiler.
 *
 * This machine has no Swift toolchain, and every Swift compile has to happen in the cloud,
 * where the minutes are rationed. Every mechanical mistake this project has actually made is
 * visible by reading the source, so the four classes below are checked here instead.
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
 * RULE C - a conformer missing a protocol requirement.
 *   A protocol change that leaves a conformer in another file alone is a hard compile error in
 *   the test target, and it has happened three rounds running. For every protocol declared in
 *   the scanned tree the requirement names, their argument labels and their property names are
 *   recorded; for every type or extension in that tree declaring conformance to one of them,
 *   each requirement is looked for as a member of that type, in its own declaration or any
 *   extension of it. A member is matched by name, and for a function also by its argument
 *   labels; a no-argument function requirement is also accepted from a property of that name,
 *   because Swift allows it. Everything this scan cannot read confidently is skipped rather
 *   than guessed: a protocol with an `associatedtype`, a `where` clause or an inheritance list
 *   this scan cannot resolve; an `init`, `subscript`, generic or `where`-constrained
 *   requirement; a requirement a protocol extension provides a default for; a conformer
 *   whose conformance is declared in a `where` clause, or whose members may be inherited from
 *   another type declared in this tree. A skipped conformer is counted, never reported, and a
 *   conformer with no members at all is reported rather than skipped.
 *
 * RULE D - the same declaration twice.
 *   Copy-paste duplication has cost an audit before. Two members of one type are reported when
 *   they have the same name, the same static-ness, the same shape and the same
 *   conditional-compilation branch: for functions the same argument labels and the same
 *   parameter types, for properties the same type. Two top-level declarations of one name in
 *   the same scanned target directory are reported when neither is `private`/`fileprivate` and
 *   both are types, or when they are functions or properties of identical shape. A pair in
 *   different `#if` branches is never compared.
 *
 * WHAT THIS DOES NOT COVER - do not mistake it for a compiler:
 *   - types, generics, availability, access control, actor isolation, effects, and overload
 *     resolution beyond the narrow uniqueness rules above;
 *   - argument COUNT: a call that omits a required parameter, or passes too many, is silent;
 *   - anything not declared in the scanned tree (SwiftUI, Foundation, XCTest, the standard
 *     library), so a wrong label on an external API is invisible;
 *   - string interpolation contents, macros, operators, subscripts and key paths;
 *   - Rule B only fires when the parameter and the stored property share an exact name and both
 *     live in a type this scan can parse.
 *   - Rule C checks only protocols declared in these files, and only member NAMES with argument
 *     labels: a requirement met by a member of the right name but the wrong type, the wrong
 *     static-ness, a read-only property where `{ get set }` was required, or a different return
 *     type is a miss. It says nothing about protocol inheritances it cannot see, associated
 *     types, `init`, subscripts, operators, `mutating`/`nonmutating` or generic requirements,
 *     and nothing about whether a conforming member's body is correct.
 *   - Rule D compares shapes, not types: two same-named functions that differ only in a
 *     parameter type are legal overloads and are left alone, as is a declaration inside `#if`
 *     compared with one outside it, so a genuine duplicate of that shape is a miss. Two
 *     top-level type names in DIFFERENT scanned target directories are assumed to live in
 *     different modules and are left alone.
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
  const unparsed = [];
  const re = /\b(struct|class|enum|actor|extension|protocol)\s+([A-Za-z_][A-Za-z0-9_.]*)/g;
  let m;
  while ((m = re.exec(clean))) {
    const name = m[2].split('.').pop();
    if (SWIFT_KEYWORDS.has(name)) continue; // `class func`, `class var`: a modifier, not a type
    const nameEnd = m.index + m[0].length;
    const bodyStart = findOpenBrace(clean, nameEnd);
    if (bodyStart < 0) { unparsed.push({ kind: m[1], name, index: m.index }); continue; }
    const bodyEnd = matchBracket(clean, bodyStart);
    if (bodyEnd < 0) { unparsed.push({ kind: m[1], name, index: m.index }); continue; }
    const parent = innermostType(types, m.index);
    types.push({
      kind: m[1],
      name,
      declStart: m.index,
      nameEnd,
      bodyStart,
      bodyEnd,
      end: bodyEnd,
      parentName: parent ? parent.name : null,
    });
  }
  return { types, unparsed };
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
// Rule C / Rule D facts: protocol requirements, type members, declared conformances
// ---------------------------------------------------------------------------------------------

/** The start of the statement an offset sits in, so `static`/`private` can be read off it. */
function statementStart(clean, offset) {
  for (let i = offset - 1; i >= 0; i--) {
    const c = clean[i];
    if (c === '\n' || c === '{' || c === '}' || c === ';') return i + 1;
  }
  return 0;
}

const normaliseTypeText = t => t.replace(/\s+/g, ' ').trim();

const typeKey = t => (t.parentName ? `${t.parentName}.${t.name}` : t.name);

/**
 * The conditional-compilation branch every offset sits in, as a path like "2:1/3:0". Two
 * declarations are only compared when their paths are equal, so an `#if`/`#else` pair of
 * alternatives is never mistaken for a duplicate and a declaration inside `#if` is never
 * compared with one outside it.
 */
function computeConditionalPaths(clean) {
  const paths = new Array(clean.length).fill('');
  const stack = [];
  let groups = 0;
  let lineStart = 0;
  for (let i = 0; i <= clean.length; i++) {
    if (i !== clean.length && clean[i] !== '\n') continue;
    const text = clean.slice(lineStart, i).trim();
    const directive = /^#(if|elseif|else|endif)\b/.exec(text);
    if (directive) {
      const kind = directive[1];
      if (kind === 'endif') {
        stack.pop();
      } else if (kind === 'if') {
        groups++;
        stack.push({ group: groups, branch: 0 });
      } else if (stack.length > 0) {
        stack[stack.length - 1].branch++;
      }
    }
    const path = stack.map(frame => `${frame.group}:${frame.branch}`).join('/');
    for (let k = lineStart; k < i; k++) paths[k] = path;
    lineStart = i + 1;
  }
  return paths;
}

/** The first occurrence of a whole word outside brackets and generics. */
function topLevelKeywordIndex(text, word) {
  let depth = 0;
  let angle = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === '<' && opensGeneric(text, i)) angle++;
    else if (c === '>' && angle > 0 && closesGeneric(text, i)) angle--;
    else if (depth === 0 && angle === 0 && text.startsWith(word, i) &&
             !isIdentChar(text[i - 1]) && !isIdentChar(text[i + word.length])) return i;
  }
  return -1;
}

/** One entry of a conformance list, or null when it is not a plain protocol name. */
function conformanceName(raw) {
  const s = raw.trim().replace(/\s+/g, ' ').replace(/^any\s+/, '');
  if (!/^[A-Za-z_][A-Za-z0-9_.]*$/.test(s)) return null;
  return s.split('.').pop();
}

/** How much of a type header to drop to get past a leading generic clause, or -1 if unreadable. */
function skipGenericClause(text) {
  if (text[0] !== '<') return 0;
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '<') depth++;
    else if (text[i] === '>') {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

/** The plain protocol names a type declaration lists after its colon. */
function parseConformances(clean, type) {
  const raw = clean.slice(type.nameEnd, type.bodyStart);
  const skip = skipGenericClause(raw);
  if (skip < 0) return { names: [], unreadable: false };
  const header = raw.slice(skip);
  const colon = topLevelColon(header);
  if (colon < 0) return { names: [], unreadable: false };
  const tail = header.slice(colon + 1);
  if (topLevelKeywordIndex(tail, 'where') >= 0) return { names: [], unreadable: true };
  const names = [];
  for (const entry of splitTopLevel(tail, ',')) {
    const name = conformanceName(entry);
    if (name) names.push(name);
  }
  return { names, unreadable: false };
}

/** The type text after a `:` on a property, stopping at its body or default value. */
function scanPropertyType(clean, depths, from, baseDepth) {
  let i = from;
  while (i < clean.length && /\s/.test(clean[i])) i++;
  if (clean[i] !== ':') return { type: '', hasType: false, end: i };
  i++;
  const start = i;
  const startDepth = depths[i] ?? baseDepth;
  while (i < clean.length) {
    const c = clean[i];
    if (depths[i] < startDepth) break;
    if (depths[i] === startDepth) {
      if (c === '{' || c === '\n' || c === ',' || c === '}' || c === ';') break;
      if (c === '=' && clean[i + 1] !== '=' &&
          !/[=!<>+\-*/%&|^~]/.test(clean[i - 1] ?? '')) break;
    }
    i++;
  }
  const type = normaliseTypeText(clean.slice(start, i));
  return { type, hasType: type.length > 0, end: i };
}

// ---------------------------------------------------------------------------------------------
// Members and file-scope declarations
// ---------------------------------------------------------------------------------------------

/** Members declared directly in a type body, keyed to that type. */
function collectMembers(clean, depths, conditions, types) {
  const members = [];
  const ownerOf = offset => {
    const t = innermostType(types, offset);
    if (!t || t.kind === 'protocol') return null;
    if (depths[offset] !== depths[t.bodyStart] + 1) return null;
    return t;
  };
  const isStatic = offset =>
    /\b(static|class)\b/.test(clean.slice(statementStart(clean, offset), offset));

  const funcRe = /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let m;
  while ((m = funcRe.exec(clean))) {
    const owner = ownerOf(m.index);
    if (!owner) continue;
    const parenAt = findArgParen(clean, m.index + m[0].length);
    if (parenAt < 0) continue;
    const close = matchBracket(clean, parenAt);
    if (close < 0) continue;
    const params = parseParams(clean.slice(parenAt, close + 1));
    members.push({
      key: typeKey(owner), ownerKind: owner.kind, kind: 'func', name: m[1],
      labels: params.map(p => p.label),
      paramTypes: params.map(p => normaliseTypeText(p.type)),
      confident: params.every(p => p.label !== null || p.name !== null),
      typeText: '', isStatic: isStatic(m.index), condition: conditions[m.index],
      line: lineAt(clean, m.index), index: m.index,
    });
  }

  const propRe = /\b(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  while ((m = propRe.exec(clean))) {
    const owner = ownerOf(m.index);
    if (!owner) continue;
    // A `case let .value(x)` pattern inside an enum is a case, not a member.
    if (/^\s*case\b/.test(clean.slice(statementStart(clean, m.index), m.index))) continue;
    const info = scanPropertyType(clean, depths, m.index + m[0].length, depths[m.index]);
    members.push({
      key: typeKey(owner), ownerKind: owner.kind, kind: 'prop', name: m[2],
      labels: [], paramTypes: [], confident: info.hasType, typeText: info.type,
      keyword: m[1], isStatic: isStatic(m.index), condition: conditions[m.index],
      line: lineAt(clean, m.index), index: m.index,
    });
  }
  return members;
}

/** File-scope declarations, so Rule D can look for a top-level name declared twice. */
function collectFileDeclarations(clean, depths, conditions, types) {
  const out = [];
  const isStatic = offset =>
    /\b(static|class)\b/.test(clean.slice(statementStart(clean, offset), offset));
  const isFilePrivate = offset =>
    /\b(private|fileprivate)\b/.test(clean.slice(statementStart(clean, offset), offset));

  for (const t of types) {
    if (t.parentName !== null || t.kind === 'extension') continue;
    out.push({
      kind: 'type', name: t.name, labels: [], paramTypes: [], typeText: '',
      isStatic: false, isFilePrivate: isFilePrivate(t.declStart),
      condition: conditions[t.declStart], line: lineAt(clean, t.declStart), index: t.declStart,
    });
  }

  const atFileScope = offset => depths[offset] === 0 && innermostType(types, offset) === null;
  const funcRe = /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let m;
  while ((m = funcRe.exec(clean))) {
    if (!atFileScope(m.index)) continue;
    const parenAt = findArgParen(clean, m.index + m[0].length);
    if (parenAt < 0) continue;
    const close = matchBracket(clean, parenAt);
    if (close < 0) continue;
    const params = parseParams(clean.slice(parenAt, close + 1));
    out.push({
      kind: 'func', name: m[1], labels: params.map(p => p.label),
      paramTypes: params.map(p => normaliseTypeText(p.type)), typeText: '',
      isStatic: isStatic(m.index), isFilePrivate: isFilePrivate(m.index),
      condition: conditions[m.index], line: lineAt(clean, m.index), index: m.index,
    });
  }

  const propRe = /\b(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  while ((m = propRe.exec(clean))) {
    if (!atFileScope(m.index)) continue;
    const info = scanPropertyType(clean, depths, m.index + m[0].length, 0);
    out.push({
      kind: 'prop', name: m[2], labels: [], paramTypes: [], typeText: info.type,
      isStatic: isStatic(m.index), isFilePrivate: isFilePrivate(m.index),
      condition: conditions[m.index], line: lineAt(clean, m.index), index: m.index,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Protocol requirements and protocol extensions
// ---------------------------------------------------------------------------------------------

/** Requirements of every protocol declared in this file, with what had to be skipped. */
function collectProtocolFacts(clean, depths, types) {
  const facts = [];
  for (const t of types) {
    if (t.kind !== 'protocol') continue;
    const fact = {
      name: t.name, key: typeKey(t), line: lineAt(clean, t.declStart),
      requirements: [], skipped: [], inherits: [], skipWhole: null,
    };
    const rawHeader = clean.slice(t.nameEnd, t.bodyStart);
    const skip = skipGenericClause(rawHeader);
    if (skip < 0) {
      fact.skipWhole = 'a generic clause this scan cannot read';
      facts.push(fact);
      continue;
    }
    const header = rawHeader.slice(skip);
    if (topLevelKeywordIndex(header, 'where') >= 0) {
      fact.skipWhole = 'a where clause on the protocol';
      facts.push(fact);
      continue;
    }
    const colon = topLevelColon(header);
    if (colon >= 0) {
      for (const raw of splitTopLevel(header.slice(colon + 1), ',')) {
        if (!raw.trim()) continue;
        const name = conformanceName(raw);
        if (name) fact.inherits.push(name);
        else fact.skipWhole = 'an inheritance list this scan cannot read';
      }
    }
    if (/\bassociatedtype\b/.test(clean.slice(t.bodyStart + 1, t.bodyEnd))) {
      fact.skipWhole = 'an associatedtype';
      facts.push(fact);
      continue;
    }
    const interior = depths[t.bodyStart] + 1;
    const isDirectRequirement = offset =>
      depths[offset] === interior && innermostType(types, offset) === t;

    const funcRe = /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)/g;
    funcRe.lastIndex = t.bodyStart;
    let m;
    while ((m = funcRe.exec(clean)) && m.index < t.bodyEnd) {
      if (!isDirectRequirement(m.index)) continue;
      const parenAt = findArgParen(clean, m.index + m[0].length);
      if (parenAt < 0) {
        fact.skipped.push({ name: m[1], reason: 'signature could not be read' });
        continue;
      }
      if (clean.slice(m.index + m[0].length, parenAt).includes('<')) {
        fact.skipped.push({ name: m[1], reason: 'generic requirement' });
        continue;
      }
      const close = matchBracket(clean, parenAt);
      if (close < 0) {
        fact.skipped.push({ name: m[1], reason: 'signature could not be read' });
        continue;
      }
      if (topLevelKeywordIndex(clean.slice(close + 1, t.bodyEnd), 'where') >= 0) {
        fact.skipped.push({ name: m[1], reason: 'where clause' });
        continue;
      }
      const params = parseParams(clean.slice(parenAt, close + 1));
      fact.requirements.push({
        kind: 'func', name: m[1], labels: params.map(p => p.label),
        confident: params.every(p => p.label !== null || p.name !== null),
        line: lineAt(clean, m.index),
      });
    }

    for (const keyword of ['init', 'subscript']) {
      const re = new RegExp(`\\b${keyword}\\b`, 'g');
      re.lastIndex = t.bodyStart;
      while ((m = re.exec(clean)) && m.index < t.bodyEnd) {
        if (!isDirectRequirement(m.index)) continue;
        if (keyword === 'init' &&
            (clean[m.index - 1] === '.' || isIdentChar(clean[m.index - 1]))) continue;
        fact.skipped.push({ name: keyword, reason: `${keyword} requirement` });
      }
    }

    const propRe = /\b(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
    propRe.lastIndex = t.bodyStart;
    while ((m = propRe.exec(clean)) && m.index < t.bodyEnd) {
      if (!isDirectRequirement(m.index)) continue;
      const info = scanPropertyType(clean, depths, m.index + m[0].length, depths[m.index]);
      if (!info.hasType) {
        fact.skipped.push({ name: m[2], reason: 'property without a readable type' });
        continue;
      }
      fact.requirements.push({
        kind: 'prop', name: m[2], labels: [], confident: true,
        line: lineAt(clean, m.index),
      });
    }
    facts.push(fact);
  }
  return facts;
}

/** Members supplied by every `extension SomeName { ... }`, so the driver can spot protocol ones. */
function collectExtensions(clean, types) {
  const out = [];
  for (const t of types) {
    if (t.kind !== 'extension') continue;
    const header = clean.slice(t.nameEnd, t.bodyStart);
    const names = new Set();
    const body = clean.slice(t.bodyStart + 1, t.bodyEnd);
    for (const raw of body.matchAll(/\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)/g)) names.add(raw[1]);
    for (const raw of body.matchAll(/\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)/g)) names.add(raw[1]);
    out.push({
      name: t.name, hasWhereClause: topLevelKeywordIndex(header, 'where') >= 0,
      names, line: lineAt(clean, t.declStart),
    });
  }
  return out;
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
  const cond = computeConditionalPaths(clean);
  const { types, unparsed } = collectTypes(clean);
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

  const protocolFacts = collectProtocolFacts(clean, depths, types);
  const module = relPath.split('/')[0];
  const members = collectMembers(clean, depths, cond, types)
    .map(m => ({ ...m, module, relPath, quote: quoteLine(source, m.index) }));
  const declFacts = [];
  for (const t of types) {
    const conformance = parseConformances(clean, t);
    declFacts.push({
      module, key: typeKey(t), name: t.name, kind: t.kind, parentName: t.parentName,
      relPath, line: lineAt(clean, t.declStart), quote: quoteLine(source, t.declStart),
      conformances: conformance.names, conformanceUnreadable: conformance.unreadable,
      isFilePrivate: /\b(private|fileprivate)\b/.test(
        clean.slice(statementStart(clean, t.declStart), t.declStart)),
    });
  }
  const fileDecls = collectFileDeclarations(clean, depths, cond, types)
    .map(d => ({ ...d, module, relPath, quote: quoteLine(source, d.index) }));

  return {
    findings, decls, calls, types, judged, initsInspected,
    facts: {
      protocolFacts, declFacts, members, fileDecls,
      extensions: collectExtensions(clean, types),
      unparsed: unparsed.length, relPath,
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Rules C and D, which need the whole tree rather than one file
// ---------------------------------------------------------------------------------------------

/** Two members of one type with the same name and an identical shape. */
function sameShape(a, b) {
  if (a.name !== b.name || a.kind !== b.kind || a.isStatic !== b.isStatic) return false;
  if (a.kind === 'func') {
    return a.labels.join('|') === b.labels.join('|') &&
           a.paramTypes.join('|') === b.paramTypes.join('|');
  }
  return a.typeText === b.typeText;
}

/** A protocol's own requirements plus its inherited ones, or a reason to skip the protocol. */
function resolveRequirements(protocol, byName, seen = new Set()) {
  const requirements = [...protocol.requirements];
  const skipped = [...protocol.skipped];
  let skipWhole = protocol.skipWhole;
  if (seen.has(protocol.name)) return { requirements, skipped, skipWhole };
  seen.add(protocol.name);
  for (const inherited of protocol.inherits) {
    const parent = byName.get(inherited);
    if (!parent) {
      skipWhole = `inherited protocol '${inherited}' is not declared in this tree`;
      break;
    }
    const resolved = resolveRequirements(parent, byName, seen);
    if (resolved.skipWhole) { skipWhole = resolved.skipWhole; break; }
    requirements.push(...resolved.requirements);
    skipped.push(...resolved.skipped);
  }
  return { requirements, skipped, skipWhole };
}

/** Does one conformer declare a member matching this requirement? */
function satisfies(members, requirement) {
  const named = members.filter(m => m.name === requirement.name);
  if (named.length === 0) return false;
  if (requirement.kind === 'prop' || !requirement.confident) return true;
  return named.some(m => {
    if (m.kind === 'prop') return requirement.labels.length === 0; // Swift allows `var x` for `func x()`
    if (!m.confident) return true;
    return m.labels.length === requirement.labels.length &&
           m.labels.every((label, i) => label === requirement.labels[i]);
  });
}

function describeRequirement(requirement) {
  if (requirement.kind === 'prop') return `property '${requirement.name}'`;
  const labels = requirement.labels.map(l => (l === null ? '_' : `${l}:`)).join(', ');
  return `func '${requirement.name}(${labels})'`;
}

function checkConformance(facts) {
  const findings = [];
  const stats = {
    protocols: facts.protocols.length, protocolsSkipped: 0,
    conformers: 0, conformersSkipped: 0, requirements: 0, requirementsSkipped: 0,
    reasons: new Map(), conformerReasons: new Map(),
    count: (reason, amount = 1) => stats.reasons.set(reason, (stats.reasons.get(reason) ?? 0) + amount),
  };
  const protocolsByName = new Map(facts.protocols.map(p => [p.name, p]));

  // Protocol-level skips are counted once, not once per conformer.
  const resolvedByName = new Map();
  for (const protocol of facts.protocols) {
    const resolved = resolveRequirements(protocol, protocolsByName);
    resolvedByName.set(protocol.name, resolved);
    if (resolved.skipWhole) {
      stats.protocolsSkipped++;
      stats.count(`protocol '${protocol.name}': ${resolved.skipWhole}`);
    }
    for (const skip of resolved.skipped) {
      stats.requirementsSkipped++;
      stats.count(`requirement '${skip.name}': ${skip.reason}`);
    }
  }

  const extensionMembers = new Map();
  for (const ext of facts.extensions) {
    if (!protocolsByName.has(ext.name)) continue;
    if (!extensionMembers.has(ext.name)) extensionMembers.set(ext.name, new Set());
    for (const name of ext.names) extensionMembers.get(ext.name).add(name);
    if (ext.hasWhereClause) extensionMembers.get(ext.name).add('*'); // a constrained default
  }

  const primaryByScope = new Map();
  const membersByScope = new Map();
  const inTreeTypes = new Set(facts.decls.map(d => d.key));
  for (const decl of facts.decls) {
    const scope = `${decl.module}|${decl.key}`;
    if (!primaryByScope.has(scope)) primaryByScope.set(scope, []);
    primaryByScope.get(scope).push(decl);
  }
  for (const member of facts.members) {
    const scope = `${member.module}|${member.key}`;
    if (!membersByScope.has(scope)) membersByScope.set(scope, []);
    membersByScope.get(scope).push(member);
  }

  for (const decl of facts.decls) {
    const scope = `${decl.module}|${decl.key}`;
    for (const protocolName of decl.conformances) {
      const protocol = protocolsByName.get(protocolName);
      if (!protocol) continue; // a protocol this scan never sees, so nothing can be judged
      const skip = reason => {
        stats.conformersSkipped++;
        stats.conformerReasons.set(reason, (stats.conformerReasons.get(reason) ?? 0) + 1);
      };
      const resolved = resolvedByName.get(protocolName);
      if (resolved.skipWhole) { skip(`its protocol '${protocolName}' could not be read (${resolved.skipWhole})`); continue; }
      if (decl.conformanceUnreadable) {
        skip('the conformance is declared behind a where clause');
        continue;
      }
      const declared = primaryByScope.get(scope) ?? [];
      if (declared.filter(d => d.kind !== 'extension').length !== 1) {
        skip('two declarations of that name live in this tree');
        continue;
      }
      const scopeMembers = membersByScope.get(scope) ?? [];
      const mayInheritMembers = decl.conformances.some(
        name => protocolsByName.has(name) ? false : inTreeTypes.has(name));
      if (scopeMembers.length === 0 && mayInheritMembers) {
        skip('its members may be inherited from another type in this tree');
        continue;
      }
      stats.conformers++;
      const defaults = extensionMembers.get(protocolName) ?? new Set();
      for (const requirement of resolved.requirements) {
        if (defaults.has(requirement.name) || defaults.has('*')) {
          stats.requirementsSkipped++;
          stats.count('a protocol extension provides a default');
          continue;
        }
        stats.requirements++;
        if (satisfies(scopeMembers, requirement)) continue;
        findings.push({
          rule: 'C', path: decl.relPath, line: decl.line, quote: decl.quote,
          typeName: decl.key, typeKind: decl.kind, protocolName,
          requirement, requirementPath: protocol.relPath, requirementLine: requirement.line,
        });
      }
    }
  }
  return { findings, stats };
}

function checkDuplicates(facts) {
  const findings = [];
  const stats = { typeScopes: 0, fileScopes: 0, conditional: 0 };

  const byScope = new Map();
  for (const member of facts.members) {
    if (member.condition) stats.conditional++;
    const scope = `${member.module}|${member.key}`;
    if (!byScope.has(scope)) byScope.set(scope, []);
    byScope.get(scope).push(member);
  }
  for (const list of byScope.values()) {
    stats.typeScopes++;
    const seen = [];
    for (const member of list) {
      const twin = seen.find(other => other.condition === member.condition && sameShape(other, member));
      if (twin) {
        findings.push({
          rule: 'D', path: member.relPath, line: member.line, quote: member.quote,
          name: member.name, scope: `the type '${member.key}'`,
          firstPath: twin.relPath, firstLine: twin.line,
        });
      } else {
        seen.push(member);
      }
    }
  }

  const byName = new Map();
  for (const decl of facts.fileDecls) {
    if (decl.isFilePrivate) continue;
    const key = `${decl.module}|${decl.name}`;
    if (!byName.has(key)) byName.set(key, []);
    byName.get(key).push(decl);
  }
  for (const list of byName.values()) {
    stats.fileScopes++;
    const seen = [];
    for (const decl of list) {
      const twin = seen.find(other => other.condition === decl.condition && other.kind === decl.kind &&
        (decl.kind === 'type' ? true : sameShape(other, decl)));
      if (twin) {
        findings.push({
          rule: 'D', path: decl.relPath, line: decl.line, quote: decl.quote,
          name: decl.name, scope: `file scope of '${decl.module}'`,
          firstPath: twin.relPath, firstLine: twin.line,
        });
      } else {
        seen.push(decl);
      }
    }
  }
  return { findings, stats };
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
let unparsedCount = 0;
const tree = { protocols: [], decls: [], members: [], fileDecls: [], extensions: [] };
const findings = [];
for (const file of files) {
  const relPath = displayPath(file);
  try {
    const { findings: fileFindings, decls, calls, judged, initsInspected, facts } =
      analyse(readFileSync(file, 'utf8'), relPath);
    declCount += decls.length;
    callCount += calls.length;
    judgedCount += judged;
    initCount += initsInspected;
    for (const protocol of facts.protocolFacts) tree.protocols.push({ ...protocol, relPath });
    tree.decls.push(...facts.declFacts);
    tree.members.push(...facts.members);
    tree.fileDecls.push(...facts.fileDecls);
    tree.extensions.push(...facts.extensions);
    unparsedCount += facts.unparsed;
    findings.push(...fileFindings);
  } catch (error) {
    console.log(`SKIP ${relPath}: could not scan (${error.message})`);
  }
}

const conformance = checkConformance(tree);
const duplicates = checkDuplicates(tree);
findings.push(...conformance.findings, ...duplicates.findings);
findings.sort((a, b) => (a.path === b.path ? a.line - b.line : a.path < b.path ? -1 : 1));

for (const f of findings) {
  if (f.rule === 'A') {
    console.log(`FAIL ${f.path}:${f.line}: argument '${f.label}' must precede the labels written before it`);
    console.log(`     declared as  ${describeDeclaration(f.decl)}`);
    console.log(`     call labels  (${f.callLabels.map(l => l ?? '_').join(', ')})`);
  } else if (f.rule === 'B') {
    console.log(`FAIL ${f.path}:${f.line}: bare use of optional parameter '${f.name}: ${f.paramType}' in ${f.owner}'s init`);
    console.log(`     the stored property '${f.name}: ${f.propertyType}' of the same name is not optional`);
  } else if (f.rule === 'C') {
    console.log(`FAIL ${f.path}:${f.line}: ${f.typeName} (${f.typeKind}) declares ${f.protocolName} but is missing ${describeRequirement(f.requirement)}`);
    console.log(`     the requirement is declared in ${f.requirementPath}:${f.requirementLine}`);
  } else {
    console.log(`FAIL ${f.path}:${f.line}: '${f.name}' is declared a second time in ${f.scope}`);
    console.log(`     the first declaration is at ${f.firstPath}:${f.firstLine}`);
  }
  console.log(`     ${f.quote}`);
}

const scanned = `scanned ${files.length} Swift files, ${declCount} declarations, ${callCount} call sites`;
const coverage = `coverage: ${judgedCount} calls resolved to one declaration and were order-checked; ${initCount} initialisers inspected for an optional shadow; ` +
  `${conformance.stats.protocols} protocols with ${conformance.stats.requirements} requirements checked against ${conformance.stats.conformers} conformers; ` +
  `${duplicates.stats.typeScopes} type scopes and ${duplicates.stats.fileScopes} file scopes checked for duplicates`;
const skips = [...conformance.stats.conformerReasons].map(([reason, n]) => `${n} x ${reason}`);
const detail = [];
for (const [reason, n] of conformance.stats.reasons) detail.push(`${n} x ${reason}`);
if (unparsedCount > 0) detail.push(`${unparsedCount} type declaration(s) whose body could not be read`);
if (duplicates.stats.conditional > 0) detail.push(`${duplicates.stats.conditional} member(s) inside #if, only compared within their own branch`);
if (findings.length === 0) {
  console.log(`PASS: swift call-site check; ${scanned}, 0 findings.`);
  console.log(coverage);
  if (skips.length > 0) console.log(`skipped: ${skips.join('; ')}`);
  if (detail.length > 0) console.log(`not judged: ${detail.join('; ')}`);
  console.log(`NOT CHECKED: types, generics, availability, argument counts, requirement types or effects, or any call to something not declared in these files.`);
  process.exitCode = 0;
} else {
  console.log(`FAIL: swift call-site check found ${findings.length} problem(s); ${scanned}.`);
  console.log(coverage);
  if (skips.length > 0) console.log(`skipped: ${skips.join('; ')}`);
  if (detail.length > 0) console.log(`not judged: ${detail.join('; ')}`);
  process.exitCode = 1;
}
