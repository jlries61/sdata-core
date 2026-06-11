--  Exercises the Runtime-stateful command surface of SData_Core.Commands:
--  the OPTIONS setters (with their length validation), REPEAT, NEW,
--  Record_Error, and Resolve_Use_Defaults.  Each command is driven through
--  the public Execute_* entry points and read back through the
--  SData_Core.Config.Runtime accessor functions -- the seam the privatization
--  (audit item #5) finally made testable in isolation (Beck B2).
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Command_Line;
with SData_Core;
with SData_Core.Commands;
with SData_Core.Config.Runtime;

procedure Commands_Tests is

   package Rt renames SData_Core.Config.Runtime;
   package Cmd renames SData_Core.Commands;

   Passed, Failed : Natural := 0;
   Raised         : Boolean;

   procedure Assert (Condition : Boolean; Name : String) is
   begin
      if Condition then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("  FAIL: " & Name);
      end if;
   end Assert;

   --  Effective (trimmed) views of the padded string OPTIONS accessors.
   function CSVDLM return String is
     (Rt.Options_CSVDLM (1 .. Rt.Options_CSVDLM_Len));
   function TXTFMT return String is
     (Rt.Options_TXTFMT (1 .. Rt.Options_TXTFMT_Len));
   function CHARSET return String is
     (Rt.Options_CHARSET (1 .. Rt.Options_CHARSET_Len));

begin
   Put_Line ("=== Commands_Tests ===");

   --  Start from a known baseline.
   Cmd.Execute_NEW;

   ---------------------------------------------------------------------
   --  REPEAT set / clear.
   ---------------------------------------------------------------------
   Cmd.Execute_REPEAT (5);
   Assert (Rt.Repeat_Active, "REPEAT(5) sets Repeat_Active");
   Assert (Rt.Repeat_Count = 5, "REPEAT(5) sets Repeat_Count");
   Cmd.Execute_REPEAT (0);
   Assert (not Rt.Repeat_Active, "REPEAT(0) clears Repeat_Active");
   Assert (Rt.Repeat_Count = 0, "REPEAT(0) clears Repeat_Count");

   ---------------------------------------------------------------------
   --  OPTIONS CSVDLM: valid set, empty rejected, too-long rejected.
   ---------------------------------------------------------------------
   Cmd.Execute_OPTIONS_CSVDLM ("|");
   Assert (CSVDLM = "|", "OPTIONS CSVDLM sets delimiter");

   Raised := False;
   begin
      Cmd.Execute_OPTIONS_CSVDLM ("");
   exception
      when SData_Core.Script_Error => Raised := True;
   end;
   Assert (Raised, "OPTIONS CSVDLM empty raises Script_Error");

   Raised := False;
   begin
      Cmd.Execute_OPTIONS_CSVDLM
        ((1 .. SData_Core.Max_Delimiter_Len + 1 => 'x'));
   exception
      when SData_Core.Script_Error => Raised := True;
   end;
   Assert (Raised, "OPTIONS CSVDLM too-long raises Script_Error");
   Assert (CSVDLM = "|", "rejected CSVDLM leaves prior value intact");

   ---------------------------------------------------------------------
   --  OPTIONS TXTFMT: valid set, empty rejected, too-long rejected.
   ---------------------------------------------------------------------
   Cmd.Execute_OPTIONS_TXTFMT ("FIXED");
   Assert (TXTFMT = "FIXED", "OPTIONS TXTFMT sets value");

   Raised := False;
   begin
      Cmd.Execute_OPTIONS_TXTFMT ("");
   exception
      when SData_Core.Script_Error => Raised := True;
   end;
   Assert (Raised, "OPTIONS TXTFMT empty raises Script_Error");

   Raised := False;
   begin
      Cmd.Execute_OPTIONS_TXTFMT
        ((1 .. SData_Core.Max_Delimiter_Len + 1 => 'x'));
   exception
      when SData_Core.Script_Error => Raised := True;
   end;
   Assert (Raised, "OPTIONS TXTFMT too-long raises Script_Error");

   ---------------------------------------------------------------------
   --  OPTIONS CHARSET: valid set, empty allowed, too-long rejected.
   ---------------------------------------------------------------------
   Cmd.Execute_OPTIONS_CHARSET ("UTF-8");
   Assert (CHARSET = "UTF-8", "OPTIONS CHARSET sets value");

   Cmd.Execute_OPTIONS_CHARSET ("");
   Assert (CHARSET = "", "OPTIONS CHARSET empty is allowed (autodetect)");

   Raised := False;
   begin
      Cmd.Execute_OPTIONS_CHARSET
        ((1 .. SData_Core.Max_Charset_Len + 1 => 'x'));
   exception
      when SData_Core.Script_Error => Raised := True;
   end;
   Assert (Raised, "OPTIONS CHARSET too-long raises Script_Error");

   ---------------------------------------------------------------------
   --  Boolean / Natural OPTIONS round-trips.
   ---------------------------------------------------------------------
   Cmd.Execute_OPTIONS_Header (False);
   Assert (not Rt.Options_Header, "OPTIONS HEADER=NO round-trips");
   Cmd.Execute_OPTIONS_Header (True);
   Assert (Rt.Options_Header, "OPTIONS HEADER=YES round-trips");

   Cmd.Execute_OPTIONS_SAVEOVERWRT (False);
   Assert (not Rt.Options_SAVEOVERWRT, "OPTIONS SAVEOVERWRT round-trips");

   Cmd.Execute_OPTIONS_IEEE_Divide (True);
   Assert (Rt.IEEE_Divide, "OPTIONS IEEE_Divide round-trips");

   Cmd.Execute_OPTIONS_Shell_Timeout (30);
   Assert (Rt.Options_Shell_Timeout = 30, "OPTIONS SHELLTIMEOUT round-trips");

   Cmd.Execute_OPTIONS_Join_Warn_Threshold (250);
   Assert (Rt.Options_Join_Warn_Threshold = 250,
           "OPTIONS JOIN_WARN_THRESHOLD round-trips");

   ---------------------------------------------------------------------
   --  Record_Error round-trip.
   ---------------------------------------------------------------------
   Cmd.Execute_Record_Error (Code => 7, Line => 42);
   Assert (Rt.Last_Error_Code = 7, "Record_Error sets Last_Error_Code");
   Assert (Rt.Last_Error_Line = 42, "Record_Error sets Last_Error_Line");

   ---------------------------------------------------------------------
   --  Resolve_Use_Defaults: fall back to OPTIONS when not specified;
   --  pass the caller's value through when specified.
   ---------------------------------------------------------------------
   Cmd.Execute_OPTIONS_CSVDLM ("~");
   Cmd.Execute_OPTIONS_Header (False);
   Cmd.Execute_OPTIONS_CHARSET ("L1");
   declare
      R : constant Cmd.Use_Defaults := Cmd.Resolve_Use_Defaults;
   begin
      Assert (R.Delimiter (1 .. R.Delimiter_Len) = "~",
              "Resolve_Use_Defaults falls back to OPTIONS delimiter");
      Assert (not R.Read_Header,
              "Resolve_Use_Defaults falls back to OPTIONS header");
      Assert (R.Charset (1 .. R.Charset_Len) = "L1",
              "Resolve_Use_Defaults falls back to OPTIONS charset");
   end;
   declare
      R : constant Cmd.Use_Defaults :=
        Cmd.Resolve_Use_Defaults
          (Delimiter           => ";",
           Delimiter_Specified => True,
           Read_Header         => True,
           Header_Specified    => True,
           Charset             => "U8",
           Charset_Specified   => True);
   begin
      Assert (R.Delimiter (1 .. R.Delimiter_Len) = ";",
              "Resolve_Use_Defaults passes specified delimiter through");
      Assert (R.Read_Header,
              "Resolve_Use_Defaults passes specified header through");
      Assert (R.Charset (1 .. R.Charset_Len) = "U8",
              "Resolve_Use_Defaults passes specified charset through");
   end;

   ---------------------------------------------------------------------
   --  NEW resets all OPTIONS / REPEAT / error state to defaults.
   ---------------------------------------------------------------------
   Cmd.Execute_REPEAT (3);
   Cmd.Execute_Record_Error (Code => 9, Line => 9);
   Cmd.Execute_NEW;
   Assert (CSVDLM = ",", "NEW restores default CSVDLM");
   Assert (Rt.Options_Header, "NEW restores default HEADER");
   Assert (Rt.Options_SAVEOVERWRT, "NEW restores default SAVEOVERWRT");
   Assert (TXTFMT = "AUTO", "NEW restores default TXTFMT");
   Assert (CHARSET = "", "NEW restores default CHARSET");
   Assert (not Rt.IEEE_Divide, "NEW restores default IEEE_Divide");
   Assert (Rt.Options_Shell_Timeout = 0, "NEW restores default SHELLTIMEOUT");
   Assert (Rt.Options_Join_Warn_Threshold = 1_000_000,
           "NEW restores default JOIN_WARN_THRESHOLD");
   Assert (not Rt.Repeat_Active, "NEW clears Repeat_Active");
   Assert (Rt.Last_Error_Code = 0, "NEW clears Last_Error_Code");
   Assert (Rt.Last_Error_Line = 0, "NEW clears Last_Error_Line");

   --  Summary
   New_Line;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Commands_Tests;
