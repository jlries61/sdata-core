--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Config.Runtime holds interpreter state that changes
--  during execution and is reset to defaults by the NEW command.  Separating
--  it from SData_Core.Config makes the boundary between startup configuration
--  (set once by the CLI) and per-run state (written by the interpreter)
--  explicit.

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Evaluator;

package SData_Core.Config.Runtime is

   Save_File_Path      : String (1 .. SData_Core.Max_Path_Len) :=
                           (others => ' ');
   Save_File_Len       : Natural := 0;
   Save_File_Active    : Boolean := False;
   Save_File_Fmt       : SData_Core.Config.Format_Type :=
                           SData_Core.Config.CSV;
   Save_Sheet_Name     : String (1 .. SData_Core.Max_Sheet_Name_Len) :=
                           (others => ' ');
   Save_Sheet_Name_Len : Natural := 0;
   FPath_Use           : Unbounded_String := Null_Unbounded_String;
   FPath_Save          : Unbounded_String := Null_Unbounded_String;
   FPath_Submit        : Unbounded_String := Null_Unbounded_String;
   FPath_Output        : Unbounded_String := Null_Unbounded_String;
   --  Output_Table_* — file path captured by Execute_OUTPUT_Table for
   --  front ends (e.g. data-vandal) where OUTPUT writes the table itself
   --  rather than redirecting console output.  Distinct from Save_File_*
   --  so SAVE-driven and OUTPUT-driven writes do not interfere.
   Output_Table_Path   : String (1 .. SData_Core.Max_Path_Len) :=
                           (others => ' ');
   Output_Table_Len    : Natural := 0;
   Output_Table_Active : Boolean := False;
   Output_Table_Fmt    : SData_Core.Config.Format_Type :=
                           SData_Core.Config.CSV;
   Repeat_Count        : Natural := 0;
   Repeat_Active       : Boolean := False;
   Last_Error_Code     : Natural := 0;
   Last_Error_Line     : Natural := 0;

   --  OPTIONS command runtime state
   Options_CSVDLM      : String (1 .. SData_Core.Max_Delimiter_Len) :=
                           (',', others => ' ');
   Options_CSVDLM_Len  : Natural := 1;
   Options_Header      : Boolean := True;
   Options_SAVEOVERWRT : Boolean := True;
   Options_TXTFMT      : String (1 .. SData_Core.Max_Delimiter_Len) :=
                           "AUTO    ";
   Options_TXTFMT_Len  : Natural := 4;
   Options_CHARSET     : String (1 .. SData_Core.Max_Charset_Len) :=
                           (others => ' ');
   Options_CHARSET_Len   : Natural := 0;
   IEEE_Divide           : Boolean := False;
   Options_Shell_Timeout : Natural := 0;
   Options_Join_Warn_Threshold : Natural := 1_000_000;

   --  Effective delimiter/header/charset saved at SAVE time for use at write
   Save_DLM         : String (1 .. SData_Core.Max_Delimiter_Len) :=
                        (',', others => ' ');
   Save_DLM_Len     : Natural := 1;
   Save_Header      : Boolean := True;
   Save_Charset     : String (1 .. SData_Core.Max_Charset_Len) :=
                        (others => ' ');
   Save_Charset_Len : Natural := 0;

   --  Persistent SELECT filter expression.  Set by Execute_SELECT and cleared
   --  by Reset (NEW command).  Shared between the interpreter and any front
   --  end that hosts the Commands package; rebuilt into a logical→physical
   --  index map at the start of each data step.
   Select_Filter_Expr : SData_Core.Evaluator.Expression_Access := null;

   procedure Reset;

   ----------------------------------------------------------------
   --  Clear_Select_Filter — free any installed persistent SELECT
   --  filter expression and reset the field to null.
   --
   --  Encapsulates the ownership transfer that consumers previously
   --  performed by calling Evaluator.Free_Expression on
   --  Select_Filter_Expr directly.  Required as a precondition for
   --  privatizing the Runtime field surface (audit item #5): once
   --  Select_Filter_Expr becomes a read-only accessor, the direct
   --  Free_Expression call no longer compiles (cannot pass a
   --  function result as an in-out parameter).
   --
   --  Idempotent — safe to call when no filter is installed.
   procedure Clear_Select_Filter;

end SData_Core.Config.Runtime;
