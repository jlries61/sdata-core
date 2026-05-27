--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

package body SData_Core.Config.Runtime is

   procedure Reset is
   begin
      Save_File_Path      := (others => ' ');
      Save_File_Len       := 0;
      Save_File_Active    := False;
      Save_File_Fmt       := SData_Core.Config.CSV;
      Save_Sheet_Name     := (others => ' ');
      Save_Sheet_Name_Len := 0;
      FPath_Use           := Null_Unbounded_String;
      FPath_Save          := Null_Unbounded_String;
      FPath_Submit        := Null_Unbounded_String;
      FPath_Output        := Null_Unbounded_String;
      Output_Table_Path   := (others => ' ');
      Output_Table_Len    := 0;
      Output_Table_Active := False;
      Output_Table_Fmt    := SData_Core.Config.CSV;
      Repeat_Count        := 0;
      Repeat_Active       := False;
      Last_Error_Code     := 0;
      Last_Error_Line     := 0;
      Options_CSVDLM     := (others => ' ');
      Options_CSVDLM (1) := ',';
      Options_CSVDLM_Len  := 1;
      Options_Header      := True;
      Options_SAVEOVERWRT := True;
      Options_TXTFMT      := (others => ' ');
      Options_TXTFMT (1 .. 4) := "AUTO";
      Options_TXTFMT_Len  := 4;
      Options_CHARSET     := (others => ' ');
      Options_CHARSET_Len := 0;
      IEEE_Divide         := False;
      Options_Shell_Timeout := SData_Core.Config.Shell_Timeout_Default;
      Save_DLM         := (others => ' ');
      Save_DLM (1)     := ',';
      Save_DLM_Len     := 1;
      Save_Header      := True;
      Save_Charset     := (others => ' ');
      Save_Charset_Len := 0;
      Clear_Select_Filter;
   end Reset;

   procedure Clear_Select_Filter is
   begin
      SData_Core.Evaluator.Free_Expression (Select_Filter_Expr);
   end Clear_Select_Filter;

end SData_Core.Config.Runtime;
