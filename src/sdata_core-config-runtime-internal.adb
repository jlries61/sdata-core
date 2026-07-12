--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

package body SData_Core.Config.Runtime.Internal is

   procedure Set_Save_File_Path (Value : String) is
   begin
      Save_File_Path_Value                       := (others => ' ');
      Save_File_Path_Value (1 .. Value'Length)   := Value;
      Save_File_Len_Value                        := Value'Length;
   end Set_Save_File_Path;

   procedure Clear_Save_File_Path is
   begin
      Save_File_Path_Value := (others => ' ');
      Save_File_Len_Value  := 0;
   end Clear_Save_File_Path;

   procedure Set_Save_File_Fmt (Value : SData_Core.Config.Format_Type) is
   begin
      Save_File_Fmt_Value := Value;
   end Set_Save_File_Fmt;

   procedure Set_Save_File_Active (Value : Boolean) is
   begin
      Save_File_Active_Value := Value;
   end Set_Save_File_Active;

   procedure Set_Save_Sheet_Name (Value : String) is
   begin
      Save_Sheet_Name_Value                     := (others => ' ');
      Save_Sheet_Name_Value (1 .. Value'Length) := Value;
      Save_Sheet_Name_Len_Value                 := Value'Length;
   end Set_Save_Sheet_Name;

   procedure Set_Save_DLM (Value : String) is
   begin
      Save_DLM_Value := (others => ' ');
      if Value'Length > 0 then
         Save_DLM_Value (1 .. Value'Length) := Value;
         Save_DLM_Len_Value                 := Value'Length;
      else
         Save_DLM_Value (1) := ',';
         Save_DLM_Len_Value := 1;
      end if;
   end Set_Save_DLM;

   procedure Set_Save_Header (Value : Boolean) is
   begin
      Save_Header_Value := Value;
   end Set_Save_Header;

   procedure Set_Save_Charset (Value : String) is
   begin
      Save_Charset_Value                     := (others => ' ');
      Save_Charset_Value (1 .. Value'Length) := Value;
      Save_Charset_Len_Value                 := Value'Length;
   end Set_Save_Charset;

   procedure Set_Save_Decimals (Value : Integer) is
   begin
      Save_Decimals_Value := Value;
   end Set_Save_Decimals;

   procedure Set_Output_Table_Path (Value : String) is
   begin
      Output_Table_Path_Value                     := (others => ' ');
      Output_Table_Path_Value (1 .. Value'Length) := Value;
      Output_Table_Len_Value                      := Value'Length;
   end Set_Output_Table_Path;

   procedure Set_Output_Table_Fmt (Value : SData_Core.Config.Format_Type) is
   begin
      Output_Table_Fmt_Value := Value;
   end Set_Output_Table_Fmt;

   procedure Set_Output_Table_Active (Value : Boolean) is
   begin
      Output_Table_Active_Value := Value;
   end Set_Output_Table_Active;

   procedure Set_Repeat (Count : Natural) is
   begin
      Repeat_Active_Value := True;
      Repeat_Count_Value  := Count;
   end Set_Repeat;

   procedure Set_FPath_Use (Value : Unbounded_String) is
   begin
      FPath_Use_Value := Value;
   end Set_FPath_Use;

   procedure Set_FPath_Save (Value : Unbounded_String) is
   begin
      FPath_Save_Value := Value;
   end Set_FPath_Save;

   procedure Set_FPath_Submit (Value : Unbounded_String) is
   begin
      FPath_Submit_Value := Value;
   end Set_FPath_Submit;

   procedure Set_FPath_Output (Value : Unbounded_String) is
   begin
      FPath_Output_Value := Value;
   end Set_FPath_Output;

   procedure Set_Options_CSVDLM (Value : String) is
   begin
      Options_CSVDLM_Value                     := (others => ' ');
      Options_CSVDLM_Value (1 .. Value'Length) := Value;
      Options_CSVDLM_Len_Value                 := Value'Length;
   end Set_Options_CSVDLM;

   procedure Set_Options_Header (Value : Boolean) is
   begin
      Options_Header_Value := Value;
   end Set_Options_Header;

   procedure Set_Options_SAVEOVERWRT (Value : Boolean) is
   begin
      Options_SAVEOVERWRT_Value := Value;
   end Set_Options_SAVEOVERWRT;

   procedure Set_Options_Warn_Reserved (Value : Boolean) is
   begin
      Options_Warn_Reserved_Value := Value;
   end Set_Options_Warn_Reserved;

   procedure Set_Options_TXTFMT (Value : String) is
   begin
      Options_TXTFMT_Value                     := (others => ' ');
      Options_TXTFMT_Value (1 .. Value'Length) := Value;
      Options_TXTFMT_Len_Value                 := Value'Length;
   end Set_Options_TXTFMT;

   procedure Set_Options_CHARSET (Value : String) is
   begin
      Options_CHARSET_Value                     := (others => ' ');
      Options_CHARSET_Value (1 .. Value'Length) := Value;
      Options_CHARSET_Len_Value                 := Value'Length;
   end Set_Options_CHARSET;

   procedure Set_IEEE_Divide (Value : Boolean) is
   begin
      IEEE_Divide_Value := Value;
   end Set_IEEE_Divide;

   procedure Set_Options_Shell_Timeout (Value : Natural) is
   begin
      Options_Shell_Timeout_Value := Value;
   end Set_Options_Shell_Timeout;

   procedure Set_Options_Join_Warn_Threshold (Value : Natural) is
   begin
      Options_Join_Warn_Threshold_Value := Value;
   end Set_Options_Join_Warn_Threshold;

   procedure Set_Last_Error (Code : Natural; Line : Natural) is
   begin
      Last_Error_Code_Value := Code;
      Last_Error_Line_Value := Line;
   end Set_Last_Error;

   procedure Set_Select_Filter
     (Expr : SData_Core.Evaluator.Expression_Access)
   is
   begin
      Select_Filter_Expr_Value := Expr;
   end Set_Select_Filter;

end SData_Core.Config.Runtime.Internal;
