#!/usr/bin/env python3
#  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
#  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
#  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>
#
#  Regression tests for gen-reference.py.  The extractor is heuristic, so
#  these assert key invariants against the live specs: that named public
#  entities are captured, multi-line signatures stay intact, and nothing
#  from the private part leaks.  Stdlib unittest only.
#
#  Run:  python3 scripts/test-gen-reference.py   (or via tests/run-tests.sh)

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "src"

spec = importlib.util.spec_from_file_location("gen_reference",
                                              HERE / "gen-reference.py")
gr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gr)


def decls_of(spec_name):
    pkg, overview, decls = gr.parse_spec(SRC / spec_name)
    return pkg, overview, decls


class PublicSurface(unittest.TestCase):

    def test_execute_use_signature_intact(self):
        _, _, decls = decls_of("sdata_core-commands.ads")
        use = [s for k, s, _ in decls if k == "routine"
               and s.lstrip().startswith("procedure Execute_USE")]
        self.assertEqual(len(use), 1, "Execute_USE not captured exactly once")
        # multi-line signature must keep its parameters
        self.assertIn("File_Name", use[0])
        self.assertIn("Read_Header", use[0])
        self.assertTrue(use[0].rstrip().endswith(";"))

    def test_parse_expression_present(self):
        _, _, decls = decls_of("sdata_core-evaluator.ads")
        names = " ".join(s for _, s, _ in decls)
        self.assertIn("Parse_Expression", names)

    def test_values_objects_and_exception(self):
        _, _, decls = decls_of("sdata_core-values.ads")
        kinds = {}
        for k, s, _ in decls:
            kinds.setdefault(k, []).append(s)
        joined = " ".join(s for _, s, _ in decls)
        self.assertIn("Pos_Inf", joined)
        self.assertIn("Neg_Inf", joined)
        self.assertTrue(any("Conversion_Error" in s
                            for s in kinds.get("exception", [])),
                        "Conversion_Error not classified as an exception")
        # operator functions
        self.assertTrue(any('"="' in s for s in kinds.get("routine", [])))

    def test_no_private_state_leaks(self):
        # Config.Runtime keeps its mutable state in the private part.
        _, _, decls = decls_of("sdata_core-config-runtime.ads")
        joined = " ".join(s for _, s, _ in decls)
        self.assertNotIn("_Value", joined,
                         "private *_Value state leaked past `private`")
        # public part is accessor functions / lifecycle procedures
        self.assertIn("Save_File_Path", joined)

    def test_default_scope_is_public_contract(self):
        for name in gr.PUBLIC_PACKAGES:
            self.assertTrue((SRC / name).exists(),
                            f"public-contract spec missing: {name}")

    def test_trailing_comment_is_doc_not_merged(self):
        # A signature with a trailing `-- comment` must not swallow the next
        # declaration, must render without the comment, and must surface the
        # comment as documentation.
        _, _, decls = decls_of("sdata_core-statistics.ads")
        zc = [(s, d) for k, s, d in decls if "function Z_CDF" in s]
        self.assertEqual(len(zc), 1, "Z_CDF not captured exactly once")
        sig, doc = zc[0]
        self.assertNotIn("Z_IDF", sig, "Z_CDF swallowed the following decl")
        self.assertNotIn("--", sig, "trailing comment leaked into signature")
        self.assertTrue(any("CDF" in d for d in doc),
                        "trailing comment not surfaced as doc")
        # The package documents ~50 routines; a merge bug would slash this.
        routines = [s for k, s, _ in decls if k == "routine"]
        self.assertGreaterEqual(len(routines), 45)

    def test_overview_strips_license(self):
        _, overview, _ = decls_of("sdata_core-commands.ads")
        text = " ".join(overview)
        self.assertNotIn("Copyright", text)
        self.assertIn("execution procedures", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
