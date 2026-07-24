--  Exercises SData_Core.Commands.Execute_TRANSPOSE end-to-end against a
--  programmatically-built table. Verifies:
--    1. Default /ARRAY: each transposed column becomes one row; _NAME_$
--       holds the source column name; _X_(1..N) hold its values in row
--       order.
--    2. /ID: each transposed column becomes one row; the /ID column's
--       values (upper-cased, per table normalization) become the output
--       column names.
--    3. Validation errors (#4 unknown /KEEP variable, #5 unknown /ID
--       column) raise Script_Error and abort before mutating the table.
--
--  Plain inline assertions; no framework. Fills the gap noted at
--  .ssd/milestones/2026-07-23-post-decomposition-baseline/skeptic-before.md
--  (M2-BECK-1): TRANSPOSE is a direct sibling of AGGREGATE/STATS but,
--  unlike them, had no in-crate driver.

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with SData_Core;
with SData_Core.Commands;      use SData_Core.Commands;
with SData_Core.Table;
with SData_Core.Values;        use SData_Core.Values;

procedure Transpose_Test is

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

   function Num (X : Real) return Value is ((Kind => Val_Numeric, Num_Val => X));

   function Str (S : String) return Value is
     ((Kind => Val_String, Str_Val => To_Unbounded_String (S)));

   function Near (R : Value; Expected : Real) return Boolean is
     (R.Kind = Val_Numeric and then abs (R.Num_Val - Expected) <= 1.0e-6);

   --  Build the fixture table: ID$ = (A,B,C), SCORE = (95,87,92),
   --  HEIGHT = (170,165,180) -- mirrors sdata's transpose_simple.csv
   --  fixture (tests/data/transpose_simple.csv) so this driver's
   --  expectations can be cross-checked against the consumer suite's
   --  transpose_basic.cmd / transpose_id.cmd.
   procedure Build_Fixture is
   begin
      Tbl.Clear;
      SData_Core.Commands.Execute_NEW;
      Tbl.Add_Column ("ID$", Tbl.Col_String);
      Tbl.Add_Column ("SCORE", Tbl.Col_Numeric);
      Tbl.Add_Column ("HEIGHT", Tbl.Col_Numeric);
      for R in 1 .. 3 loop
         Tbl.Add_Row;
      end loop;
      Tbl.Set_Value (1, "ID$", Str ("A"));
      Tbl.Set_Value (2, "ID$", Str ("B"));
      Tbl.Set_Value (3, "ID$", Str ("C"));
      Tbl.Set_Value (1, "SCORE", Num (95.0));
      Tbl.Set_Value (2, "SCORE", Num (87.0));
      Tbl.Set_Value (3, "SCORE", Num (92.0));
      Tbl.Set_Value (1, "HEIGHT", Num (170.0));
      Tbl.Set_Value (2, "HEIGHT", Num (165.0));
      Tbl.Set_Value (3, "HEIGHT", Num (180.0));
   end Build_Fixture;

   Opts   : Transpose_Options;
   Raised : Boolean;

