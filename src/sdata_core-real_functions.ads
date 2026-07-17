--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Elementary math functions (Sqrt, Log, Exp, Sin, "**", etc.) instantiated for
--  the interpreter's Real type.  Real is a distinct 'digits 15' type, so the
--  predefined Ada.Numerics.Elementary_Functions (which is for Float) no longer
--  applies; this instantiation replaces it across the evaluator.

with Ada.Numerics.Generic_Elementary_Functions;
with SData_Core.Values;

package SData_Core.Real_Functions is
   new Ada.Numerics.Generic_Elementary_Functions (SData_Core.Values.Real);
