#!/usr/bin/env python3
#  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
#  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
#  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>
#
#  Generate an HTML programmer's reference for sdata-core's public API
#  directly from the .ads specs.  Depends only on the Python 3 standard
#  library -- it reads specs as text and never invokes the Ada toolchain,
#  which is why it works where GNATdoc 26.0 (ASIS/libadalang frontend)
#  crashes on this crate's source closure.
#
#  For each spec it keeps the visible (pre-`private`) declarations and the
#  contiguous `--` doc-comment block that precedes each, then emits a single
#  self-contained HTML page grouped by package.  The license header and the
#  package overview block are recognised and handled specially.
#
#  Usage:
#    scripts/gen-reference.py [-o OUT.html] [--src DIR] [--all]
#
#  By default only the public-contract packages (see PUBLIC_PACKAGES, which
#  mirrors the contract named in CLAUDE.md) are documented; --all documents
#  every spec under the source directory.  Normally invoked through
#  scripts/gen-reference.sh.

import argparse
import html
import re
import sys
from pathlib import Path

#  The public contract consumed by sdata and data-vandal (CLAUDE.md).
PUBLIC_PACKAGES = (
    "sdata_core-commands.ads",
    "sdata_core-evaluator.ads",
    "sdata_core-values.ads",
    "sdata_core-config-runtime.ads",
    "sdata_core-variables.ads",
    "sdata_core-table.ads",
    "sdata_core-statistics.ads",
)

ROUTINE_RE = re.compile(r"^\s*(?:overriding\s+)?(?:function|procedure)\b", re.I)
TYPE_RE = re.compile(r"^\s*(?:type|subtype)\b", re.I)
INSTANCE_RE = re.compile(r"^\s*package\s+[\w.]+\s+is\s+new\b", re.I)
#  A package instantiation with "is" and "new" split across two lines
#  (`package Foo is` / `  new Bar (...)`) -- INSTANCE_RE only matches the
#  single-line form. Checked one line ahead by the caller (parse_spec),
#  not here, since it needs the next line's content, not just this one's.
INSTANCE_CONTINUATION_RE = re.compile(r"^\s*package\s+[\w.]+\s+is\s*$", re.I)
#  The declared name of a type/subtype/package-instance line -- used to
#  check whether a later routine's own signature actually references the
#  type carry is offering it (see carry_name below).
DECL_NAME_RE = re.compile(r"^\s*(?:type|subtype|package)\s+([\w.]+)", re.I)
#  An object, constant or exception declaration: one or more identifiers,
#  then a colon.  (Routines start with a keyword and are matched above.)
OBJECT_RE = re.compile(r"^\s*[A-Za-z]\w*(?:\s*,\s*[A-Za-z]\w*)*\s*:(?!=)", re.I)
PKG_RE = re.compile(r"^\s*package\s+([\w.]+)\s+is\b", re.I)
LICENSE_MARKERS = ("Copyright", "License:", "See LICENSE")


def comment_text(line):
    """Text of a `--` comment line (sans marker), or None if not a comment."""
    s = line.lstrip()
    return s[2:].strip() if s.startswith("--") else None


def classify(line):
    """Return the declaration kind for a visible-part line, or None."""
    if ROUTINE_RE.match(line):
        return "routine"
    if INSTANCE_RE.match(line):
        return "type"
    if TYPE_RE.match(line):
        return "type"
    if OBJECT_RE.match(line):
        low = line.lower()
        if "exception" in low:
            return "exception"
        if "constant" in low:
            return "constant"
        return "value"
    return None


def split_code_comment(line):
    """Split a source line into (code, comment-text-or-None) at the first '--'.

    Naive but sufficient for these specs (no '--' appears inside a string
    literal in the public signatures); the code half drives parsing while the
    comment half becomes documentation.
    """
    idx = line.find("--")
    if idx == -1:
        return line.rstrip(), None
    return line[:idx].rstrip(), line[idx + 2:].strip()


