--  Exercises SData_Core.Commands.Execute_AGGREGATE end-to-end against a
--  programmatically-built table (per ADR-046 / architect C2).  Verifies:
--    1. One output row per consecutive BY group, with the BY value preserved.
--    2. SUM / MEAN / N over a scalar column produce the right values/types.
--    3. The active BY list is cleared afterward.
--    4. Validation errors (#4 unknown variable, #6 character type mismatch)
--       raise Script_Error and abort before mutating the table.
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with SData_Core;
with SData_Core.Commands;      use SData_Core.Commands;
with SData_Core.Table;
with SData_Core.Values;        use SData_Core.Values;

procedure Aggregate_Exec_Test is

   package Tbl renames SData_Core.Table;

   Passed, Failed : Natural := 0;

   procedure Assert (Condition : Boolean; Name : String) is
   begin
      if Condition then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("  FAIL: " & Name);
      end if;
   end Assert;

   function Num (X : Real)    return Value is ((Kind => Val_Numeric, Num_Val => X));

   function Near (R : Value; Expected : Real) return Boolean is
     (R.Kind = Val_Numeric and then abs (R.Num_Val - Expected) <= 1.0e-6);

   function Spec (Outvar, Fn : String;
                  Kind : Aggregate_Invar_Kind;
                  Invar : String := "";
                  Index : Natural := 0) return Aggregate_Spec is
     (Outvar      => To_Unbounded_String (Outvar),
      Fn_Name     => To_Unbounded_String (Fn),
      Invar_Kind  => Kind,
      Invar_Name  => To_Unbounded_String (Invar),
      Invar_Index => Index);

   --  Build the fixture table: G = (1,1,2), X = (10,20,30), grouped by G.
   procedure Build_Fixture is
   begin
      Tbl.Clear;
      SData_Core.Commands.Execute_NEW;
      Tbl.Add_Column ("G", Tbl.Col_Numeric);
      Tbl.Add_Column ("X", Tbl.Col_Numeric);
      for R in 1 .. 3 loop
         Tbl.Add_Row;
      end loop;
      Tbl.Set_Value (1, "G", Num (1.0)); Tbl.Set_Value (1, "X", Num (10.0));
      Tbl.Set_Value (2, "G", Num (1.0)); Tbl.Set_Value (2, "X", Num (20.0));
      Tbl.Set_Value (3, "G", Num (2.0)); Tbl.Set_Value (3, "X", Num (30.0));
      Tbl.Clear_By_Vars;
      Tbl.Add_By_Var ("G");
   end Build_Fixture;

   Specs  : Aggregate_Spec_Vectors.Vector;
   Raised : Boolean;

begin
   Put_Line ("=== Aggregate_Exec_Test ===");

   ---------------------------------------------------------------------
   --  Happy path: total=SUM(X)  avg=MEAN(X)  n=N()  grouped by G.
   ---------------------------------------------------------------------
   Build_Fixture;
   Specs.Clear;
   Specs.Append (Spec ("total", "SUM",  Invar_Scalar, "X"));
   Specs.Append (Spec ("avg",   "MEAN", Invar_Scalar, "X"));
   Specs.Append (Spec ("n",     "N",    Invar_Empty));
   Execute_AGGREGATE (Specs);

   --  Column names are normalised to upper case by the table layer.
   Assert (Tbl.Column_Count = 4, "schema: G,total,avg,n");
   Assert (Tbl.Column_Name (1) = "G",     "col 1 = G");
   Assert (Tbl.Column_Name (2) = "TOTAL", "col 2 = TOTAL");
   Assert (Tbl.Column_Name (3) = "AVG",   "col 3 = AVG");
   Assert (Tbl.Column_Name (4) = "N",     "col 4 = N");
   Assert (Tbl.Row_Count = 2, "two groups -> two rows");

   --  Group 1 (G=1): SUM=30, MEAN=15, N=2.
   Assert (Near (Tbl.Get_Value (1, "G"), 1.0),     "row1 G=1");
   Assert (Near (Tbl.Get_Value (1, "total"), 30.0), "row1 total=30");
   Assert (Near (Tbl.Get_Value (1, "avg"), 15.0),   "row1 avg=15");
   Assert (Tbl.Get_Value (1, "n").Kind = Val_Integer
           and then Tbl.Get_Value (1, "n").Int_Val = 2, "row1 n=2 (integer)");

   --  Group 2 (G=2): SUM=30, MEAN=30, N=1.
   Assert (Near (Tbl.Get_Value (2, "G"), 2.0),     "row2 G=2");
   Assert (Near (Tbl.Get_Value (2, "total"), 30.0), "row2 total=30");
   Assert (Near (Tbl.Get_Value (2, "avg"), 30.0),   "row2 avg=30");
   Assert (Tbl.Get_Value (2, "n").Kind = Val_Integer
           and then Tbl.Get_Value (2, "n").Int_Val = 1, "row2 n=1 (integer)");

   --  BY list consumed.
   Assert (Tbl.By_Var_Count = 0, "BY cleared after AGGREGATE");

   ---------------------------------------------------------------------
   --  #4 unknown variable aborts without mutating the table.
   ---------------------------------------------------------------------
   Build_Fixture;
   Specs.Clear;
   Specs.Append (Spec ("bad", "SUM", Invar_Scalar, "NOSUCHCOL"));
   Raised := False;
   begin
      Execute_AGGREGATE (Specs);
   exception
      when SData_Core.Script_Error =>
         Raised := True;
   end;
   Assert (Raised, "#4: unknown variable raises Script_Error");
   --  Table is still the 3-row fixture (G,X), BY still active.
   Assert (Tbl.Column_Count = 2 and then Tbl.Row_Count = 3,
           "#4: table untouched after unknown-variable error");
   Assert (Tbl.By_Var_Count = 1, "#4: BY still active after error");

   ---------------------------------------------------------------------
   --  #6 character type mismatch (MIN on a string column).
   ---------------------------------------------------------------------
   Tbl.Clear;
   SData_Core.Commands.Execute_NEW;
   Tbl.Add_Column ("S", Tbl.Col_String);
   Tbl.Add_Row;
   Tbl.Set_Value (1, "S", (Kind => Val_String,
                           Str_Val => To_Unbounded_String ("hi")));
   Specs.Clear;
   Specs.Append (Spec ("m", "MIN", Invar_Scalar, "S"));
   Raised := False;
   begin
      Execute_AGGREGATE (Specs);
   exception
      when SData_Core.Script_Error =>
         Raised := True;
   end;
   Assert (Raised, "#6: character type mismatch raises Script_Error");
   Assert (Tbl.Column_Count = 1, "#6: table untouched after type-mismatch error");

   --  Summary
   New_Line;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Aggregate_Exec_Test;
