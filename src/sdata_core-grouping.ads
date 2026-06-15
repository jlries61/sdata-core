--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  SData_Core.Grouping holds the BY-group state: the active BY-variable names
--  and the same-group test.  In_Same_Group reads cell values via
--  Columns.Column_Maps + the Backing_Store directly -- it does NOT with Table
--  (sec 4.4).  The BY-var list is package-level state, mirroring the prior
--  Table_By_Vars singleton.

with SData_Core.Columns;
with SData_Core.Backing_Store;

package SData_Core.Grouping is

   procedure Clear_By_Vars;
   procedure Add_By_Var (Name : String);
   function  By_Var_Count return Natural;
   function  By_Var_Name (I : Positive) return String;

   --  True iff rows Idx1 and Idx2 share all BY-var values (empty BY => always
   --  True; equal indices => True; out-of-range => False).  Reads cells from T
   --  (live segment) or Store (spilled), exactly as the old Get_Value_Upper.
   function In_Same_Group
     (Idx1, Idx2    : Positive;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Boolean;

end SData_Core.Grouping;