def consume_signature(lines, start, kind):
    """Collect a full declaration starting at `lines[start]`.

    Returns (signature_text, trailing_comments, index_of_last_line).  Trailing
    `--` comments are stripped from the rendered signature and returned
    separately (so `function F return T;  -- note` both terminates correctly
    and contributes its note as documentation).  Subprogram and object
    declarations end at the paren-balanced line terminated by ';'; a type with
    a record/variant body ends at its matching `end ...;`.
    """
    code, com = split_code_comment(lines[start])
    sig = [code]
    trailing = [com] if com else []
    depth = code.count("(") - code.count(")")
    i = start
    is_block_type = kind == "type" and re.search(r"\bis\b.*\brecord\b", code)
    while i + 1 < len(lines):
        if is_block_type:
            if re.search(r"^\s*end\b[^;]*;\s*$", sig[-1]):
                break
        elif depth <= 0 and sig[-1].rstrip().endswith(";"):
            break
        i += 1
        code, com = split_code_comment(lines[i])
        sig.append(code)
        if com:
            trailing.append(com)
        depth += code.count("(") - code.count(")")
        if "record" in code and kind == "type":
            is_block_type = True
    while sig and not sig[-1].strip():     # drop trailing blank code lines
        sig.pop()
    return "\n".join(sig), trailing, i


