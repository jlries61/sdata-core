--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Internal write surface for SData_Core.Config.Runtime.  Callable only
--  by SData_Core.Commands (the Execute_* procedures) and by the parent
--  package body.  Front ends (sdata, data-vandal) must not `with` this
--  package; they drive Runtime through the Execute_* surface only.
--
--  Each procedure encapsulates a logically-atomic update of one or two
--  related private-part state variables (e.g. Set_Save_File_Path
--  updates both Save_File_Path_Value and Save_File_Len_Value so the
--  pair stays consistent).  Privatization (audit item #5) replaces 58
--  direct field writes in Commands.adb with calls into this package.

with SData_Core.Evaluator;

package SData_Core.Config.Runtime.Internal is

   --  SAVE descriptor (Execute_SAVE writes these).  Each Set_X_Path-style
   --  procedure also updates the matching _Len so callers cannot leave
   --  the pair inconsistent.
   procedure Set_Save_File_Path  (Value : String);
   procedure Clear_Save_File_Path;
   procedure Set_Save_File_Fmt   (Value : SData_Core.Config.Format_Type);
   procedure Set_Save_File_Active (Value : Boolean);
   procedure Set_Save_Sheet_Name (Value : String);

   --  Effective SAVE format captured at SAVE time.
   procedure Set_Save_DLM     (Value : String);
   procedure Set_Save_Header  (Value : Boolean);
   procedure Set_Save_Charset (Value : String);
   procedure Set_Save_Decimals (Value : Integer);

   --  OUTPUT_Table descriptor (Execute_OUTPUT_Table writes these).
   procedure Set_Output_Table_Path   (Value : String);
   procedure Set_Output_Table_Fmt    (Value : SData_Core.Config.Format_Type);
   procedure Set_Output_Table_Active (Value : Boolean);

   --  REPEAT loop bookkeeping (Execute_REPEAT writes these).  Use the
   --  public End_Repeat in the parent package to clear; Set_Repeat is
   --  for entering the loop.
   procedure Set_Repeat (Count : Natural);

   --  FPATH search paths (Execute_FPATH writes one or more of these).
   procedure Set_FPath_Use    (Value : Unbounded_String);
   procedure Set_FPath_Save   (Value : Unbounded_String);
   procedure Set_FPath_Submit (Value : Unbounded_String);
   procedure Set_FPath_Output (Value : Unbounded_String);

   --  OPTIONS command (Execute_OPTIONS_* writes one of these).
   procedure Set_Options_CSVDLM             (Value : String);
   procedure Set_Options_Header             (Value : Boolean);
   procedure Set_Options_SAVEOVERWRT        (Value : Boolean);
   procedure Set_Options_Warn_Reserved      (Value : Boolean);
   procedure Set_Options_TXTFMT             (Value : String);
   procedure Set_Options_CHARSET            (Value : String);
   procedure Set_IEEE_Divide                (Value : Boolean);
   procedure Set_Options_Shell_Timeout      (Value : Natural);
   procedure Set_Options_Join_Warn_Threshold (Value : Natural);

   --  Error recording (Execute_Record_Error writes these).
   procedure Set_Last_Error (Code : Natural; Line : Natural);

   --  SELECT filter (Execute_SELECT writes this; ownership transfers in).
   procedure Set_Select_Filter
     (Expr : SData_Core.Evaluator.Expression_Access);

end SData_Core.Config.Runtime.Internal;
