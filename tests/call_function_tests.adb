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
with Ada.Command_Line;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core;
with SData_Core.Evaluator;  use SData_Core.Evaluator;
with SData_Core.Values;     use SData_Core.Values;

procedure Call_Function_Tests is

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

   function N (X : Real)    return Value is ((Kind => Val_Numeric, Num_Val => X));
   function I (X : Int)     return Value is ((Kind => Val_Integer, Int_Val => X));
   function S (T : String)  return Value is
      ((Kind => Val_String, Str_Val => To_Unbounded_String (T)));

   function Near (R : Value; Expected : Real; Eps : Real := 1.0e-6)
      return Boolean is
   begin
      if R.Kind = Val_Numeric then
         return abs (R.Num_Val - Expected) <= Eps;
      elsif R.Kind = Val_Integer then
         return abs (Real (R.Int_Val) - Expected) <= Eps;
      end if;
      return False;
   end Near;

   No_Args : constant Value_Array (1 .. 0) := (others => (Kind => Val_Missing));

begin
   Put_Line ("=== Call_Function_Tests ===");

   --  Numeric family (Numeric_Fns)
   Assert (Near (Call_Function ("SQRT", (1 => N (4.0))),  2.0), "SQRT(4) = 2");
   Assert (Near (Call_Function ("SQRT", (1 => I (9))),    3.0), "SQRT(9 as Integer) = 3");
   Assert (Near (Call_Function ("ABS",  (1 => N (-3.0))), 3.0), "ABS(-3.0) = 3.0");
   Assert (Near (Call_Function ("ABS",  (1 => I (-7))),   7.0), "ABS(-7 as Integer)");

   --  String family (String_Fns)
   declare
      R : constant Value := Call_Function ("UPPER$", (1 => S ("abc")));
   begin
      Assert (R.Kind = Val_String
              and then To_String (R.Str_Val) = "ABC",
              "UPPER$('abc') = 'ABC'");
   end;
   declare
      R : constant Value := Call_Function ("LEN", (1 => S ("hello")));
   begin
      Assert (Near (R, 5.0), "LEN('hello') = 5");
   end;

   --  Aggregate family (Aggregate_Fns) — multi-arg dispatch
   Assert (Near (Call_Function ("SUM", (N (1.0), N (2.0), N (3.0))), 6.0),
           "SUM(1, 2, 3) = 6");
   Assert (Near (Call_Function ("MEAN", (N (2.0), N (4.0), N (6.0))), 4.0),
           "MEAN(2, 4, 6) = 4");
   Assert (Near (Call_Function ("MIN", (N (3.0), N (1.0), N (2.0))), 1.0),
           "MIN(3, 1, 2) = 1");
   Assert (Near (Call_Function ("MAX", (N (3.0), N (1.0), N (2.0))), 3.0),
           "MAX(3, 1, 2) = 3");

   --  Misc family — zero-arg constant
   Assert (Near (Call_Function ("PI", No_Args), 3.14159, 0.001),
           "PI() approximately 3.14159");

   --  Unknown function name must raise Script_Error
   declare
      R : Value;
   begin
      R := Call_Function ("NOSUCH_FN", (1 => N (0.0)));
      Failed := Failed + 1;
      Put_Line ("  FAIL: NOSUCH_FN should have raised Script_Error (got "
                & To_String (R) & ")");
   exception
      when SData_Core.Script_Error =>
         Passed := Passed + 1;
   end;

   --  Summary
   New_Line;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Call_Function_Tests;