def parse_spec(path):
    """Return (package_name, overview_lines, [(kind, signature, doc), ...])."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    pkg_name = path.stem.replace("-", ".")

    pkg_idx = next((i for i, ln in enumerate(lines) if PKG_RE.match(ln)), None)
    if pkg_idx is not None:
        pkg_name = PKG_RE.match(lines[pkg_idx]).group(1)

    #  The overview is the first comment block before `package` that is not
    #  the license header.  It usually sits above the `with` clauses, so a
    #  simple walk-back from `package` would miss it -- group the head of the
    #  file into blank-line-separated comment blocks and take the first
    #  non-license one.
    overview = []
    head = lines[:pkg_idx] if pkg_idx is not None else lines
    block = []
    for ln in head:
        c = comment_text(ln)
        if c is not None:
            block.append(c)
            continue
        if block:
            if not any(m in d for d in block for m in LICENSE_MARKERS):
                overview = block
                break
            block = []
    else:
        if block and not any(m in d for d in block for m in LICENSE_MARKERS):
            overview = block

    #  `fresh` accumulates comment lines seen since the last declaration was
    #  consumed -- this is "this declaration's own comment", full stop.
    #  `carry` is a fallback: the fresh comment a `type` declaration just
    #  displayed, made available to later declarations that have no fresh
    #  comment of their own. This exists because a supporting type (a record
    #  or array used only as a routine's parameter/return type) is
    #  frequently documented by a comment that's really about the routine
    #  -- see Resolve_Use_Defaults/Use_Defaults and Call_Function/
    #  Value_Array (single hop) and Aggregate_Invar_Kind -> Aggregate_Spec
    #  -> Aggregate_Spec_Vectors -> Execute_AGGREGATE (multi-hop: two bare
    #  intervening types, issue #135).
    #
    #  Two invariants keep this from reintroducing either failure mode an
    #  earlier, broader design hit (see PR #134's own history): (1) a
    #  declaration's fresh comment always wins OUTRIGHT over `carry` -- never
    #  blended, never appended-to -- so a type or routine with its own
    #  comment can never show a concatenation of its own text and something
    #  inherited (this is what actually broke SData_Core.Evaluator's
    #  Expression_Kind/Binary_Op/Unary_Op/... chain the first time: fresh
    #  comments kept appending onto old carry instead of replacing it).
    #  (2) `carry` is only ever *displayed* by a `routine` -- a bare `type`
    #  with no fresh of its own is transparent (passes `carry` through
    #  unchanged) but never shows it and never re-derives it from anything
    #  but its own fresh comment. This is why Expression/Expression_Access
    #  (bare forward declarations right after the commented Unary_Op) show
    #  nothing rather than incorrectly inheriting "Unary operators." --
    #  bare types don't display carry at all, only pass it along.
    #
    #  What changed for #135 versus PR #134's original narrower rule: `carry`
    #  used to reset after any bare type (single-hop only). It now survives
    #  through an unbounded run of *consecutive bare types* (still killed by
    #  2+ blank lines, a fresh comment of its own -- which replaces it, not
    #  appends to it -- or an unclassified line), so a routine several bare
    #  helper types downstream of a documented type can still inherit it.
    #
    #  A routine with its OWN fresh comment additionally combines it with
    #  carry (carry first, then its own note) -- but ONLY when `carry_names`
    #  (every type identifier the current, still-live carry has passed
    #  through -- the type that originated it, plus every bare type it was
    #  transparently carried across since) contains a name that actually
    #  appears in that routine's own signature. Without this gate, a routine
    #  whose own comment is a complete, self-sufficient description (not a
    #  supplementary trailing note) would incorrectly have an unrelated
    #  upstream type's comment prepended to it merely for being the next
    #  declaration with a fresh comment of its own -- found by auditing the
    #  whole corpus, not just the two target cases: Is_Known_Function (own
    #  comment: "True iff Name... is a registered evaluator function") was
    #  picking up Aggregate_Metadata's comment, an unrelated type two
    #  declarations earlier that Is_Known_Function's signature never
    #  mentions.
    #
    #  `carry_names` must accumulate across the whole bare-type chain, not
    #  just remember the originating type: Execute_AGGREGATE mentions
    #  Aggregate_Spec_Vectors, not Aggregate_Invar_Kind (the type that
    #  actually originated the carried overview text three declarations
    #  earlier) -- an first version of this gate that tracked only the
    #  single originating name wrongly rejected this exact case, the one
    #  #135 was filed about. Tracking the whole set correctly keeps
    #  Execute_AGGREGATE (mentions Aggregate_Spec_Vectors), Function_Arity
    #  (returns Arity_Spec), and Chi_Square_Tests (takes Count_Matrix, the
    #  origin, reached transparently through Count_Vector/Chi_Square_Result/
    #  GOF_Result) combining, while Is_Known_Function reverts to showing
    #  only its own comment. Verified by hand against every declaration in
    #  all 7 public-contract spec files, not just the handful of cases
    #  originally reported -- no remaining misattribution found. Accepted,
    #  stated residual risk: this is a syntactic name match, not a semantic
    #  one -- a routine whose signature happens to textually mention an
    #  unrelated type's name (coincidence, not reference) could still
    #  wrongly combine; not observed anywhere in this corpus, and multi-word
    #  Ada identifiers make an accidental match unlikely in practice.
    decls = []
    fresh = []
    carry = []
    carry_names = []
    blank_run = 0
    i = (pkg_idx or 0) + 1
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped == "private":          # stop at the private part
            break
        c = comment_text(lines[i])
        if c is not None:
            fresh.append(c)
            blank_run = 0
            i += 1
            continue
        if not stripped:
            #  A single blank line is tolerated as a paragraph break within an
            #  otherwise-contiguous doc block (common style: an explanatory
            #  paragraph, one blank line for readability, then the group of
            #  declarations it describes -- e.g. the OPTIONS_* setter family
            #  and the Config.Runtime read-accessor block both write it this
            #  way). Two or more consecutive blanks is treated as a genuine
            #  section break and drops both buffers, same as before.
            blank_run += 1
            if blank_run >= 2:
                fresh = []
                carry = []
                carry_names = []
            i += 1
            continue
        blank_run = 0
        kind = classify(lines[i])
        if kind is None and INSTANCE_CONTINUATION_RE.match(lines[i]) \
           and i + 1 < len(lines) and lines[i + 1].lstrip().lower().startswith("new"):
            #  `package Foo is` / `  new Bar (...)` -- classify() only ever
            #  sees one line, so INSTANCE_RE (single-line "is new") misses
            #  this split form entirely; without this check the line falls
            #  through to the "unclassified" branch below and silently
            #  resets both fresh and carry, which is exactly why
            #  Aggregate_Spec_Vectors (#135) was invisible to the parser,
            #  not merely undocumented.
            kind = "type"
        if kind:
            sig, trailing, last = consume_signature(lines, i, kind)
            #  A type's own fresh comment always wins outright over carry
            #  (never blended -- see the module-level comment above `decls`
            #  for why). A routine is different: its own fresh comment is
            #  usually a short trailing note (e.g. "Raises Script_Error...")
            #  that *supplements* rather than replaces a fuller upstream
            #  overview -- but only combine when carry_names shows this
            #  routine's own signature actually references one of the types
            #  the live carry has passed through; otherwise carry is just
            #  unrelated upstream noise and this routine shows only its own
            #  fresh, same as pre-#135. Empty operands degrade correctly
            #  either way: no carry -> just its own fresh; no fresh -> just
            #  carry; neither -> nothing.
            if kind == "routine":
                if fresh and carry and any(
                    re.search(r"\b" + re.escape(n) + r"\b", sig) for n in carry_names
                ):
                    doc = carry + fresh
                elif fresh:
                    doc = fresh
                else:
                    doc = carry
            else:
                doc = fresh
            decls.append((kind, sig, doc + trailing))
            if kind == "type":
                name_match = DECL_NAME_RE.match(lines[i])
                name = name_match.group(1) if name_match else None
                if fresh:
                    carry = fresh
                    carry_names = [name] if name else []
                elif carry and name:
                    #  Bare type -- transparent: carry's text is unchanged,
                    #  but this type's own name joins the set a later
                    #  routine's signature might reference.
                    carry_names.append(name)
            else:
                carry = []
                carry_names = []
            fresh = []
            i = last + 1
        else:
            fresh = []
            carry = []
            carry_names = []
            i += 1
    return pkg_name, overview, decls


CSS = """
  body{font:15px/1.55 -apple-system,Segoe UI,Roboto,sans-serif;max-width:62em;
       margin:2em auto;padding:0 1em;color:#1a1a1a}
  h1{border-bottom:2px solid #444}
  h2{margin-top:2.5em;border-bottom:1px solid #ccc;color:#234}
  nav{background:#f6f6f6;padding:1em 1.5em;border-radius:6px;line-height:2}
  nav a{margin-right:1.2em;white-space:nowrap}
  .decl{margin:1.4em 0;padding-left:1em;border-left:3px solid #cdd}
  .kind{font-size:.72em;text-transform:uppercase;color:#888;letter-spacing:.06em}
  pre{background:#f4f6f8;padding:.6em .8em;border-radius:4px;overflow-x:auto;
      font:13px/1.45 SFMono-Regular,Consolas,monospace}
  .doc{color:#333;white-space:pre-wrap;margin-top:.4em}
  .overview{color:#444;font-style:italic;white-space:pre-wrap}
  footer{margin-top:3em;color:#999;font-size:.85em;border-top:1px solid #eee;
         padding-top:1em}
"""


def esc(text):
    return html.escape(text)


def render(specs, all_packages):
    nl = "\n"
    out = ["<!doctype html><html lang='en'><head><meta charset='utf-8'>",
           "<meta name='viewport' content='width=device-width,initial-scale=1'>",
           "<title>sdata-core &mdash; Programmer's Reference</title>",
           f"<style>{CSS}</style></head><body>",
           "<h1>sdata-core &mdash; Programmer's Reference</h1>"]
    scope = "all packages" if all_packages else "public-contract packages"
    out.append(f"<p class='overview'>Public API ({esc(scope)}). Generated from "
               "<code>src/*.ads</code> visible declarations.</p>")

    out.append("<nav><strong>Packages</strong><br>")
    for pkg, _, _ in specs:
        out.append(f"<a href='#{esc(pkg)}'>{esc(pkg)}</a>")
    out.append("</nav>")

    for pkg, overview, decls in specs:
        out.append(f"<h2 id='{esc(pkg)}'>{esc(pkg)}</h2>")
        if overview:
            out.append(f"<p class='overview'>{esc(nl.join(overview))}</p>")
        for kind, sig, doc in decls:
            out.append("<div class='decl'>")
            out.append(f"<div class='kind'>{esc(kind)}</div>")
            out.append(f"<pre>{esc(sig)}</pre>")
            if doc:
                out.append(f"<div class='doc'>{esc(nl.join(doc))}</div>")
            out.append("</div>")

    out.append("<footer>Generated by scripts/gen-reference.py "
               "&mdash; sdata-core.</footer>")
    out.append("</body></html>")
    return nl.join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate sdata-core API reference.")
    ap.add_argument("-o", "--output", help="output HTML file (default: stdout)")
    ap.add_argument("--src", default=str(Path(__file__).resolve().parent.parent
                                         / "src"),
                    help="source directory holding the .ads specs")
    ap.add_argument("--all", action="store_true",
                    help="document every spec, not just the public contract")
    args = ap.parse_args(argv)

    src = Path(args.src)
    files = sorted(src.glob("*.ads"))
    if not args.all:
        wanted = set(PUBLIC_PACKAGES)
        files = [f for f in files if f.name in wanted]
    if not files:
        sys.exit(f"gen-reference: no matching .ads specs under {src}")

    specs = [parse_spec(f) for f in files]
    document = render(specs, args.all)

    if args.output:
        Path(args.output).write_text(document, encoding="utf-8")
        decl_count = sum(len(d) for _, _, d in specs)
        print(f"gen-reference: wrote {args.output} "
              f"({len(specs)} packages, {decl_count} declarations)",
              file=sys.stderr)
    else:
        sys.stdout.write(document)


if __name__ == "__main__":
    main()
