--  Exercises the aggregate metadata side-table added for the AGGREGATE
--  command (SData_Core.Evaluator.Is_Aggregate / Lookup, per ADR-046 /
--  architect C1).  Verifies that:
--    1. Every registered aggregate is recognised by Is_Aggregate.
--    2. A non-aggregate function (SQRT) is NOT recognised.
--    3. Lookup returns the correct Accepts_Numeric / Accepts_Character flags
--       (N and NMISS accept character; all others are numeric-only).
--    4. Lookup on an unknown name raises SData_Core.Script_Error.
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;          use Ada.Text_IO;
with Ada.Command_Line;
with SData_Core;
with SData_Core.Evaluator; use SData_Core.Evaluator;

procedure Aggregate_Meta_Test is

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

   Numeric_Only : constant array (Positive range <>) of access constant String :=
     (new String'("SUM"), new String'("MEAN"), new String'("STD"),
      new String'("VAR"), new String'("MIN"), new String'("MAX"),
      new String'("GMEAN"), new String'("HMEAN"), new String'("MEDIAN"));

begin
   Put_Line ("=== Aggregate_Meta_Test ===");

   --  1. Recognition (case-insensitive).
   Assert (Is_Aggregate ("sum"),    "Is_Aggregate(""sum"")");
   Assert (Is_Aggregate ("MEDIAN"), "Is_Aggregate(""MEDIAN"")");
   Assert (Is_Aggregate ("NmIsS"),  "Is_Aggregate(""NmIsS"")");

   --  2. Non-aggregate rejected.
   Assert (not Is_Aggregate ("sqrt"), "not Is_Aggregate(""sqrt"")");
   Assert (not Is_Aggregate ("len$"), "not Is_Aggregate(""len$"")");

   --  3a. N and NMISS accept both numeric and character.
   Assert (Lookup ("N").Accepts_Numeric,       "N accepts numeric");
   Assert (Lookup ("N").Accepts_Character,     "N accepts character");
   Assert (Lookup ("nmiss").Accepts_Numeric,   "NMISS accepts numeric");
   Assert (Lookup ("nmiss").Accepts_Character, "NMISS accepts character");

   --  3b. All other aggregates are numeric-only and all resolve.
   for P of Numeric_Only loop
      Assert (Lookup (P.all).Accepts_Numeric,
              "Lookup(""" & P.all & """).Accepts_Numeric");
      Assert (not Lookup (P.all).Accepts_Character,
              "not Lookup(""" & P.all & """).Accepts_Character");
   end loop;

   --  4. Unknown name raises Script_Error.
   declare
      M : Aggregate_Metadata;
   begin
      M := Lookup ("NOSUCH_AGG");
      Failed := Failed + 1;
      Put_Line ("  FAIL: Lookup(""NOSUCH_AGG"") should have raised (got "
                & M.Accepts_Numeric'Image & ")");
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
end Aggregate_Meta_Test;