begin
   Put_Line ("=== Transpose_Test ===");

   ---------------------------------------------------------------------
   --  Happy path: default /ARRAY, /DROP=id$.
   ---------------------------------------------------------------------
   Build_Fixture;
   Opts := (Keep_List  => Tbl.Name_Vectors.Empty_Vector,
            Drop_List  => Tbl.Name_Vectors.Empty_Vector,
            Name_Col   => Null_Unbounded_String,
            Id_Col     => Null_Unbounded_String,
            Array_Name => Null_Unbounded_String,
            Has_Id     => False,
            Has_Array  => False);
   Opts.Drop_List.Append (To_Unbounded_String ("id$"));
   Execute_TRANSPOSE (Opts);

   Assert (Tbl.Column_Count = 4, "default: schema _NAME_$,_X_(1),_X_(2),_X_(3)");
   Assert (Tbl.Column_Name (1) = "_NAME_$",  "default: col 1 = _NAME_$");
   Assert (Tbl.Column_Name (2) = "_X_(1)",   "default: col 2 = _X_(1)");
   Assert (Tbl.Column_Name (3) = "_X_(2)",   "default: col 3 = _X_(2)");
   Assert (Tbl.Column_Name (4) = "_X_(3)",   "default: col 4 = _X_(3)");
   Assert (Tbl.Row_Count = 2, "default: two transposed columns -> two rows");

   Assert (Tbl.Get_Value (1, "_NAME_$").Str_Val = To_Unbounded_String ("SCORE"),
           "default: row1 name = SCORE");
   Assert (Near (Tbl.Get_Value (1, "_X_(1)"), 95.0), "default: row1 _X_(1)=95");
   Assert (Near (Tbl.Get_Value (1, "_X_(2)"), 87.0), "default: row1 _X_(2)=87");
   Assert (Near (Tbl.Get_Value (1, "_X_(3)"), 92.0), "default: row1 _X_(3)=92");

   Assert (Tbl.Get_Value (2, "_NAME_$").Str_Val = To_Unbounded_String ("HEIGHT"),
           "default: row2 name = HEIGHT");
   Assert (Near (Tbl.Get_Value (2, "_X_(1)"), 170.0), "default: row2 _X_(1)=170");
   Assert (Near (Tbl.Get_Value (2, "_X_(2)"), 165.0), "default: row2 _X_(2)=165");
   Assert (Near (Tbl.Get_Value (2, "_X_(3)"), 180.0), "default: row2 _X_(3)=180");

   ---------------------------------------------------------------------
   --  Happy path: /ID=id$ -- output columns named A, B, C.
   ---------------------------------------------------------------------
   Build_Fixture;
   Opts := (Keep_List  => Tbl.Name_Vectors.Empty_Vector,
            Drop_List  => Tbl.Name_Vectors.Empty_Vector,
            Name_Col   => Null_Unbounded_String,
            Id_Col     => To_Unbounded_String ("ID$"),
            Array_Name => Null_Unbounded_String,
            Has_Id     => True,
            Has_Array  => False);
   Execute_TRANSPOSE (Opts);

   Assert (Tbl.Column_Count = 4, "/ID: schema _NAME_$,A,B,C");
   Assert (Tbl.Column_Name (1) = "_NAME_$", "/ID: col 1 = _NAME_$");
   Assert (Tbl.Column_Name (2) = "A",       "/ID: col 2 = A");
   Assert (Tbl.Column_Name (3) = "B",       "/ID: col 3 = B");
   Assert (Tbl.Column_Name (4) = "C",       "/ID: col 4 = C");
   Assert (Tbl.Row_Count = 2, "/ID: two transposed columns -> two rows");

   Assert (Near (Tbl.Get_Value (1, "A"), 95.0), "/ID: row1 (SCORE) A=95");
   Assert (Near (Tbl.Get_Value (1, "B"), 87.0), "/ID: row1 (SCORE) B=87");
   Assert (Near (Tbl.Get_Value (1, "C"), 92.0), "/ID: row1 (SCORE) C=92");
   Assert (Near (Tbl.Get_Value (2, "A"), 170.0), "/ID: row2 (HEIGHT) A=170");
   Assert (Near (Tbl.Get_Value (2, "B"), 165.0), "/ID: row2 (HEIGHT) B=165");
   Assert (Near (Tbl.Get_Value (2, "C"), 180.0), "/ID: row2 (HEIGHT) C=180");

   ---------------------------------------------------------------------
   --  #4: unknown variable in /KEEP aborts without mutating the table.
   ---------------------------------------------------------------------
   Build_Fixture;
   Opts := (Keep_List  => Tbl.Name_Vectors.Empty_Vector,
            Drop_List  => Tbl.Name_Vectors.Empty_Vector,
            Name_Col   => Null_Unbounded_String,
            Id_Col     => Null_Unbounded_String,
            Array_Name => Null_Unbounded_String,
            Has_Id     => False,
            Has_Array  => False);
   Opts.Keep_List.Append (To_Unbounded_String ("NOSUCHCOL"));
   Raised := False;
   begin
      Execute_TRANSPOSE (Opts);
   exception
      when E : SData_Core.Script_Error =>
         Raised := True;
         Assert (Ada.Exceptions.Exception_Message (E) =
                   "TRANSPOSE: unknown variable 'NOSUCHCOL' in /KEEP",
                 "#4: exact error message");
   end;
   Assert (Raised, "#4: unknown /KEEP variable raises Script_Error");
   Assert (Tbl.Column_Count = 3 and then Tbl.Row_Count = 3,
           "#4: table untouched after /KEEP error");

   ---------------------------------------------------------------------
   --  #5: unknown /ID column aborts without mutating the table.
   ---------------------------------------------------------------------
   Build_Fixture;
   Opts := (Keep_List  => Tbl.Name_Vectors.Empty_Vector,
            Drop_List  => Tbl.Name_Vectors.Empty_Vector,
            Name_Col   => Null_Unbounded_String,
            Id_Col     => To_Unbounded_String ("NOEXIST"),
            Array_Name => Null_Unbounded_String,
            Has_Id     => True,
            Has_Array  => False);
   Raised := False;
   begin
      Execute_TRANSPOSE (Opts);
   exception
      when E : SData_Core.Script_Error =>
         Raised := True;
         Assert (Ada.Exceptions.Exception_Message (E) =
                   "TRANSPOSE: /ID column 'NOEXIST' does not exist",
                 "#5: exact error message");
   end;
   Assert (Raised, "#5: unknown /ID column raises Script_Error");
   Assert (Tbl.Column_Count = 3 and then Tbl.Row_Count = 3,
           "#5: table untouched after /ID error");

   --  Summary
   New_Line;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Transpose_Test;
