--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

package body SData_Core.Config.Runtime is

   --  ---------------------------------------------------------------
   --  Read accessors — each returns the corresponding private state.

   function Save_File_Path      return String  is (Save_File_Path_Value);
   function Save_File_Len       return Natural is (Save_File_Len_Value);
   function Save_File_Active    return Boolean is (Save_File_Active_Value);
   function Save_File_Fmt       return SData_Core.Config.Format_Type is
     (Save_File_Fmt_Value);
   function Save_Sheet_Name     return String  is (Save_Sheet_Name_Value);
   function Save_Sheet_Name_Len return Natural is (Save_Sheet_Name_Len_Value);

   function FPath_Use    return Unbounded_String is (FPath_Use_Value);
   function FPath_Save   return Unbounded_String is (FPath_Save_Value);
   function FPath_Submit return Unbounded_String is (FPath_Submit_Value);
   function FPath_Output return Unbounded_String is (FPath_Output_Value);

   function Output_Table_Path   return String  is (Output_Table_Path_Value);
   function Output_Table_Len    return Natural is (Output_Table_Len_Value);
   function Output_Table_Active return Boolean is (Output_Table_Active_Value);
   function Output_Table_Fmt    return SData_Core.Config.Format_Type is
     (Output_Table_Fmt_Value);

   function Repeat_Count  return Natural is (Repeat_Count_Value);
   function Repeat_Active return Boolean is (Repeat_Active_Value);

   function Last_Error_Code return Natural is (Last_Error_Code_Value);
   function Last_Error_Line return Natural is (Last_Error_Line_Value);

   function Options_CSVDLM             return String  is (Options_CSVDLM_Value);
   function Options_CSVDLM_Len         return Natural is (Options_CSVDLM_Len_Value);
   function Options_Header             return Boolean is (Options_Header_Value);
   function Options_SAVEOVERWRT        return Boolean is (Options_SAVEOVERWRT_Value);
   function Options_Warn_Reserved      return Boolean is (Options_Warn_Reserved_Value);
   function Options_TXTFMT             return String  is (Options_TXTFMT_Value);
   function Options_TXTFMT_Len         return Natural is (Options_TXTFMT_Len_Value);
   function Options_CHARSET            return String  is (Options_CHARSET_Value);
   function Options_CHARSET_Len        return Natural is (Options_CHARSET_Len_Value);
   function IEEE_Divide                return Boolean is (IEEE_Divide_Value);
   function Options_Shell_Timeout      return Natural is (Options_Shell_Timeout_Value);
   function Options_Join_Warn_Threshold return Natural is
     (Options_Join_Warn_Threshold_Value);

   function Save_DLM         return String  is (Save_DLM_Value);
   function Save_DLM_Len     return Natural is (Save_DLM_Len_Value);
   function Save_Header      return Boolean is (Save_Header_Value);
   function Save_Charset     return String  is (Save_Charset_Value);
   function Save_Charset_Len return Natural is (Save_Charset_Len_Value);

   function Select_Filter_Expr return SData_Core.Evaluator.Expression_Access is
     (Select_Filter_Expr_Value);

   --  ---------------------------------------------------------------
   --  Lifecycle procedures.

   procedure Reset is
   begin
      Save_File_Path_Value      := (others => ' ');
      Save_File_Len_Value       := 0;
      Save_File_Active_Value    := False;
      Save_File_Fmt_Value       := SData_Core.Config.CSV;
      Save_Sheet_Name_Value     := (others => ' ');
      Save_Sheet_Name_Len_Value := 0;
      FPath_Use_Value           := Null_Unbounded_String;
      FPath_Save_Value          := Null_Unbounded_String;
      FPath_Submit_Value        := Null_Unbounded_String;
      FPath_Output_Value        := Null_Unbounded_String;
      Output_Table_Path_Value   := (others => ' ');
      Output_Table_Len_Value    := 0;
      Output_Table_Active_Value := False;
      Output_Table_Fmt_Value    := SData_Core.Config.CSV;
      Repeat_Count_Value        := 0;
      Repeat_Active_Value       := False;
      Last_Error_Code_Value     := 0;
      Last_Error_Line_Value     := 0;
      Options_CSVDLM_Value      := (others => ' ');
      Options_CSVDLM_Value (1)  := ',';
      Options_CSVDLM_Len_Value  := 1;
      Options_Header_Value      := True;
      Options_SAVEOVERWRT_Value   := True;
      Options_Warn_Reserved_Value := True;
      Options_TXTFMT_Value        := (others => ' ');
      Options_TXTFMT_Value (1 .. 4) := "AUTO";
      Options_TXTFMT_Len_Value  := 4;
      Options_CHARSET_Value     := (others => ' ');
      Options_CHARSET_Len_Value := 0;
      IEEE_Divide_Value         := False;
      Options_Shell_Timeout_Value       := SData_Core.Config.Shell_Timeout_Default;
      Options_Join_Warn_Threshold_Value := 1_000_000;
      Save_DLM_Value            := (others => ' ');
      Save_DLM_Value (1)        := ',';
      Save_DLM_Len_Value        := 1;
      Save_Header_Value         := True;
      Save_Charset_Value        := (others => ' ');
      Save_Charset_Len_Value    := 0;
      Clear_Select_Filter;
   end Reset;

   procedure Clear_Select_Filter is
   begin
      SData_Core.Evaluator.Free_Expression (Select_Filter_Expr_Value);
   end Clear_Select_Filter;

   procedure End_Repeat is
   begin
      Repeat_Active_Value := False;
      Repeat_Count_Value  := 0;
   end End_Repeat;

   procedure Clear_Pending_Save is
   begin
      Save_File_Active_Value := False;
   end Clear_Pending_Save;

end SData_Core.Config.Runtime;
