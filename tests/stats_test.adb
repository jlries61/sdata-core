--  Exercises SData_Core.Commands.Execute_STATS end-to-end against a
--  programmatically-built table. Verifies:
--    1. Explicit /VAR + stat list, no BY: one row per variable, one column
--       per requested statistic.
--    2. Default /VAR (all numeric minus BY) with an active BY: one row per
--       (group x variable).
--    3. Validation errors (unknown variable; numeric-only statistic applied
--       to a character variable) raise Script_Error and abort before
--       mutating the table.
--
--  Stat lists deliberately avoid STD in every case: STD's numeric
--  correctness is already covered by statistics_tests.adb (the pure
--  SData_Core.Statistics math); this driver's job is the Runtime-stateful
--  command seam (schema building, group scanning, error handling), not
--  re-verifying aggregate-function math.
--
--  Plain inline assertions; no framework. Fills the gap noted at
--  .ssd/milestones/2026-07-23-post-decomposition-baseline/skeptic-before.md
--  (M2-BECK-1, corrected mid-remediation): Execute_STATS is a direct
--  sibling of Execute_AGGREGATE/Execute_TRANSPOSE but, unlike AGGREGATE,
--  had no in-crate driver -- statistics_tests.adb covers the underlying
--  math, not the command procedure itself.

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Exceptions;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with SData_Core;
with SData_Core.Commands;      use SData_Core.Commands;
with SData_Core.Table;
with SData_Core.Values;        use SData_Core.Values;
with Test_Support;             use Test_Support;

procedure Stats_Test is

   package Tbl renames SData_Core.Table;

   function Is_Int (R : Value; Expected : Integer) return Boolean is
     (R.Kind = Val_Integer and then R.Int_Val = Int (Expected));

   Opts   : Stats_Options;
   Raised : Boolean;

