#!/usr/bin/env node
/*
 * VideoShrink call-site check - a source scan, not a compiler.
 *
 * This machine has no Swift toolchain, and every Swift compile has to happen in the cloud,
 * where the minutes are rationed. Every mechanical mistake this project has actually made is
 * visible by reading the source, so the four classes below are checked here instead.
 *
 * WHAT IS READ, AND THE ONE TREE THAT IS DELIBERATELY NOT READ.
 *   Four trees by default: VideoShrink/ (the app's own Swift), VideoShrinkTests/ (the unit-test
 *   target), VideoShrinkUITests/ (the one target that launches the app rather than reading it)
 *   and the Expo bridge directory modules/videoshrink-native/ios/. The bridge files are the
 *   Swift that makes this an Expo app, and until this change nothing on this machine read them
 *   at all.
 *   The pod's VideoShrinkCore/ directory is NOT read: it is a byte-for-byte mirror of
 *   VideoShrink/{Models,Services,Presentation}, written by scripts/sync-native-sources.mjs and
 *   git-ignored, so reading it would declare every type in that module twice and turn every
 *   judged call into an ambiguous skip. The source it is copied from is read instead, and the
 *   exclusion is named in the output so the file count can be reconciled.
 *   The bridge files import ExpoModulesCore, UIKit and SwiftUI. Everything those frameworks
 *   declare is outside the scanned set, so calls into them are skipped exactly as calls into
 *   Apple's APIs always were. That skip is counted and printed; it is not coverage.
 *
 * RULE A - argument label order.
 *   Swift requires a call's labelled arguments to appear in the declaration's order. For every
 *   `func`, explicit `init`, synthesised struct memberwise initialiser and enum case in the
 *   scanned tree, the ordered parameter labels are recorded. A call is resolved against the
 *   declarations in its own file first, and only against the rest of the scanned tree when its
 *   own file declares nothing of that name. That second step is what lets the bridge files be
 *   checked at all, because almost every call in them constructs a type declared in VideoShrink/
 *   and they declare almost nothing themselves. Because an all-unlabelled call can never violate
 *   the ordering rule, the cross-file step is taken only for calls that write at least one
 *   argument label; that also keeps a framework call like Expo's `View(_:)` from being resolved
 *   to a same-named declaration in the app. A call is judged only when exactly one declaration
 *   can accept the labels the call supplies; if none or several can, the call is skipped rather
 *   than guessed, and every skip is counted by reason in the output. When a supplied label exists
 *   in the resolved declaration but sits before a label the call already consumed, that is the
 *   definite compile error "argument 'x' must precede argument 'y'".
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
 *   different `#if` branches is never compared. One comparison crosses directories, for the one
 *   seam where the directory rule would be wrong: the Expo pod compiles its two bridge files and
 *   its mirrored copy of VideoShrink/{Models,Services,Presentation} into ONE module, so a
 *   file-scope name declared on both sides of that seam is a redeclaration even though the two
 *   files sit in different scanned target directories.
 *
 * RULE E - a member referenced through a type's own name, where no such member exists.
 *   Rules A to D cannot see this at all: A resolves call *labels* and never asks whether the thing
 *   being called exists, and C and D compare declarations with each other. So `Self.pauseHeadline2`
 *   or `BatchSelectionScreen.unaccountedHeading2` would pass this scan and be caught only by the
 *   compiler. A reference is reported when its base is a type declared in the scanned tree - or
 *   `Self`, inside a type this scan can place - AND the member name is declared *nowhere* in the
 *   tree: not as a member of any type, not as a file-scope declaration, not as a protocol
 *   requirement, not as a type, and not as an enum case.
 *
 *   It deliberately does not report the softer mistake - a member that exists, but on a different
 *   type than the reference names. That needs the module and inheritance rules this scan does not
 *   have, and a false report there would be worse than silence. Those references are counted so the
 *   output says how much was looked at and not judged.
 *
 *   Enum cases with associated values are members too, and until round 22 this scan collected none
 *   of them: the case text was read with a scanner that counted `(` as a nesting level, so
 *   `case noSession(resolution:)` arrived as the text `noSession(` and produced no declaration at
 *   all. Every such case was invisible to Rules A, C and D - its labels were never recorded, so a
 *   call to it was never order-checked - and Rule E is what surfaced the gap. Fixing it makes 24
 *   more call sites judgeable.
 *
 * RULE F - a computed property whose body is more than one statement, written without `return`.
 *   Implicit returns are a single-expression feature: `var x: T { expression }` returns it, and
 *   the moment a name is bound first - `var x: T { let y = ...; expression }` - the getter is a
 *   function with no return on a path that must return a value, which is a hard compile error.
 *
 *   This is not a hypothetical. It is the one thing the first compile of the last ten rounds
 *   found: `BatchViewModel.selectableAssets` bound `unaccounted` before its `filter`, and the
 *   whole app and test target did not build. Nothing on Windows could see it. Rules A to E all
 *   look at *names* - label order, shadowing, missing requirements, duplicates, members that do
 *   not exist - and this is a shape, which is why it needed its own rule rather than a tweak to
 *   an existing one.
 *
 *   A property is reported when its declared type is not `Void`, its body contains no `return` at
 *   all, and the first statement in that body begins with `let`, `var`, `guard`, `for`, `while`,
 *   `repeat`, `defer` or `do`. Those cannot be expressions, so a body that opens with one and never
 *   returns is wrong whatever else is true of it. A body that opens with an expression - however
 *   many lines it wraps across - is left alone, which is what keeps the rule quiet on the hundreds
 *   of single-expression getters this codebase writes. `get`/`set` accessor blocks open with `get`,
 *   so they are left alone too, and so is any property marked `@ViewBuilder`: a builder allows a
 *   body of statements without a return, which is the whole point of it.
 *
 *   `some View` used to be excluded along with `@ViewBuilder`, on the reasoning that a view body
 *   needs no return. That is true of a view *builder* and false of an ordinary `some View`
 *   property, and both shapes are everywhere in this app - so the exclusion hid half the targets.
 *   Within the hour of writing the rule, a two-statement `some View` property without a `return`
 *   broke the build: the compiler found `DeletionSheet.warning`, which this rule had been skipping.
 *
 *   The distinction it now draws is the one Swift actually draws. `View` declares
 *   `@ViewBuilder var body: Self.Body { get }`, and a conforming type inherits that attribute, so a
 *   property named `body` whose type is `some View` is a builder body and needs no `return` - which
 *   is why widening the rule to every `some View` property immediately reported
 *   `QualityPillGroup.body`, code that compiles and always has. Any other `some View` property is
 *   an ordinary getter and needs one.
 *
 * WHAT THIS DOES NOT COVER - do not mistake it for a compiler:
 *   - types, generics, availability, access control, actor isolation, effects, and overload
 *     resolution beyond the narrow uniqueness rules above;
 *   - argument COUNT: a call that omits a required parameter, or passes too many, is silent;
 *   - anything not declared in the scanned tree (SwiftUI, UIKit, Foundation, PhotoKit,
 *     AVFoundation, XCTest, ExpoModulesCore, the standard library), so a wrong label on an
 *     external API is invisible;
 *   - string interpolation contents, macros, operators, subscripts and key paths;
 *   - Rule E judges names, not types or visibility: a member that exists on the right type but
 *     with the wrong access level, or that exists only in the test target while the reference is
 *     in the app, is left alone; and a reference through `Self` is judged only where the enclosing
 *     type could be placed.
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
 *     different modules and are left alone, EXCEPT across the one seam named above; that
 *     assumption is wrong for exactly that pair of directories and is applied deliberately
 *     everywhere else.
 *   - Rule A's cross-file step can only ever ADD a judgment, never remove one: a call whose own
 *     file declares something of that name is resolved exactly as it was before the step
 *     existed. It is still a guess in one direction, though: a call to a framework API that
 *     shares its name with the only declaration of that name in the scanned tree is judged
 *     against that declaration. The counts printed below say how much was judged and how much
 *     was left alone.
 *   A clean run is evidence, never proof. A finding is a very strong hint.
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { resolve, relative, dirname, basename } from 'node:path';
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
      // A case runs to the end of its line - or past it, while an associated value is still open.
      // This used to advance while `depths[end] === interior`, and `depths` counts `(`, `[` and
      // `{` together, so the scan stopped at the first parenthesis: `case noSession(resolution:)`
      // arrived here as the text `noSession(`, matched nothing, and produced NO declaration at all.
      // Every enum case with an associated value was therefore invisible to all four rules - its
      // labels were never recorded, a call to it was never order-checked, and Rule E reported it as
      // a name declared nowhere until this was found.
      let end = cm.index + cm[0].length;
      let open = 0;
      while (end < t.bodyEnd && (clean[end] !== '\n' || open > 0)) {
        if (clean[end] === '(' || clean[end] === '[') open++;
        if (clean[end] === ')' || clean[end] === ']') open = Math.max(0, open - 1);
        end++;
      }
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
    if (before === '@' || before === '#') continue;
    // A call written `.member(...)` - a leading dot and no type name - is collected now, and is
    // resolved tree-wide rather than against its own file. Until round 22 it was dropped here, on
    // the reasonable-sounding grounds that resolving one needs type inference this scan does not
    // have. That reasoning was about *which type* the member belongs to, and it cost far more than
    // it saved: `.planning(resolution:frameRate:)`, `.saved(originalBytes:copyBytes:)` and the rest
    // of this codebase's enum-case and member-call style were invisible. A count of the shape in
    // the scanned files found 1,371 of them, 429 carrying at least one label, and not one was being
    // judged. The name is enough to resolve one here, because the same guards that keep a framework
    // call from being mistaken for a local declaration still apply: the labels must match exactly
    // one declaration in the tree, and a call writing no labels is left alone.
    const dotMember = before === '.';
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
    calls.push({ name, labels, index: m.index, parenAt, close, dotMember });
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
  const module = relPath.split('/')[0];

  for (const d of decls) {
    d.relPath = relPath;
    d.module = module;
    d.line = lineAt(clean, d.index);
    d.quote = quoteLine(source, d.index);
  }
  for (const call of calls) {
    call.relPath = relPath;
    call.line = lineAt(clean, call.index);
    call.quote = quoteLine(source, call.index);
  }

  const findings = [];
  let initsInspected = 0;

  // Rule B. Rule A needs the declarations of every file, so it lives in checkCallOrder below.
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
    findings, decls, calls, types, initsInspected, module,
    // Rule E needs the cleared text and the original: the first to find references without
    // matching inside a comment or a string, the second to quote the line it found one on.
    clean, source,
    facts: {
      protocolFacts, declFacts, members, fileDecls,
      extensions: collectExtensions(clean, types),
      unparsed: unparsed.length, relPath,
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Rule A, which needs every file's declarations: a call is resolved against its own file first
// ---------------------------------------------------------------------------------------------

/**
 * Rule E: a member referenced through a type's own name, where no such member exists.
 *
 * Every round of this project has added static sentences and rules that another part of the app
 * reads by name - `BatchSelectionScreen.unaccountedHeading`, `Self.pauseHeadline(deletion:)`,
 * `VideoReasonList.RowDescription` - and Rules A to D cannot see any of them. Rule A resolves call
 * *labels*; it never asks whether the thing being called exists. Rules C and D compare declarations
 * against each other. So `Self.pauseHeadline2(...)` would compile as far as this scan is concerned,
 * and the first thing to notice would be the compiler, on a machine nobody has.
 *
 * WHAT IT JUDGES, AND WHAT IT DELIBERATELY DOES NOT
 *   A reference is reported when the base is a type declared in the scanned tree (or `Self`, inside
 *   a type this scan can place) AND the member name is declared *nowhere* in the tree - not as a
 *   member of any type, not as a file-scope declaration, not as a protocol requirement, not as a
 *   type. A name that exists nowhere cannot resolve to anything, so a reference to one is a defect
 *   whatever the surrounding code is doing.
 *
 *   It does not report the softer and more common mistake - a member that exists, but on a
 *   different type than the one the reference names. That needs the module and inheritance rules
 *   this scan does not have, and a false report there would be worse than silence: the whole value
 *   of this file is that a finding is worth acting on. Those references are counted instead, so the
 *   output says how much was looked at and not judged.
 *
 *   Skipped rather than guessed, like everything else here: a base name that is not a declared type
 *   (which is most of them - SwiftUI, UIKit and the standard library are outside this scan); a base
 *   name declared more than once, so the reference could be to either; a member the compiler
 *   synthesises rather than declares (`allCases` from `CaseIterable`, `rawValue` from
 *   `RawRepresentable`); and `Self` outside a type this scan can place.
 */
