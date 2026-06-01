--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Config.Runtime holds interpreter state that changes
--  during execution and is reset to defaults by the NEW command.  Separating
--  it from SData_Core.Config makes the boundary between startup configuration
--  (set once by the CLI) and per-run state (written by the interpreter)
--  explicit.
--
--  Privatization (audit item #5): the state itself lives in the private
--  part of this spec, accessible only to the package body and to the
--  Internal child package.  Consumers see read-only accessor functions
--  with the same names as the old public variables, plus the lifecycle
--  procedures below.  All writes go through SData_Core.Config.Runtime.
--  Internal, which is callable only by SData_Core.Commands.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Evaluator;

package SData_Core.Config.Runtime is

   --  Read accessors.  Each returns the current value of the corresponding
   --  private state variable.  At the call site these read identically to
   --  the previous public variables (Ada lets you slice a function result
   --  the same way you slice a String variable), so existing consumer
   --  code continues to compile unchanged.

   function Save_File_Path      return String;
   function Save_File_Len       return Natural;
   function Save_File_Active    return Boolean;
   function Save_File_Fmt       return SData_Core.Config.Format_Type;
   function Save_Sheet_Name     return String;
   function Save_Sheet_Name_Len return Natural;

   function FPath_Use    return Unbounded_String;
   function FPath_Save   return Unbounded_String;
   function FPath_Submit return Unbounded_String;
   function FPath_Output return Unbounded_String;

   function Output_Table_Path   return String;
   function Output_Table_Len    return Natural;
   function Output_Table_Active return Boolean;
   function Output_Table_Fmt    return SData_Core.Config.Format_Type;

   function Repeat_Count  return Natural;
   function Repeat_Active return Boolean;

   function Last_Error_Code return Natural;
   function Last_Error_Line return Natural;

   function Options_CSVDLM             return String;
   function Options_CSVDLM_Len         return Natural;
   function Options_Header             return Boolean;
   function Options_SAVEOVERWRT        return Boolean;
   function Options_TXTFMT             return String;
   function Options_TXTFMT_Len         return Natural;
   function Options_CHARSET            return String;
   function Options_CHARSET_Len        return Natural;
   function IEEE_Divide                return Boolean;
   function Options_Shell_Timeout      return Natural;
   function Options_Join_Warn_Threshold return Natural;

   function Save_DLM         return String;
   function Save_DLM_Len     return Natural;
   function Save_Header      return Boolean;
   function Save_Charset     return String;
   function Save_Charset_Len return Natural;

   function Select_Filter_Expr return SData_Core.Evaluator.Expression_Access;

   ----------------------------------------------------------------
   --  Lifecycle procedures (public).

   procedure Reset;

   --  Clear_Select_Filter — free any installed persistent SELECT filter
   --  expression and reset the field to null.  Idempotent.
   procedure Clear_Select_Filter;

   --  End_Repeat — clear an active REPEAT state once the loop has finished
   --  iterating.  Idempotent.
   procedure End_Repeat;

   --  Clear_Pending_Save — cancel any pending SAVE target.  Does NOT clear
   --  path/format/sheet (only Reset blanks the full SAVE descriptor).
   --  Idempotent.
   procedure Clear_Pending_Save;

private

   --  Mutable state.  Visible to the package body and to children (the
   --  Internal child package writes these; readers go through the public
   --  accessor functions above).

   Save_File_Path_Value      : String (1 .. SData_Core.Max_Path_Len) :=
                                 (others => ' ');
   Save_File_Len_Value       : Natural := 0;
   Save_File_Active_Value    : Boolean := False;
   Save_File_Fmt_Value       : SData_Core.Config.Format_Type :=
                                 SData_Core.Config.CSV;
   Save_Sheet_Name_Value     : String (1 .. SData_Core.Max_Sheet_Name_Len) :=
                                 (others => ' ');
   Save_Sheet_Name_Len_Value : Natural := 0;

   FPath_Use_Value    : Unbounded_String := Null_Unbounded_String;
   FPath_Save_Value   : Unbounded_String := Null_Unbounded_String;
   FPath_Submit_Value : Unbounded_String := Null_Unbounded_String;
   FPath_Output_Value : Unbounded_String := Null_Unbounded_String;

   --  Output_Table_* — file path captured by Execute_OUTPUT_Table for
   --  front ends (e.g. data-vandal) where OUTPUT writes the table itself
   --  rather than redirecting console output.  Distinct from Save_File_*
   --  so SAVE-driven and OUTPUT-driven writes do not interfere.
   Output_Table_Path_Value   : String (1 .. SData_Core.Max_Path_Len) :=
                                 (others => ' ');
   Output_Table_Len_Value    : Natural := 0;
   Output_Table_Active_Value : Boolean := False;
   Output_Table_Fmt_Value    : SData_Core.Config.Format_Type :=
                                 SData_Core.Config.CSV;

   Repeat_Count_Value  : Natural := 0;
   Repeat_Active_Value : Boolean := False;

   Last_Error_Code_Value : Natural := 0;
   Last_Error_Line_Value : Natural := 0;

   --  OPTIONS command runtime state.
   Options_CSVDLM_Value      : String (1 .. SData_Core.Max_Delimiter_Len) :=
                                 (',', others => ' ');
   Options_CSVDLM_Len_Value  : Natural := 1;
   Options_Header_Value      : Boolean := True;
   Options_SAVEOVERWRT_Value : Boolean := True;
   Options_TXTFMT_Value      : String (1 .. SData_Core.Max_Delimiter_Len) :=
                                 "AUTO    ";
   Options_TXTFMT_Len_Value  : Natural := 4;
   Options_CHARSET_Value     : String (1 .. SData_Core.Max_Charset_Len) :=
                                 (others => ' ');
   Options_CHARSET_Len_Value : Natural := 0;
   IEEE_Divide_Value         : Boolean := False;
   Options_Shell_Timeout_Value       : Natural := 0;
   Options_Join_Warn_Threshold_Value : Natural := 1_000_000;

   --  Effective delimiter/header/charset saved at SAVE time for use at write.
   Save_DLM_Value         : String (1 .. SData_Core.Max_Delimiter_Len) :=
                              (',', others => ' ');
   Save_DLM_Len_Value     : Natural := 1;
   Save_Header_Value      : Boolean := True;
   Save_Charset_Value     : String (1 .. SData_Core.Max_Charset_Len) :=
                              (others => ' ');
   Save_Charset_Len_Value : Natural := 0;

   --  Persistent SELECT filter expression.  Set by Execute_SELECT and
   --  cleared by Reset (NEW command) or Clear_Select_Filter.  Shared
   --  between the interpreter and any front end that hosts the Commands
   --  package; rebuilt into a logical->physical index map at the start
   --  of each data step.
   Select_Filter_Expr_Value : SData_Core.Evaluator.Expression_Access := null;

end SData_Core.Config.Runtime;
