--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

private package SData_Core.Evaluator.Nav_Fns is
   procedure Register;

   --  Called by SData_Core.Evaluator.Set_Group_Boundary before each record.
   --  Sets the values returned by BOG() and EOG() during that record's
   --  expression evaluation.
   procedure Set_Boundary (BOG, EOG : Boolean);
end SData_Core.Evaluator.Nav_Fns;