function checkMemberReferences(files) {
  const findings = [];
  const stats = {
    references: 0, onTheType: 0, declaredElsewhere: 0,
    notATypeName: 0, ambiguousTypeName: 0, synthesized: 0,
  };

  const declaredNames = new Set();
  const membersByScope = new Map();
  const typeKeysByName = new Map();

  for (const file of files) {
    const module = file.facts.module;
    for (const member of file.facts.members) {
      declaredNames.add(member.name);
      const scope = `${module}|${member.key}`;
      if (!membersByScope.has(scope)) membersByScope.set(scope, new Set());
      membersByScope.get(scope).add(member.name);
    }
    for (const decl of file.facts.fileDecls) declaredNames.add(decl.name);
    for (const decl of file.facts.declFacts) {
      declaredNames.add(decl.name);
      if (!typeKeysByName.has(decl.name)) typeKeysByName.set(decl.name, new Set());
      typeKeysByName.get(decl.name).add(`${module}|${decl.key}`);
    }
    for (const protocol of file.facts.protocolFacts) {
      declaredNames.add(protocol.name);
      for (const requirement of protocol.requirements) declaredNames.add(requirement.name);
      for (const skipped of protocol.skipped) declaredNames.add(skipped.name);
    }
    for (const extension of file.facts.extensions) declaredNames.add(extension.name);
  }

  // Enum cases are members of their enum, but they are collected with the other declarations
  // rather than with the members above, so `SomeEnum.someCase` would otherwise read as a name that
  // exists nowhere - which is how the first run of this rule reported 170 of them.
  for (const file of files) {
    for (const decl of file.decls) {
      if (decl.kind !== 'case') continue;
      declaredNames.add(decl.name);
      for (const key of typeKeysByName.get(decl.typeName) ?? []) {
        if (!membersByScope.has(key)) membersByScope.set(key, new Set());
        membersByScope.get(key).add(decl.name);
      }
    }
  }

  // Members the compiler writes for a declaration rather than taking them from one.
  const synthesized = new Set(['allCases', 'rawValue', 'init', 'self', 'hashValue', 'description']);

  for (const file of files) {
    const clean = file.clean;
    const reference = /(^|[^A-Za-z0-9_.])(Self|[A-Z][A-Za-z0-9_]*)\s*\.\s*([a-z_][A-Za-z0-9_]*)/g;
    let hit;
    while ((hit = reference.exec(clean))) {
      const base = hit[2];
      const member = hit[3];
      const at = hit.index + hit[1].length;
      let keys;
      if (base === 'Self') {
        const owner = innermostType(file.types, at);
        keys = owner ? new Set([`${file.module}|${typeKey(owner)}`]) : null;
      } else {
        keys = typeKeysByName.get(base) ?? null;
      }
      if (!keys) { stats.notATypeName++; continue; }
      stats.references++;
      if (keys.size > 1) { stats.ambiguousTypeName++; continue; }
      if (synthesized.has(member)) { stats.synthesized++; continue; }
      const key = [...keys][0];
      if ((membersByScope.get(key) ?? new Set()).has(member)) { stats.onTheType++; continue; }
      if (declaredNames.has(member)) { stats.declaredElsewhere++; continue; }
      findings.push({
        rule: 'E', path: file.facts.relPath, line: lineAt(clean, at),
        quote: quoteLine(file.source, at), base, member,
      });
    }
  }
  return { findings, stats };
}