begin
   Put_Line ("=== Stats_Test ===");

   ---------------------------------------------------------------------
   --  Happy path: no BY, explicit /VAR=(X Y) /STATS=(N MIN MEAN MAX).
   ---------------------------------------------------------------------
   Tbl.Clear;
   SData_Core.Commands.Execute_NEW;
   Tbl.Add_Column ("X", Tbl.Col_Numeric);
   Tbl.Add_Column ("Y", Tbl.Col_Numeric);
   Tbl.Add_Row; Tbl.Set_Value (1, "X", Num (10.0)); Tbl.Set_Value (1, "Y", Num (1.0));
   Tbl.Add_Row; Tbl.Set_Value (2, "X", Num (20.0)); Tbl.Set_Value (2, "Y", Num (2.0));
   Tbl.Add_Row; Tbl.Set_Value (3, "X", Num (30.0)); Tbl.Set_Value (3, "Y", Num (3.0));

   Opts.Var_List.Clear;  Opts.Var_List.Append (To_Unbounded_String ("X"));
   Opts.Var_List.Append (To_Unbounded_String ("Y"));
   Opts.Stat_List.Clear;
   Opts.Stat_List.Append (To_Unbounded_String ("N"));
   Opts.Stat_List.Append (To_Unbounded_String ("MIN"));
   Opts.Stat_List.Append (To_Unbounded_String ("MEAN"));
   Opts.Stat_List.Append (To_Unbounded_String ("MAX"));
   Execute_STATS (Opts);

   Assert (Tbl.Column_Count = 5, "no-BY: schema _NAME_$,N,MIN,MEAN,MAX");
   Assert (Tbl.Column_Name (1) = "_NAME_$", "no-BY: col 1 = _NAME_$");
   Assert (Tbl.Column_Name (2) = "N",       "no-BY: col 2 = N");
   Assert (Tbl.Column_Name (3) = "MIN",     "no-BY: col 3 = MIN");
   Assert (Tbl.Column_Name (4) = "MEAN",    "no-BY: col 4 = MEAN");
   Assert (Tbl.Column_Name (5) = "MAX",     "no-BY: col 5 = MAX");
   Assert (Tbl.Row_Count = 2, "no-BY: two variables -> two rows");

   Assert (Tbl.Get_Value (1, "_NAME_$").Str_Val = To_Unbounded_String ("X"),
           "no-BY: row1 name = X");
   Assert (Is_Int (Tbl.Get_Value (1, "N"), 3), "no-BY: row1 N=3 (integer)");
   Assert (Near (Tbl.Get_Value (1, "MIN"), 10.0),  "no-BY: row1 MIN=10");
   Assert (Near (Tbl.Get_Value (1, "MEAN"), 20.0), "no-BY: row1 MEAN=20");
   Assert (Near (Tbl.Get_Value (1, "MAX"), 30.0),  "no-BY: row1 MAX=30");

   Assert (Tbl.Get_Value (2, "_NAME_$").Str_Val = To_Unbounded_String ("Y"),
           "no-BY: row2 name = Y");
   Assert (Is_Int (Tbl.Get_Value (2, "N"), 3), "no-BY: row2 N=3 (integer)");
   Assert (Near (Tbl.Get_Value (2, "MIN"), 1.0),  "no-BY: row2 MIN=1");
   Assert (Near (Tbl.Get_Value (2, "MEAN"), 2.0), "no-BY: row2 MEAN=2");
   Assert (Near (Tbl.Get_Value (2, "MAX"), 3.0),  "no-BY: row2 MAX=3");

   ---------------------------------------------------------------------
   --  Happy path: BY=G, default /VAR (all numeric minus BY), /STATS=(N MEAN).
   ---------------------------------------------------------------------
   Tbl.Clear;
   SData_Core.Commands.Execute_NEW;
   Tbl.Add_Column ("G", Tbl.Col_Numeric);
   Tbl.Add_Column ("X", Tbl.Col_Numeric);
   Tbl.Add_Row; Tbl.Set_Value (1, "G", Num (1.0)); Tbl.Set_Value (1, "X", Num (10.0));
   Tbl.Add_Row; Tbl.Set_Value (2, "G", Num (1.0)); Tbl.Set_Value (2, "X", Num (20.0));
   Tbl.Add_Row; Tbl.Set_Value (3, "G", Num (2.0)); Tbl.Set_Value (3, "X", Num (30.0));
   Tbl.Clear_By_Vars;
   Tbl.Add_By_Var ("G");

   Opts.Var_List.Clear;    --  default -> all numeric columns minus BY (= X only)
   Opts.Stat_List.Clear;
   Opts.Stat_List.Append (To_Unbounded_String ("N"));
   Opts.Stat_List.Append (To_Unbounded_String ("MEAN"));
   Execute_STATS (Opts);

   Assert (Tbl.Column_Count = 4, "BY: schema G,_NAME_$,N,MEAN");
   Assert (Tbl.Column_Name (1) = "G",       "BY: col 1 = G");
   Assert (Tbl.Column_Name (2) = "_NAME_$", "BY: col 2 = _NAME_$");
   Assert (Tbl.Column_Name (3) = "N",       "BY: col 3 = N");
   Assert (Tbl.Column_Name (4) = "MEAN",    "BY: col 4 = MEAN");
   Assert (Tbl.Row_Count = 2, "BY: two groups -> two rows (one var each)");

   Assert (Near (Tbl.Get_Value (1, "G"), 1.0), "BY: row1 G=1");
   Assert (Tbl.Get_Value (1, "_NAME_$").Str_Val = To_Unbounded_String ("X"),
           "BY: row1 name = X (only non-BY numeric column)");
   Assert (Is_Int (Tbl.Get_Value (1, "N"), 2),  "BY: row1 (G=1) N=2");
   Assert (Near (Tbl.Get_Value (1, "MEAN"), 15.0), "BY: row1 (G=1) MEAN=15");

   Assert (Near (Tbl.Get_Value (2, "G"), 2.0), "BY: row2 G=2");
   Assert (Is_Int (Tbl.Get_Value (2, "N"), 1),  "BY: row2 (G=2) N=1");
   Assert (Near (Tbl.Get_Value (2, "MEAN"), 30.0), "BY: row2 (G=2) MEAN=30");

   Assert (Tbl.By_Var_Count = 0, "BY cleared after STATS");

   ---------------------------------------------------------------------
   --  Error: unknown variable in /VAR aborts without mutating the table.
   ---------------------------------------------------------------------
   Tbl.Clear;
   SData_Core.Commands.Execute_NEW;
   Tbl.Add_Column ("N", Tbl.Col_Numeric);
   Tbl.Add_Row; Tbl.Set_Value (1, "N", Num (1.0));
   Tbl.Add_Row; Tbl.Set_Value (2, "N", Num (2.0));
   Tbl.Add_Row; Tbl.Set_Value (3, "N", Num (3.0));

   Opts.Var_List.Clear;  Opts.Var_List.Append (To_Unbounded_String ("NOSUCHCOL"));
   Opts.Stat_List.Clear; Opts.Stat_List.Append (To_Unbounded_String ("MEAN"));
   Raised := False;
   begin
      Execute_STATS (Opts);
   exception
      when E : SData_Core.Script_Error =>
         Raised := True;
         Assert (Ada.Exceptions.Exception_Message (E) =
                   "STATS: unknown variable 'NOSUCHCOL'",
                 "unknown-var: exact error message");
   end;
   Assert (Raised, "unknown-var: raises Script_Error");
   Assert (Tbl.Column_Count = 1 and then Tbl.Row_Count = 3,
           "unknown-var: table untouched after error");

   ---------------------------------------------------------------------
   --  Error: numeric-only statistic on a character variable.
   ---------------------------------------------------------------------
   Tbl.Clear;
   SData_Core.Commands.Execute_NEW;
   Tbl.Add_Column ("S", Tbl.Col_String);
   Tbl.Add_Row;
   Tbl.Set_Value (1, "S", (Kind => Val_String,
                           Str_Val => To_Unbounded_String ("hi")));

   Opts.Var_List.Clear;  Opts.Var_List.Append (To_Unbounded_String ("S"));
   Opts.Stat_List.Clear; Opts.Stat_List.Append (To_Unbounded_String ("MEAN"));
   Raised := False;
   begin
      Execute_STATS (Opts);
   exception
      when E : SData_Core.Script_Error =>
         Raised := True;
         Assert (Ada.Exceptions.Exception_Message (E) =
                   "STATS: statistic 'MEAN' cannot be applied to character variable 'S'",
                 "char-mismatch: exact error message");
   end;
   Assert (Raised, "char-mismatch: raises Script_Error");
   Assert (Tbl.Column_Count = 1, "char-mismatch: table untouched after error");

   Report_And_Exit;
end Stats_Test;
