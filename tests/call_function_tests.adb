--  Exercises SData_Core.Evaluator.Call_Function (documented as a
--  "thin shim for unit tests") against one representative function
--  from each registered family.  Verifies that:
--    1. Each family's Register procedure was reached during elaboration
--       (functions show up in the dispatch table).
--    2. Argument marshalling Value_Array -> Vector works.
--    3. An unknown name surfaces as SData_Core.Script_Error.
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;           use Ada.Text_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core;
with SData_Core.Evaluator;  use SData_Core.Evaluator;
with SData_Core.Values;     use SData_Core.Values;
with Test_Support;          use Test_Support;

procedure Call_Function_Tests is

   No_Args : constant Value_Array (1 .. 0) := (others => (Kind => Val_Missing));

begin
   Put_Line ("=== Call_Function_Tests ===");

   --  Numeric family (Numeric_Fns)
   Assert (Near (Call_Function ("SQRT", (1 => Num (4.0))),  2.0), "SQRT(4) = 2");
   Assert (Near (Call_Function ("SQRT", (1 => I (9))),    3.0), "SQRT(9 as Integer) = 3");
   Assert (Near (Call_Function ("ABS",  (1 => Num (-3.0))), 3.0), "ABS(-3.0) = 3.0");
   Assert (Near (Call_Function ("ABS",  (1 => I (-7))),   7.0), "ABS(-7 as Integer)");

   --  String family (String_Fns)
   declare
      R : constant Value := Call_Function ("UPPER$", (1 => Str ("abc")));
   begin
      Assert (R.Kind = Val_String
              and then To_String (R.Str_Val) = "ABC",
              "UPPER$('abc') = 'ABC'");
   end;
   declare
      R : constant Value := Call_Function ("LEN", (1 => Str ("hello")));
   begin
      Assert (Near (R, 5.0), "LEN('hello') = 5");
   end;

   --  Aggregate family (Aggregate_Fns) — multi-arg dispatch
   Assert (Near (Call_Function ("SUM", (Num (1.0), Num (2.0), Num (3.0))), 6.0),
           "SUM(1, 2, 3) = 6");
   Assert (Near (Call_Function ("MEAN", (Num (2.0), Num (4.0), Num (6.0))), 4.0),
           "MEAN(2, 4, 6) = 4");
   Assert (Near (Call_Function ("MIN", (Num (3.0), Num (1.0), Num (2.0))), 1.0),
           "MIN(3, 1, 2) = 1");
   Assert (Near (Call_Function ("MAX", (Num (3.0), Num (1.0), Num (2.0))), 3.0),
           "MAX(3, 1, 2) = 3");

   --  Misc family — zero-arg constant
   Assert (Near (Call_Function ("PI", No_Args), 3.14159, 0.001),
           "PI() approximately 3.14159");

   --  Unknown function name must raise Script_Error
   declare
      R : Value;
   begin
      R := Call_Function ("NOSUCH_FN", (1 => Num (0.0)));
      Assert (False, "NOSUCH_FN should have raised Script_Error (got "
                      & To_String (R) & ")");
   exception
      when SData_Core.Script_Error =>
         Assert (True, "NOSUCH_FN raises Script_Error");
   end;

   Report_And_Exit;
end Call_Function_Tests;