/**
 * Order-check every call in the tree.
 *
 * A call's own file is consulted first, and the rest of the tree only when that file declares
 * nothing of the call's name. That order matters twice: it keeps every judgment this scan made
 * before the cross-file step existed (so the step can only add coverage), and it keeps a
 * framework call like Expo's `View(_:)` out of a same-named declaration elsewhere in the app,
 * because such a call writes no argument label and the cross-file step ignores those - an
 * all-unlabelled call can never violate the ordering rule anyway.
 */
function checkCallOrder(files) {
  const findings = [];
  const stats = {
    judged: 0, crossFile: 0, crossFileInBridge: 0,
    unresolved: 0, ambiguous: 0, noMatch: 0, unlabelled: 0, memberJudged: 0,
  };

  const treeByName = new Map();
  for (const file of files) {
    for (const decl of file.decls) {
      if (!treeByName.has(decl.name)) treeByName.set(decl.name, []);
      treeByName.get(decl.name).push(decl);
    }
  }

  for (const file of files) {
    const localByName = new Map();
    for (const decl of file.decls) {
      if (!localByName.has(decl.name)) localByName.set(decl.name, []);
      localByName.get(decl.name).push(decl);
    }
    for (const call of file.calls) {
      // A leading-dot call has no file-local meaning, so it never gets the local-first step: the
      // only thing that can resolve it is a declaration somewhere in the tree.
      const local = call.dotMember ? undefined : localByName.get(call.name);
      let candidates = local;
      if (!candidates) {
        if (!call.labels.some(label => label !== null)) { stats.unlabelled++; continue; }
        candidates = treeByName.get(call.name);
      }
      if (!candidates) { stats.unresolved++; continue; }
      const supplied = new Set(call.labels.filter(l => l !== null));
      const matching = candidates.filter(d => [...supplied].every(l => d.labels.includes(l)));
      if (matching.length === 0) { stats.noMatch++; continue; }
      if (matching.length > 1) { stats.ambiguous++; continue; }
      const decl = matching[0];
      stats.judged++;
      if (call.dotMember) stats.memberJudged++;
      if (!local) {
        stats.crossFile++;
        if (call.relPath.startsWith(`${BRIDGE_DIRECTORY}/`)) stats.crossFileInBridge++;
      }
      const result = checkOrder(decl.labels, call.labels);
      if (result.ok || result.skip) continue;
      findings.push({
        rule: 'A',
        path: call.relPath,
        line: call.line,
        quote: call.quote,
        name: call.name,
        label: result.label,
        decl,
        callLabels: call.labels,
      });
    }
  }
  return { findings, stats };
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
  const stats = { typeScopes: 0, fileScopes: 0, conditional: 0, podSeam: 0 };

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

  // One comparison crosses directories, for the one seam where the rule above would be wrong.
  // The Expo pod compiles its two bridge files and its own mirrored copy of
  // VideoShrink/{Models,Services,Presentation} into ONE module, so a file-scope name declared on
  // both sides of that seam is a redeclaration even though the two files sit in different
  // scanned target directories. Only a same-kind, same-shape pair is reported, and a file-private
  // declaration is left alone, exactly as in the per-directory check.
  const podSwift = facts.fileDecls.filter(d => d.mirroredIntoPod && !d.isFilePrivate);
  if (podSwift.length > 0) {
    for (const decl of facts.fileDecls) {
      if (!decl.bridgeFile || decl.isFilePrivate) continue;
      stats.podSeam++;
      const twin = podSwift.find(other => other.name === decl.name &&
        other.condition === decl.condition && other.kind === decl.kind &&
        (decl.kind === 'type' ? true : sameShape(other, decl)));
      if (!twin) continue;
      findings.push({
        rule: 'D', path: decl.relPath, line: decl.line, quote: decl.quote,
        name: decl.name,
        scope: `the Expo pod's compilation unit, which compiles the bridge files with the app Swift`,
        firstPath: twin.relPath, firstLine: twin.line,
      });
    }
  }
  return { findings, stats };
}

// ---------------------------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------------------------

// The two Expo bridge files, and the one generated tree this scan must not read. The podspec's
// source_files glob compiles both bridge files together with the pod's copy of
// VideoShrink/{Models,Services,Presentation}, which is what makes them one compilation unit. Those
// three folders are the ones scripts/sync-native-sources.mjs mirrors; if that script ever mirrors
// another folder, add it here too, or the seam comparison below will quietly stop covering it.
const BRIDGE_DIRECTORY = 'modules/videoshrink-native/ios';
const GENERATED_MIRROR_DIRECTORY = 'VideoShrinkCore';
const MIRRORED_SOURCE_FOLDERS = [
  'VideoShrink/Models', 'VideoShrink/Services', 'VideoShrink/Presentation',
];
const excludedDirectories = [];

function collectSwiftFiles(target) {
  const stat = statSync(target);
  if (stat.isFile()) return target.endsWith('.swift') ? [target] : [];
  const out = [];
  for (const entry of readdirSync(target, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
    const full = resolve(target, entry.name);
    if (entry.isDirectory()) {
      // The pod's mirror of the app's own Swift is a byte copy of files this scan already reads.
      // Reading it as well would declare every one of those types twice, which makes every call
      // to them ambiguous and silently turns judgments into skips.
      if (entry.name === GENERATED_MIRROR_DIRECTORY) { excludedDirectories.push(displayPath(full)); continue; }
      out.push(...collectSwiftFiles(full));
    }
    else if (entry.name.endsWith('.swift')) out.push(full);
  }
  return out;
}

function displayPath(file) {
  const rel = relative(repoRoot, file);
  return rel.startsWith('..') ? file.replaceAll('\\', '/') : rel.replaceAll('\\', '/');
}

const args = process.argv.slice(2).filter(a => !a.startsWith('--'));
const targets = args.length > 0 ? args : [
  resolve(repoRoot, 'VideoShrink'),
  resolve(repoRoot, 'VideoShrinkTests'),
  resolve(repoRoot, 'VideoShrinkUITests'),
  resolve(repoRoot, BRIDGE_DIRECTORY),
];

const files = [];
for (const target of targets) {
  const resolved = resolve(process.cwd(), target);
  // The same exclusion, for the same reason, when the mirror is named on the command line: a run
  // that read it could only produce fewer judgments than the source it was copied from, under a
  // PASS line that would look like coverage of the pod.
  if (basename(resolved) === GENERATED_MIRROR_DIRECTORY) {
    excludedDirectories.push(displayPath(resolved));
    continue;
  }
  for (const file of collectSwiftFiles(resolved)) if (!files.includes(file)) files.push(file);
}
files.sort();

/**
 * Rule F: a computed property whose body is more than one statement needs an explicit `return`.
 *
 * This one reads shapes rather than names, which is why it is its own function: it wants the
 * source text and the indentation, and nothing Rules A to E collect.
 *
 * The brace walk ignores line comments and string literals before counting, so a `{` inside
 * either cannot send it hunting for a closing brace that is not there. That is an approximation -
 * a multi-line string or a block comment containing a brace would still confuse it - and the
 * cost of being wrong in that direction is a missed finding, not a false one, because a body it
 * fails to delimit is simply never judged.
 */
function checkGetterReturns(files) {
  const findings = [];
  let inspected = 0;
  for (const file of files) {
    const lines = file.source.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const decl = /^(\s*)(?:@\w+(?:\([^)]*\))?\s+)?(?:public |private |internal |fileprivate |final )*var\s+(\w+)\s*:\s*(.+?)\s*\{\s*$/.exec(lines[i]);
      if (!decl) continue;
      const [, indent, name, type] = decl;
      // `Void` has nothing to return and cannot be wrong in the way this rule describes. `some
      // View` deliberately does NOT appear here: only a `@ViewBuilder` body may be written as bare
      // statements, and that is what the check below excludes instead.
      if (/\bVoid\b/.test(type)) continue;
      // A `body` of type `some View` is the `View` protocol's own requirement, and the protocol
      // annotates it `@ViewBuilder`, so a conforming type inherits the attribute and a body of
      // bare statements is exactly right. Everything else is an ordinary getter.
      if (name === 'body' && /\bsome View\b/.test(type)) continue;
      const decorated = lines[i].includes('@ViewBuilder') ||
        (i > 0 && lines[i - 1].trim().startsWith('@ViewBuilder'));
      if (decorated) continue;

      let depth = 1;
      const body = [];
      for (let j = i + 1; j < lines.length && depth > 0; j++) {
        const stripped = lines[j].replace(/\/\/.*$/, '').replace(/"(?:[^"\\]|\\.)*"/g, '""');
        for (const ch of stripped) {
          if (ch === '{') depth += 1;
          else if (ch === '}') depth -= 1;
        }
        if (depth > 0) body.push(lines[j]);
      }
      if (depth > 0) continue; // Unbalanced: this scan cannot place the body, so it says nothing.
      inspected += 1;
      if (/\breturn\b/.test(body.join('\n'))) continue;

      // The first statement in the body, which for a correctly-written getter is either `return`
      // or an expression. A statement keyword there means the body is more than one expression.
      const base = `${indent}    `;
      const first = body.find(line => line.trim() && line.startsWith(base) && !line.trim().startsWith('//'));
      if (first && /^\s*(let|var|guard|for|while|repeat|defer|do)\b/.test(first)) {
        findings.push({
          rule: 'F', path: file.relPath, line: i + 1, name, type,
          quote: lines[i].trim(),
        });
      }
    }
  }
  return { findings, stats: { inspected } };
}

let declCount = 0;
let callCount = 0;
let initCount = 0;
let unparsedCount = 0;
const tree = { protocols: [], decls: [], members: [], fileDecls: [], extensions: [] };
const analysed = [];
const findings = [];
for (const file of files) {
  const relPath = displayPath(file);
  try {
    const { findings: fileFindings, decls, calls, initsInspected, facts, types, clean, source } =
      analyse(readFileSync(file, 'utf8'), relPath);
    declCount += decls.length;
    callCount += calls.length;
    initCount += initsInspected;
    // Rule E needs the whole analysis, not just the declarations and calls: the members a file
    // declares, the types it declares, the text it was read from and the module it belongs to.
    analysed.push({ decls, calls, facts, types, clean, source, relPath, module: facts.module });
    const inBridgeDirectory = relPath.startsWith(`${BRIDGE_DIRECTORY}/`);
    const mirroredIntoPod = MIRRORED_SOURCE_FOLDERS.some(folder => relPath.startsWith(`${folder}/`));
    for (const protocol of facts.protocolFacts) tree.protocols.push({ ...protocol, relPath });
    tree.decls.push(...facts.declFacts);
    tree.members.push(...facts.members);
    tree.fileDecls.push(...facts.fileDecls.map(d => ({
      ...d, bridgeFile: inBridgeDirectory, mirroredIntoPod,
    })));
    tree.extensions.push(...facts.extensions);
    unparsedCount += facts.unparsed;
    findings.push(...fileFindings);
  } catch (error) {
    console.log(`SKIP ${relPath}: could not scan (${error.message})`);
  }
}

const callOrder = checkCallOrder(analysed);
const memberRefs = checkMemberReferences(analysed);
const conformance = checkConformance(tree);
const duplicates = checkDuplicates(tree);
const getterReturns = checkGetterReturns(analysed);
findings.push(...callOrder.findings, ...conformance.findings, ...duplicates.findings,
              ...memberRefs.findings, ...getterReturns.findings);
findings.sort((a, b) => (a.path === b.path ? a.line - b.line : a.path < b.path ? -1 : 1));

for (const f of findings) {
  if (f.rule === 'A') {
    console.log(`FAIL ${f.path}:${f.line}: argument '${f.label}' must precede the labels written before it`);
    const where = f.decl.relPath === f.path ? '' : ` in ${f.decl.relPath}:${f.decl.line}`;
    console.log(`     declared as  ${describeDeclaration(f.decl)}${where}`);
    console.log(`     call labels  (${f.callLabels.map(l => l ?? '_').join(', ')})`);
  } else if (f.rule === 'B') {
    console.log(`FAIL ${f.path}:${f.line}: bare use of optional parameter '${f.name}: ${f.paramType}' in ${f.owner}'s init`);
    console.log(`     the stored property '${f.name}: ${f.propertyType}' of the same name is not optional`);
  } else if (f.rule === 'C') {
    console.log(`FAIL ${f.path}:${f.line}: ${f.typeName} (${f.typeKind}) declares ${f.protocolName} but is missing ${describeRequirement(f.requirement)}`);
    console.log(`     the requirement is declared in ${f.requirementPath}:${f.requirementLine}`);
  } else if (f.rule === 'E') {
    console.log(`FAIL ${f.path}:${f.line}: '${f.base}.${f.member}' names a member that is declared nowhere in the scanned tree`);
    console.log(`     a name that exists nowhere cannot resolve, whatever else is true of the code around it`);
  } else if (f.rule === 'F') {
    console.log(`FAIL ${f.path}:${f.line}: '${f.name}: ${f.type}' is a getter with more than one statement and no return`);
    console.log(`     implicit returns are a single-expression feature; this body binds a name first, so it must write 'return'`);
  } else {
    console.log(`FAIL ${f.path}:${f.line}: '${f.name}' is declared a second time in ${f.scope}`);
    console.log(`     the first declaration is at ${f.firstPath}:${f.firstLine}`);
  }
  console.log(`     ${f.quote}`);
}

const scanned = `scanned ${files.length} Swift files, ${declCount} declarations, ${callCount} call sites`;
const scope = args.length > 0
  ? `scope: the ${files.length} Swift files named on the command line`
  : `scope: VideoShrink/, VideoShrinkTests/, VideoShrinkUITests/ and the Expo bridge files in ${BRIDGE_DIRECTORY}/`;
const coverage = `coverage: ${callOrder.stats.judged} calls resolved to one declaration and were order-checked` +
  (callOrder.stats.crossFile > 0 ? ` (${callOrder.stats.crossFile} of them resolved across files, ${callOrder.stats.crossFileInBridge} of those written in the two bridge files - the step that makes the bridge files checkable at all; ${callOrder.stats.memberJudged} written with a leading dot, which resolve only across files)` : '') +
  `; ${initCount} initialisers inspected for an optional shadow; ` +
  `${conformance.stats.protocols} protocols with ${conformance.stats.requirements} requirements checked against ${conformance.stats.conformers} conformers; ` +
  `${duplicates.stats.typeScopes} type scopes and ${duplicates.stats.fileScopes} file scopes checked for duplicates` +
  (duplicates.stats.podSeam > 0 ? `, plus ${duplicates.stats.podSeam} name(s) of the bridge files checked against the app Swift the pod compiles them with` : '') +
  `; ${memberRefs.stats.onTheType} member references resolved to a member of the type they name, out of ${memberRefs.stats.references} made through a type name this scan knows` +
  `; ${getterReturns.stats.inspected} computed properties inspected for a multi-statement body without a return`;
const notMemberChecked = `not member-checked: ${memberRefs.stats.notATypeName} references whose base is not a type declared in the scanned tree ` +
  `(SwiftUI, UIKit, Foundation, PhotoKit, AVFoundation, XCTest and the standard library are all outside it); ` +
  `${memberRefs.stats.ambiguousTypeName} where the base name is declared more than once; ` +
  `${memberRefs.stats.synthesized} to a member the compiler writes rather than one a declaration supplies; ` +
  `${memberRefs.stats.declaredElsewhere} to a member that exists in the tree but not on the type this reference names, which needs the module and inheritance rules this scan does not have - so a typo that lands on another type's member is left alone rather than guessed at`;
const notOrderChecked = `not order-checked: ${callOrder.stats.unresolved} call sites whose name is declared nowhere in the tree ` +
  `(SwiftUI, UIKit, PhotoKit, AVFoundation, ExpoModulesCore and the standard library are all outside it); ` +
  `${callOrder.stats.ambiguous} where several declarations could accept the labels written; ` +
  `${callOrder.stats.noMatch} where the name is declared but no declaration accepts the labels written; ` +
  `${callOrder.stats.unlabelled} calls written with no argument labels that their own file does not declare, which the cross-file step leaves alone because an unlabelled call cannot break the ordering rule`;
const skips = [...conformance.stats.conformerReasons].map(([reason, n]) => `${n} x ${reason}`);
const detail = [];
for (const [reason, n] of conformance.stats.reasons) detail.push(`${n} x ${reason}`);
if (unparsedCount > 0) detail.push(`${unparsedCount} type declaration(s) whose body could not be read`);
if (duplicates.stats.conditional > 0) detail.push(`${duplicates.stats.conditional} member(s) inside #if, only compared within their own branch`);
const report = () => {
  console.log(scope);
  console.log(coverage);
  console.log(notOrderChecked);
  console.log(notMemberChecked);
  for (const excluded of excludedDirectories) {
    console.log(`excluded: ${excluded}/ (a generated byte copy of Swift this scan already reads, written by npm run sync:native)`);
  }
  if (skips.length > 0) console.log(`skipped: ${skips.join('; ')}`);
  if (detail.length > 0) console.log(`not judged: ${detail.join('; ')}`);
};
if (files.length === 0) {
  // A run that read nothing is not a clean run. The only way to get here is to name targets that
  // resolve to the generated mirror this scan excludes, or to no Swift at all, and a green line
  // over zero files would be read as the opposite of what happened.
  console.log(`NOT RUN: swift call-site check; the target list resolved to no Swift files to read.`);
  report();
  process.exitCode = 1;
} else if (findings.length === 0) {
  console.log(`PASS: swift call-site check; ${scanned}, 0 findings.`);
  report();
  console.log(`NOT CHECKED: types, generics, availability, argument counts, requirement types or effects, or any call to something not declared in these files - including the bridge files' calls into ExpoModulesCore, which are counted as not order-checked above rather than guessed at.`);
  process.exitCode = 0;
} else {
  console.log(`FAIL: swift call-site check found ${findings.length} problem(s); ${scanned}.`);
  report();
  process.exitCode = 1;
}
