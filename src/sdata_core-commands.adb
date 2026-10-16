--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;        use Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;          use Ada.Strings.Unbounded;
with GNAT.OS_Lib;
with SData_Core.Config.Runtime;
with SData_Core.Config.Runtime.Internal;
with SData_Core.File_IO;
with SData_Core.IO;
with SData_Core.Values;              use SData_Core.Values;
with SData_Core.Variables;
use SData_Core;

package body SData_Core.Commands is

   --------------------------------------------------------------------
   --  Local helpers                                                  --
   --------------------------------------------------------------------

   package Name_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   --  Full_Path — resolve a user-supplied path against the appropriate
   --  FPath_* base directory and tack on a default extension when the
   --  caller omitted one.  Mirrors the legacy implementation in
   --  SData.Interpreter so that paths supplied to commands inside
   --  sdata-core hosts behave identically across front ends.
   function Full_Path (Path : String; Category : String) return String is
      Cat    : constant String := To_Upper (Category);
      Base   : Unbounded_String := Null_Unbounded_String;
      Result : Unbounded_String;

      function Has_Extension (S : String) return Boolean is
      begin
         for I in reverse S'Range loop
            if S (I) = '.' then
               return True;
            elsif S (I) = '/' or else S (I) = '\' then
               return False;
            end if;
         end loop;
         return False;
      end Has_Extension;
   begin
      --  Absolute paths bypass FPATH resolution entirely.
      if Path'Length >= 1 and then
         (Path (Path'First) = '/' or else
          (Path'Length >= 2 and then Path (Path'First + 1) = ':'))
      then
         Result := To_Unbounded_String (Path);
      else
         if Cat = "USE" then
            Base := SData_Core.Config.Runtime.FPath_Use;
         elsif Cat = "SAVE" then
            Base := SData_Core.Config.Runtime.FPath_Save;
         elsif Cat = "SUBMIT" then
            Base := SData_Core.Config.Runtime.FPath_Submit;
         elsif Cat = "OUTPUT" then
            Base := SData_Core.Config.Runtime.FPath_Output;
         end if;

         if Base /= Null_Unbounded_String and then
            To_String (Base) /= ""
         then
            declare
               B : constant String := To_String (Base);
            begin
               if B (B'Last) = '/' or else B (B'Last) = '\' then
                  Result := To_Unbounded_String (B & Path);
               else
                  Result := To_Unbounded_String (B & "/" & Path);
               end if;
            end;
         else
            Result := To_Unbounded_String (Path);
         end if;
      end if;

      --  Append a category-default extension if one is missing.  MOCK is
      --  a sentinel value that bypasses extension handling.
      declare
         S : constant String := To_String (Result);
      begin
         if To_Upper (S) = "MOCK" or else To_Upper (S) = "MOCK_DATA" then
            return S;
         end if;
         if not Has_Extension (S) then
            if Cat = "USE" or else Cat = "SAVE" then
               return S & ".CSV";
            elsif Cat = "SUBMIT" then
               return S & ".CMD";
            elsif Cat = "OUTPUT" then
               return S & ".DAT";
            end if;
         end if;
         return S;
      end;
   end Full_Path;

   --  Validate_Output_Dir — design.md §4.3/§4.5's "Data Integrity" contract
   --  for SAVE/OUTPUT: the target directory must exist and be writable,
   --  checked immediately when the statement executes rather than left to
   --  surface as a raw Ada exception when the deferred write eventually
   --  happens.  Category names the caller in the error message (e.g. "SAVE").
   --  Uses Ada.Directories.Containing_Directory rather than a hand-rolled
   --  '/'/'\\' scan: it's standard Ada, so path-separator syntax is
   --  whatever the target Ada implementation defines it to be (POSIX,
   --  Windows, or otherwise), not hardcoded here. It's purely syntactic --
   --  no existence check on Full itself -- so it works fine on a
   --  not-yet-existing SAVE target.
   procedure Validate_Output_Dir (Full : String; Category : String) is
      Dir : constant String := Ada.Directories.Containing_Directory (Full);
   begin
      if not Ada.Directories.Exists (Dir) then
         raise SData_Core.Script_Error with
            Category & ": target directory does not exist: " & Dir;
      end if;
      if not Ada.Directories."=" (Ada.Directories.Kind (Dir), Ada.Directories.Directory) then
         raise SData_Core.Script_Error with
            Category & ": target path is not a directory: " & Dir;
      end if;
      if not GNAT.OS_Lib.Is_Write_Accessible_File (Dir) then
         raise SData_Core.Script_Error with
            Category & ": no write permission for directory: " & Dir;
      end if;
   exception
      when Ada.Directories.Name_Error =>
         raise SData_Core.Script_Error with
            Category & ": invalid target path: " & Full;
      when Ada.Directories.Use_Error =>
         raise SData_Core.Script_Error with
            Category & ": target path has no containing directory: " & Full;
   end Validate_Output_Dir;

   --  Collect_Filter_Vars — walks the filter AST and inserts the upper-cased
   --  name of every variable the expression reads at evaluation time.  The
   --  first argument of identifier-ref functions (LAG/NEXT/OBS etc.) is a
   --  variable *name*, not a value read, so it is skipped.
   procedure Collect_Filter_Vars
     (Expr  :        SData_Core.Evaluator.Expression_Access;
      Names : in out Name_Sets.Set) is
      use SData_Core.Evaluator;
   begin
      if Expr = null then
         return;
      end if;
      case Expr.Kind is
         when Expr_Variable =>
            Names.Include (To_Upper (Expr.Var_Name (1 .. Expr.Var_Len)));
         when Expr_Binary_Op =>
            Collect_Filter_Vars (Expr.Left,  Names);
            Collect_Filter_Vars (Expr.Right, Names);
         when Expr_Unary_Op =>
            Collect_Filter_Vars (Expr.Operand, Names);
         when Expr_Function_Call =>
            declare
               FName : constant String :=
                  To_Upper (Expr.Func_Name (1 .. Expr.Func_Len));
               Args  : Expression_List := Expr.Arguments;
            begin
               if Is_Identifier_Ref_Function (FName) and then Args /= null
               then
                  Args := Args.Next;  --  skip the variable-name argument
               end if;
               while Args /= null loop
                  Collect_Filter_Vars (Args.Expr, Names);
                  Args := Args.Next;
               end loop;
            end;
         when Expr_Array_Access =>
            Names.Include (To_Upper (Expr.Arr_Name (1 .. Expr.Arr_Len)));
            declare
               Idx : Expression_List := Expr.Arr_Idx;
            begin
               while Idx /= null loop
                  Collect_Filter_Vars (Idx.Expr, Names);
                  Idx := Idx.Next;
               end loop;
            end;
         when others =>
            null;
      end case;
   end Collect_Filter_Vars;

   --  Rebuild_Filter_Map — re-evaluates the persistent SELECT filter
   --  against the current physical row set and installs the resulting
   --  logical→physical index map on the table.  No-op when no filter is
   --  active.  Called from Execute_RUN.
   procedure Rebuild_Filter_Map is
      use SData_Core.Evaluator;
      Expr : constant Expression_Access :=
         SData_Core.Config.Runtime.Select_Filter_Expr;
   begin
      if Expr = null then
         return;
      end if;
      declare
         Total          : constant Natural := SData_Core.Table.Row_Count;
         Saved_Physical : constant Natural :=
            SData_Core.Table.Get_Current_Record_Index;
      begin
         if Total = 0 then
            SData_Core.Table.Clear_Index_Map;
         else
            declare
               Filter_Cols : Name_Sets.Set;
            begin
               Collect_Filter_Vars (Expr, Filter_Cols);
               declare
                  Passing : SData_Core.Table.Index_Array (1 .. Total);
                  Count   : Natural := 0;
               begin
                  for R in 1 .. Total loop
                     SData_Core.Table.Set_Current_Record_Index (R);
                     for Col_Name of Filter_Cols loop
                        if SData_Core.Table.Has_Column (Col_Name) then
                           SData_Core.Variables.Load_PDV_One_Column
                              (R, Col_Name);
                        end if;
                     end loop;
                     if Is_True (Evaluate (Expr)) then
                        Count := Count + 1;
                        Passing (Count) := R;
                        if SData_Core.Config.Debug_Level >= 2 then
                           SData_Core.IO.Put_Line_Error
                              ("[debug] SELECT: KEPT");
                        end if;
                     else
                        if SData_Core.Config.Debug_Level >= 2 then
                           SData_Core.IO.Put_Line_Error
                              ("[debug] SELECT: DROPPED");
                        end if;
                     end if;
                  end loop;
                  SData_Core.Table.Set_Current_Record_Index (Saved_Physical);
                  SData_Core.Table.Set_Index_Map (Passing (1 .. Count));
                  if SData_Core.Config.Debug_Level >= 2 then
                     declare
                        Count_Img : constant String :=
                           Natural'Image (Count);
                        Total_Img : constant String :=
                           Natural'Image (Total);
                     begin
                        SData_Core.IO.Put_Line_Error
                          ("[debug] SELECT: "
                           & Count_Img (Count_Img'First + 1
                                        .. Count_Img'Last)
                           & " of "
                           & Total_Img (Total_Img'First + 1
                                        .. Total_Img'Last)
                           & " records kept");
                     end;
                  end if;
               exception
                  when others =>
                     SData_Core.Table.Set_Current_Record_Index
                        (Saved_Physical);
                     raise;
               end;
            end;
         end if;
      end;
   end Rebuild_Filter_Map;

   --  Flush_Pending_Output_Table — if a table-form OUTPUT path is pending
   --  and no SAVE is also pending, write the current table to that path.
   --  Used by Execute_RUN so that front ends (e.g. data-vandal) where
   --  OUTPUT means "save the table here" produce a file at end-of-RUN.
   --  When both an OUTPUT path and a SAVE are active, SAVE wins and this
   --  routine is a no-op, mirroring the spec text "if OUTPUT was set
   --  without an explicit SAVE".
   procedure Flush_Pending_Output_Table is
   begin
      if not SData_Core.Config.Runtime.Output_Table_Active then
         return;
      end if;
      if SData_Core.Config.Runtime.Save_File_Active then
         --  An explicit SAVE supersedes OUTPUT-as-save; let
         --  Flush_Pending_Save handle the write.
         return;
      end if;
      begin
         SData_Core.File_IO.Open_Output
            (Full_Path
                (SData_Core.Config.Runtime.Output_Table_Path
                    (1 .. SData_Core.Config.Runtime.Output_Table_Len),
                 "OUTPUT"),
             SData_Core.Config.Runtime.Output_Table_Fmt,
             "",          -- sheet name (default)
             ",",         -- delimiter
             True,        -- write header
             SData_Core.Config.Runtime.Options_SAVEOVERWRT,
             SData_Core.Config.Runtime.Options_CHARSET
                (1 .. SData_Core.Config.Runtime.Options_CHARSET_Len));
         SData_Core.IO.Put_Line
           ("Dataset saved: " &
            SData_Core.Config.Runtime.Output_Table_Path
               (1 .. SData_Core.Config.Runtime.Output_Table_Len));
      exception
         when SData_Core.File_IO.Save_Refused => null;
         when E : Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
            raise SData_Core.Script_Error with
               "OUTPUT: cannot write """ &
               SData_Core.Config.Runtime.Output_Table_Path
                  (1 .. SData_Core.Config.Runtime.Output_Table_Len) &
               """: " & Ada.Exceptions.Exception_Message (E);
      end;
   end Flush_Pending_Output_Table;

   --  Flush_Pending_Save — if a SAVE is pending, write the current table
   --  out using the parameters captured at SAVE time and clear the
   --  pending flag.  Used by Execute_RUN.
   procedure Flush_Pending_Save is
   begin
      if not SData_Core.Config.Runtime.Save_File_Active then
         return;
      end if;
      begin
         SData_Core.File_IO.Open_Output
            (Full_Path
                (SData_Core.Config.Runtime.Save_File_Path
                    (1 .. SData_Core.Config.Runtime.Save_File_Len),
                 "SAVE"),
             SData_Core.Config.Runtime.Save_File_Fmt,
             SData_Core.Config.Runtime.Save_Sheet_Name
                (1 .. SData_Core.Config.Runtime.Save_Sheet_Name_Len),
             SData_Core.Config.Runtime.Save_DLM
                (1 .. SData_Core.Config.Runtime.Save_DLM_Len),
             SData_Core.Config.Runtime.Save_Header,
             SData_Core.Config.Runtime.Options_SAVEOVERWRT,
             SData_Core.Config.Runtime.Save_Charset
                (1 .. SData_Core.Config.Runtime.Save_Charset_Len),
             SData_Core.Config.Runtime.Save_Decimals,
             SData_Core.Config.Runtime.Save_Missing_Token
                (1 .. SData_Core.Config.Runtime.Save_Missing_Token_Len));
         SData_Core.IO.Put_Line
           ("Dataset saved: " &
            SData_Core.Config.Runtime.Save_File_Path
               (1 .. SData_Core.Config.Runtime.Save_File_Len));
      exception
         when SData_Core.File_IO.Save_Refused => null;
         when E : Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
            raise SData_Core.Script_Error with
               "SAVE: cannot write """ &
               SData_Core.Config.Runtime.Save_File_Path
                  (1 .. SData_Core.Config.Runtime.Save_File_Len) &
               """: " & Ada.Exceptions.Exception_Message (E);
      end;
      SData_Core.Config.Runtime.Clear_Pending_Save;
   end Flush_Pending_Save;

   --------------------------------------------------------------------
   --  Execute_USE                                                    --
   --------------------------------------------------------------------
   procedure Execute_USE
     (File_Name   : String;
      Fmt         : SData_Core.Config.Format_Type;
      Sheet_Name  : String  := "";
      Delimiter   : String  := ",";
      Read_Header : Boolean := True;
      Charset     : String  := "";
      Skip_Rows   : Natural := 0;
      Max_Rows    : Natural := 0;
      Nscan_Rows  : Natural := 0;
      Is_Mock     : Boolean := False;
      Missing_Tokens : String := "";
      Declared_Types : String := "")
   is
   begin
      SData_Core.Config.Runtime.End_Repeat;

      declare
         Full : constant String :=
            (if Is_Mock then "MOCK" else Full_Path (File_Name, "USE"));
      begin
         if Full'Length > SData_Core.Max_Path_Len then
            raise SData_Core.Script_Error with "Path too long: " & Full;
         end if;
         SData_Core.File_IO.Open_Input
           (Full,
            Fmt,
            Sheet_Name,
            Delimiter,
            Read_Header,
            Charset,
            Skip_Rows,
            Max_Rows,
            Nscan_Rows,
            Missing_Tokens,
            Declared_Types);
      end;

      --  Final progress total for the load (per-row ticks are emitted inside
      --  each format reader); no-op unless --progress is set.
      SData_Core.IO.Show_Progress
        ("USE", SData_Core.Table.Row_Count, Final => True);

      SData_Core.Variables.Refresh_PDV_Names;
      SData_Core.Variables.Resolve_Column_Array_Collisions;  --  ADR-0025
      SData_Core.Variables.Register_Subscripted_Columns;
   end Execute_USE;

   --------------------------------------------------------------------
   --  Resolve_Use_Defaults                                           --
   --------------------------------------------------------------------
   function Resolve_Use_Defaults
     (Delimiter           : String  := "";
      Delimiter_Specified : Boolean := False;
      Read_Header         : Boolean := True;
      Header_Specified    : Boolean := False;
      Charset             : String  := "";
      Charset_Specified   : Boolean := False) return Use_Defaults
   is
      Eff_DLM : constant String :=
        (if Delimiter_Specified then Delimiter
         else SData_Core.Config.Runtime.Options_CSVDLM
                (1 .. SData_Core.Config.Runtime.Options_CSVDLM_Len));
      Eff_Charset : constant String :=
        (if Charset_Specified then Charset
         else SData_Core.Config.Runtime.Options_CHARSET
                (1 .. SData_Core.Config.Runtime.Options_CHARSET_Len));
      Result : Use_Defaults;
   begin
      if Eff_DLM'Length > Max_Delimiter_Len then
         raise SData_Core.Script_Error
           with "USE delimiter too long: " & Eff_DLM;
      end if;
      if Eff_Charset'Length > Max_Charset_Len then
         raise SData_Core.Script_Error
           with "USE charset name too long: " & Eff_Charset;
      end if;

      Result.Delimiter (1 .. Eff_DLM'Length) := Eff_DLM;
      Result.Delimiter_Len := Eff_DLM'Length;
      Result.Read_Header :=
        (if Header_Specified then Read_Header
         else SData_Core.Config.Runtime.Options_Header);
      Result.Charset (1 .. Eff_Charset'Length) := Eff_Charset;
      Result.Charset_Len := Eff_Charset'Length;
      return Result;
   end Resolve_Use_Defaults;

   --------------------------------------------------------------------
   --  Execute_SAVE                                                   --
   --------------------------------------------------------------------
   procedure Execute_SAVE
     (File_Name    : String;
      Fmt          : SData_Core.Config.Format_Type;
      Sheet_Name   : String  := "";
      Delimiter    : String  := ",";
      Write_Header : Boolean := True;
      Charset      : String  := "";
      Decimals     : Integer := -1;
      Missing_Token : String := "")
   is
   begin
      if File_Name'Length = 0 then
         SData_Core.Config.Runtime.Clear_Pending_Save;
         SData_Core.Config.Runtime.Internal.Clear_Save_File_Path;
         return;
      end if;

      declare
         Full : constant String := Full_Path (File_Name, "SAVE");
      begin
         Validate_Output_Dir (Full, "SAVE");
         SData_Core.Config.Runtime.Internal.Set_Save_File_Path (Full);
         SData_Core.Config.Runtime.Internal.Set_Save_File_Fmt (Fmt);
         SData_Core.Config.Runtime.Internal.Set_Save_Sheet_Name (Sheet_Name);
         SData_Core.Config.Runtime.Internal.Set_Save_File_Active (True);
         SData_Core.Config.Runtime.Internal.Set_Save_DLM (Delimiter);
         SData_Core.Config.Runtime.Internal.Set_Save_Header (Write_Header);
         if Charset'Length > 0 then
            SData_Core.Config.Runtime.Internal.Set_Save_Charset (Charset);
         else
            SData_Core.Config.Runtime.Internal.Set_Save_Charset
              (SData_Core.Config.Runtime.Options_CHARSET
                  (1 .. SData_Core.Config.Runtime.Options_CHARSET_Len));
         end if;
         SData_Core.Config.Runtime.Internal.Set_Save_Decimals (Decimals);
         SData_Core.Config.Runtime.Internal.Set_Save_Missing_Token (Missing_Token);
      end;
   end Execute_SAVE;

   --------------------------------------------------------------------
   --  Execute_FPATH                                                  --
   --------------------------------------------------------------------
   procedure Execute_FPATH
     (Path        : String;
      Use_Flag    : Boolean := False;
      Save_Flag   : Boolean := False;
      Submit_Flag : Boolean := False;
      Output_Flag : Boolean := False)
   is
      Reset_All : constant Boolean :=
         not (Use_Flag or Save_Flag or Submit_Flag or Output_Flag);
      P : constant Unbounded_String := To_Unbounded_String (Path);
   begin
      if Reset_All or else Use_Flag    then
         SData_Core.Config.Runtime.Internal.Set_FPath_Use    (P);
      end if;
      if Reset_All or else Save_Flag   then
         SData_Core.Config.Runtime.Internal.Set_FPath_Save   (P);
      end if;
      if Reset_All or else Submit_Flag then
         SData_Core.Config.Runtime.Internal.Set_FPath_Submit (P);
      end if;
      if Reset_All or else Output_Flag then
         SData_Core.Config.Runtime.Internal.Set_FPath_Output (P);
      end if;
   end Execute_FPATH;

   --------------------------------------------------------------------
   --  Execute_OUTPUT                                                 --
   --------------------------------------------------------------------
   procedure Execute_OUTPUT
     (File_Name : String;
      TXTFMT    : String := "";
      Charset   : String := "")
   is
   begin
      if SData_Core.IO.Is_Redirected then
         SData_Core.IO.Close_Output;
      end if;
      if File_Name'Length > 0 then
         SData_Core.IO.Open_Output (Full_Path (File_Name, "OUTPUT"));
      end if;
      --  Route OPTIONS-field writes through the OPTIONS executors so the
      --  same length validation applies regardless of which door
      --  (OUTPUT or OPTIONS) sets the field — one validating path, no
      --  raw Internal.Set_* bypass (see ADR-0005; closes Fowler R3).
      if TXTFMT'Length > 0 then
         Execute_OPTIONS_TXTFMT (TXTFMT);
      end if;
      if Charset'Length > 0 then
         Execute_OPTIONS_CHARSET (Charset);
      end if;
   end Execute_OUTPUT;

   --------------------------------------------------------------------
   --  Execute_OUTPUT_Table                                           --
   --------------------------------------------------------------------
   procedure Execute_OUTPUT_Table
     (File_Name : String;
      Fmt       : SData_Core.Config.Format_Type := SData_Core.Config.CSV)
   is
   begin
      if File_Name'Length = 0 then
         SData_Core.Config.Runtime.Internal.Set_Output_Table_Active (False);
         SData_Core.Config.Runtime.Internal.Set_Output_Table_Path ("");
         return;
      end if;

      if File_Name'Length > SData_Core.Max_Path_Len then
         raise SData_Core.Script_Error with
            "OUTPUT: path too long: " & File_Name;
      end if;

      SData_Core.Config.Runtime.Internal.Set_Output_Table_Path (File_Name);
      SData_Core.Config.Runtime.Internal.Set_Output_Table_Fmt (Fmt);
      SData_Core.Config.Runtime.Internal.Set_Output_Table_Active (True);
   end Execute_OUTPUT_Table;

   --------------------------------------------------------------------
   --  Execute_SELECT                                                 --
   --------------------------------------------------------------------
   procedure Execute_SELECT
     (Expr : SData_Core.Evaluator.Expression_Access)
   is
      use type SData_Core.Evaluator.Expression_Access;
      Old : SData_Core.Evaluator.Expression_Access :=
         SData_Core.Config.Runtime.Select_Filter_Expr;
   begin
      if Old = Expr then
         return;  --  caller passing back the same expression; nothing to do
      end if;
      SData_Core.Evaluator.Free_Expression (Old);
      SData_Core.Config.Runtime.Internal.Set_Select_Filter (Expr);
      SData_Core.Table.Clear_Index_Map;
   end Execute_SELECT;

   --------------------------------------------------------------------
   --  Execute_KEEP                                                   --
   --------------------------------------------------------------------
   procedure Execute_KEEP
     (Names : SData_Core.Table.Name_Vectors.Vector)
   is
      Keep : Name_Sets.Set;
   begin
      --  Expand any array base name into its actual member column names
      --  before building Keep, so an array mentioned by name (e.g. "KEEP
      --  Q" for array Q) retains all of
      --  Q's elements per design.md §3.4 ("If virtual array mentioned in
      --  KEEP, all constituent variables are retained" -- the same
      --  member-level treatment applies to real arrays, which have no
      --  separate rule because they have no "definition" distinct from
      --  their elements the way a virtual array does). A name that is not
      --  a registered array is kept literally, unchanged from before.
      for N of Names loop
         declare
            Upper : constant String := To_Upper (To_String (N));
         begin
            if SData_Core.Variables.Has_Array (Upper) then
               for Member of SData_Core.Variables.Expand_Array_Names (Upper) loop
                  Keep.Include (To_Upper (To_String (Member)));
               end loop;
            else
               Keep.Include (Upper);
            end if;
         end;
      end loop;

      --  2026-08-15: validate every requested name against the table's
      --  actual columns before dropping anything -- design.md's own
      --  promise ("A KEEP statement that lists variables that... do not
      --  exist... shall fail with an error message") was never actually
      --  implemented. Previously, a name that matched no column (a typo,
      --  or a session/temporary variable instead of a column) simply never
      --  satisfied "not in Keep" for any real column below, which is a
      --  per-COLUMN condition -- an entirely-unmatched Keep set silently
      --  dropped every column in the table instead of erring, since
      --  nothing ever checked whether the requested names existed at all.
      --  Checked before the drop loop so the statement is atomic: either
      --  every name is valid and KEEP proceeds, or nothing is dropped.
      --  Validated against the *expanded* Keep
      --  set now, since an array base name (e.g. "Q") is never itself a
      --  table column -- Has_Column("Q") would spuriously fail even though
      --  "KEEP Q" is entirely valid for a registered array Q.
      for Name of Keep loop
         if not SData_Core.Table.Has_Column (Name) then
            raise Script_Error with
              "KEEP: variable """ & Name & """ does not exist";
         end if;
      end loop;

      --  Snapshot existing columns before dropping; Drop_Column mutates
      --  Column_Order and would invalidate index-based iteration.
      declare
         Snapshot : SData_Core.Table.Name_Vectors.Vector;
      begin
         for I in 1 .. SData_Core.Table.Column_Count loop
            Snapshot.Append
               (To_Unbounded_String (SData_Core.Table.Column_Name (I)));
         end loop;
         for U of Snapshot loop
            declare
               Col : constant String :=
                  Ada.Characters.Handling.To_Upper (To_String (U));
            begin
               if not Keep.Contains (Col) then
                  SData_Core.Table.Drop_Column (Col);
               end if;
            end;
         end loop;
      end;
   end Execute_KEEP;

   --------------------------------------------------------------------
   --  Execute_DROP                                                   --
   --------------------------------------------------------------------
   procedure Execute_DROP
     (Names : SData_Core.Table.Name_Vectors.Vector)
   is
      --  Expand any array base name into its actual member column names,
      --  matching Execute_KEEP above. Unlike KEEP, a *temporary* array's
      --  elements live in Temp_Symbols, not
      --  Table columns (Dim_Array never creates a Table column for a
      --  Is_Temporary real array; see the Existing_Def.Is_Temporary branch
      --  in Dim_Array's own resize logic) -- Expand_Array_Names still
      --  returns their "NAME(i)" names, but those correctly fail the
      --  Has_Column check below and raise, same as attempting to DROP any
      --  other temporary variable does today. That is *design.md's own
      --  documented rule* for DROP ("A DROP statement that lists a
      --  variable that does not exist as a permanent (table column)
      --  variable -- including a temporary (SET) variable, which DROP
      --  cannot remove; use UNSET instead -- shall fail with an error
      --  message"), not a gap this fix needs to close.
      Expanded : SData_Core.Table.Name_Vectors.Vector;
   begin
      for N of Names loop
         declare
            Upper : constant String := To_Upper (To_String (N));
         begin
            if SData_Core.Variables.Has_Array (Upper) then
               for Member of SData_Core.Variables.Expand_Array_Names (Upper) loop
                  Expanded.Append (Member);
               end loop;
            else
               Expanded.Append (To_Unbounded_String (Upper));
            end if;
         end;
      end loop;

      --  2026-08-15: same treatment as Execute_KEEP above -- validate every
      --  requested name first (atomic: nothing is dropped if any name is
      --  invalid) rather than silently no-op'ing per-name. Previously safe
      --  (unlike KEEP's whole-table data loss) but silent: DROPping a typo
      --  or a session/temporary variable name did nothing, with no feedback
      --  that it hadn't.
      for N of Expanded loop
         declare
            Col : constant String := To_Upper (To_String (N));
         begin
            if not SData_Core.Table.Has_Column (Col) then
               raise Script_Error with
                 "DROP: variable """ & Col & """ does not exist";
            end if;
         end;
      end loop;
      --  Second pass still guards with Has_Column (not just "drop
      --  unconditionally") so a name repeated in the same DROP statement
      --  (e.g. "DROP X, X") harmlessly no-ops on its second occurrence
      --  rather than failing on an already-dropped column.
      for N of Expanded loop
         declare
            Col : constant String := To_Upper (To_String (N));
         begin
            if SData_Core.Table.Has_Column (Col) then
               SData_Core.Table.Drop_Column (Col);
            end if;
         end;
      end loop;

      --  design.md §3.4: "If virtual array mentioned in DROP, all
      --  constituent variables are deleted along with virtual array
      --  definition" -- the same total-deletion behavior applies to real
      --  arrays ("Individual array elements cannot be deleted", so DROP
      --  only ever operates on whole arrays). Undefine *after* the column
      --  drops above succeed, so an array whose DROP fails validation
      --  (e.g. one element already removed independently) keeps its
      --  registration rather than being left half-deleted.
      for N of Names loop
         declare
            Upper : constant String := To_Upper (To_String (N));
         begin
            if SData_Core.Variables.Has_Array (Upper) then
               SData_Core.Variables.Undefine_Array (Upper);
            end if;
         end;
      end loop;
   end Execute_DROP;

   --------------------------------------------------------------------
   --  Execute_ARRAY                                                  --
   --------------------------------------------------------------------
   procedure Execute_ARRAY
     (Name         : String;
      Constituents : SData_Core.Table.Name_Vectors.Vector)
   is
   begin
      if Name'Length = 0 then
         SData_Core.Variables.List_Virtual_Arrays;
      elsif Constituents.Is_Empty then
         SData_Core.Variables.Undefine_Virtual_Array (Name);
      else
         SData_Core.Variables.Define_Array (Name, Constituents);
      end if;
   end Execute_ARRAY;

   --------------------------------------------------------------------
   --  Execute_DIM                                                    --
   --------------------------------------------------------------------
   procedure Execute_DIM
     (Base_Name : String;
      Start_Idx : Integer;
      End_Idx   : Integer;
      Is_Temp   : Boolean := False)
   is
   begin
      SData_Core.Variables.Dim_Array
         (Base_Name, Start_Idx, End_Idx, Is_Temp);
   end Execute_DIM;

   --------------------------------------------------------------------
   --  Execute_Commit_Step                                            --
   --------------------------------------------------------------------
   --------------------------------------------------------------------
   --  Execute_AGGREGATE                                              --
   --------------------------------------------------------------------
   --  Collapses the current table into one row per active BY group.  See
   --  the package spec and ADR-046 for the contract.  Implementation
   --  follows architect C2: validate -> group-scan the SELECT-filtered
   --  logical view -> build a fresh output table -> swap -> flush a pending
   --  SAVE -> clear SELECT and BY.  All validation precedes any side effect.

   package Tbl  renames SData_Core.Table;
   package Eval renames SData_Core.Evaluator;

   --  Shared BY-group scan (the public grouping primitive; see commands.ads).
   --  A "group" is a vector of physical row indices.  Reflects the active
   --  SELECT filter via Rebuild_Filter_Map and partitions the logical view
   --  into consecutive BY-key runs (the whole filtered table is one group when
   --  no BY is active).  Used by AGGREGATE, STATS, TRANSPOSE, and sdata TABLES.
   function Group_Boundaries return Row_Group_Vectors.Vector is
      Physical_Rows : Row_Index_Vectors.Vector;
   begin
      --  ADR-0013: BY no longer sorts the table, so grouping can no longer
      --  be discovered by scanning for adjacent-row runs (that scan is
      --  still exactly right for ordinary RUN group navigation, see
      --  sdata's Group_Flags -- it is Group_Boundaries's own four
      --  commands, AGGREGATE/STATS/TRANSPOSE/TABLES, that need every
      --  same-key row together regardless of adjacency). Collect the
      --  SELECT-filtered physical row list and hand it to
      --  Table.Partition_By_Key, which groups by key value and sorts only
      --  the resulting group list, never the table.
      Rebuild_Filter_Map;
      for L in 1 .. Tbl.Logical_Row_Count loop
         Physical_Rows.Append (Tbl.Logical_To_Physical (L));
      end loop;
      return Tbl.Partition_By_Key (Physical_Rows);
   end Group_Boundaries;

   --  Gather one column's values across a group's physical rows.
   function Group_Values (Rows : Row_Index_Vectors.Vector; Col : String)
      return Eval.Value_Array
   is
      A : Eval.Value_Array (1 .. Integer (Rows.Length));
      I : Positive := 1;
   begin
      for P of Rows loop
         A (I) := Tbl.Get_Value (P, Col);
         I := I + 1;
      end loop;
      return A;
   end Group_Values;

   --  Emit the active BY variables as the leading output columns (same name and
   --  column type as the source).  Shared schema prologue for the reshape
   --  commands whose BY columns come first (TRANSPOSE, STATS); refactor R4
   --  (commit c94a1c0).  AGGREGATE does NOT use this -- see the design note
   --  above Execute_AGGREGATE for why.
   procedure Add_By_Output_Columns is
   begin
      for I in 1 .. Tbl.By_Var_Count loop
         Tbl.Add_Output_Column
           (Tbl.By_Var_Name (I), Tbl.Get_Column_Type (Tbl.By_Var_Name (I)));
      end loop;
   end Add_By_Output_Columns;

   --  Copy the active BY values into output columns 1 .. By_Var_Count of Row,
   --  reading them from First_Phys (the group's first physical row).  Companion
   --  to Add_By_Output_Columns; the BY columns are always the leading ones.
   procedure Set_By_Output_Values (Row : Positive; First_Phys : Positive) is
   begin
      for I in 1 .. Tbl.By_Var_Count loop
         Tbl.Set_Output_Value_By_Col
           (Row, I, Tbl.Get_Value (First_Phys, Tbl.By_Var_Name (I)));
      end loop;
   end Set_By_Output_Values;

   --  Shared post-swap epilogue for the reshape commands (AGGREGATE, TRANSPOSE,
   --  STATS).  Commits the freshly-built output table, drops the now-stale
   --  SELECT index map, refreshes PDV names and re-detects subscripted columns
   --  (ADR-041), flushes any pending SAVE, then tears down the consumed SELECT
   --  filter and BY grouping.  Cmd_Name names the calling command for the
   --  SAVE-flush error message.  All three commands finalize through here so the
   --  sequence lives in exactly one place (milestone 2026-07-06 refactor R1).
   procedure Commit_Reshaped_Table (Cmd_Name : String) is
   begin
      SData_Core.Table.Commit_Output_Table;
      SData_Core.Table.Clear_Index_Map;     --  stale SELECT map no longer valid
      SData_Core.Variables.Refresh_PDV_Names;
      SData_Core.Variables.Resolve_Column_Array_Collisions;  --  ADR-0025
      SData_Core.Variables.Register_Subscripted_Columns;  --  ADR-041 re-detect

      if SData_Core.Config.Runtime.Save_File_Active then
         begin
            Flush_Pending_Save;
         exception
            when E : others =>
               raise SData_Core.Script_Error with
                 Cmd_Name & ": SAVE flush failed: " &
                 Ada.Exceptions.Exception_Message (E);
         end;
      end if;

      Execute_SELECT (null);                --  free the stale filter expression
      SData_Core.Table.Clear_By_Vars;       --  grouping consumed
   end Commit_Reshaped_Table;

   --  AGGREGATE -- summary statistics by BY group (ADR-046).  Body
   --  extracted to its own subunit (SOFTWARE_STANDARDS_REVIEW.md section 1
   --  finding: shared-command facade concentration) -- see
   --  sdata_core-commands-execute_aggregate.adb for the design note and
   --  implementation.
   procedure Execute_AGGREGATE (Specs : Aggregate_Spec_Vectors.Vector)
     is separate;

   --  TRANSPOSE -- reshape columns to rows (ADR-047).  Body extracted to
   --  its own subunit (SOFTWARE_STANDARDS_REVIEW.md section 1 finding) --
   --  see sdata_core-commands-execute_transpose.adb.
   procedure Execute_TRANSPOSE (Options : Transpose_Options)
     is separate;

   --------------------------------------------------------------------
   --  Stat_Display_Name                                               --
   --------------------------------------------------------------------
   function Stat_Display_Name (S : Stat_Request) return String is
      U : constant String := To_Upper (To_String (S.Name));
   begin
      if S.Has_Pctl_Value then
         return U & Ada.Strings.Fixed.Trim
                       (S.Pctl_Value'Image, Ada.Strings.Left);
      else
         return U;
      end if;
   end Stat_Display_Name;

   --------------------------------------------------------------------
   --  Execute_STATS                                                  --
   --------------------------------------------------------------------
   --  Computes summary statistics for the chosen (or, by default, all
   --  numeric) variables.  Produces one output row per (active BY group x
   --  variable), with one column per requested statistic.  Mirrors
   --  AGGREGATE's "validate -> scan -> build -> swap -> flush SAVE -> clear
   --  SELECT/BY" structure.  All validation precedes any side effect.
   procedure Execute_STATS (Options : Stats_Options) is
      package Tbl  renames SData_Core.Table;
      package Vars renames SData_Core.Variables;

      type Var_Rec is record
         Name    : Unbounded_String;
         Is_Char : Boolean;
      end record;
      package Var_Recs is new Ada.Containers.Vectors (Positive, Var_Rec);

      Stats : Stat_Request_Vectors.Vector;
      Vlist : Var_Recs.Vector;

      function Is_By (Name : String) return Boolean is
      begin
         for I in 1 .. Tbl.By_Var_Count loop
            if To_Upper (Tbl.By_Var_Name (I)) = To_Upper (Name) then
               return True;
            end if;
         end loop;
         return False;
      end Is_By;

      procedure Add_Var (Name : String) is
      begin
         Vlist.Append
           ((Name    => To_Unbounded_String (Name),
             Is_Char => Tbl."=" (Tbl.Get_Column_Type (Name), Tbl.Col_String)));
      end Add_Var;
   begin
      --  1. Resolve the statistic list (default N MIN MEAN MAX STD).
      if Options.Stat_List.Is_Empty then
         Stats.Append (Stat_Request'(Name => To_Unbounded_String ("N"), others => <>));
         Stats.Append (Stat_Request'(Name => To_Unbounded_String ("MIN"), others => <>));
         Stats.Append (Stat_Request'(Name => To_Unbounded_String ("MEAN"), others => <>));
         Stats.Append (Stat_Request'(Name => To_Unbounded_String ("MAX"), others => <>));
         Stats.Append (Stat_Request'(Name => To_Unbounded_String ("STD"), others => <>));
      else
         Stats := Options.Stat_List;
      end if;
      for S of Stats loop
         if not Eval.Is_Aggregate (To_String (S.Name)) then
            raise SData_Core.Script_Error with
              "STATS: '" & To_String (S.Name)
              & "' is not a registered aggregate function";
         end if;
      end loop;
      --  Duplicate-display-name check (ADR-075/sdata#93): two PCTL(<p>)
      --  requests with the SAME percentile (or, degenerately, any other
      --  statistic repeated) would otherwise collide on Add_Output_Column
      --  (which silently no-ops on a duplicate name), misaligning every
      --  later column index against Stats' own length. Reject explicitly
      --  rather than silently dropping a requested statistic.
      declare
         Seen : Name_Sets.Set;
      begin
         for S of Stats loop
            declare
               D : constant String := Stat_Display_Name (S);
            begin
               if Seen.Contains (D) then
                  raise SData_Core.Script_Error with
                    "STATS: statistic '" & D
                    & "' requested more than once";
               end if;
               Seen.Insert (D);
            end;
         end loop;
      end;

      --  2. Resolve the variable list.
      if Options.Var_List.Is_Empty then
         for I in 1 .. Tbl.Column_Count loop
            declare
               Name : constant String := Tbl.Column_Name (I);
            begin
               if not Is_By (Name)
                 and then not Tbl."=" (Tbl.Get_Column_Type (Name), Tbl.Col_String)
               then
                  Add_Var (Name);
               end if;
            end;
         end loop;
      else
         for V of Options.Var_List loop
            declare
               Name : constant String := To_String (V);
            begin
               if Vars.Has_Array (Name) then
                  declare
                     Lo, Hi : Integer;
                  begin
                     Vars.Get_Array_Bounds (Name, Lo, Hi);
                     for K in Lo .. Hi loop
                        Add_Var (Vars.Get_Array_Element_Column (Name, K));
                     end loop;
                  end;
               elsif Tbl.Has_Column (Name) then
                  Add_Var (Name);
               else
                  raise SData_Core.Script_Error with
                    "STATS: unknown variable '" & Name & "'";
               end if;
            end;
         end loop;
      end if;

      if Vlist.Is_Empty then
         raise SData_Core.Script_Error with
           "STATS: no variables to summarize";
      end if;

      --  3. Type rule: a character variable is valid only if every requested
      --     statistic accepts character input (i.e. only N / NMISS).
      for V of Vlist loop
         if V.Is_Char then
            for S of Stats loop
               if not Eval.Lookup (To_String (S.Name)).Accepts_Character then
                  raise SData_Core.Script_Error with
                    "STATS: statistic '" & Stat_Display_Name (S)
                    & "' cannot be applied to character variable '"
                    & To_String (V.Name) & "'";
               end if;
            end loop;
         end if;
      end loop;

      --  4. Build the output schema: BY vars + _NAME_$ + one col per stat.
      Tbl.Initialize_Output_Table;
      Add_By_Output_Columns;
      Tbl.Add_Output_Column ("_NAME_$", Tbl.Col_String);
      for S of Stats loop
         declare
            U : constant String := Stat_Display_Name (S);
         begin
            Tbl.Add_Output_Column
              (U, (if U = "N" or else U = "NMISS"
                   then Tbl.Col_Integer else Tbl.Col_Numeric));
         end;
      end loop;

      --  5. Scan groups; one output row per (group x variable).
      for G of Group_Boundaries loop
         declare
            First_Phys : constant Positive := G.First_Element;
         begin
            for V of Vlist loop
               Tbl.Add_Output_Row;
               declare
                  R   : constant Positive := Tbl.Output_Row_Count;
                  Col : Positive := 1;
                  --  Materialize the group's column values ONCE; every
                  --  statistic reads the same vector (was rebuilt per statistic).
                  Vals : constant Eval.Value_Array :=
                    Group_Values (G, To_String (V.Name));
               begin
                  Set_By_Output_Values (R, First_Phys);
                  Col := Tbl.By_Var_Count + 1;
                  Tbl.Set_Output_Value_By_Col
                    (R, Col,
                     (Kind => Val_String, Str_Val => V.Name));
                  Col := Col + 1;
                  for S of Stats loop
                     --  ADR-075/sdata#93: a PCTL(<p>) request appends its
                     --  percentile as the TRAILING element of a fresh copy
                     --  of Vals (Ada array concatenation is non-destructive
                     --  -- the shared Vals above, reused by every OTHER
                     --  entry in this same loop, is never mutated). Every
                     --  other statistic's Call_Function call is unchanged.
                     Tbl.Set_Output_Value_By_Col
                       (R, Col,
                        Eval.Call_Function
                          (To_String (S.Name),
                           (if S.Has_Pctl_Value
                            then Eval."&"
                                   (Vals,
                                    Value'(Kind    => Val_Integer,
                                           Int_Val => Int (S.Pctl_Value)))
                            else Vals)));
                     Col := Col + 1;
                  end loop;
               end;
            end loop;
         end;
      end loop;

      --  6. Commit, re-register arrays, flush SAVE, clear SELECT/BY.
      Commit_Reshaped_Table ("STATS");
   end Execute_STATS;

   procedure Execute_Commit_Step (Flush_Save : Boolean := True) is
   begin
      Rebuild_Filter_Map;
      if Flush_Save then
         Flush_Pending_Save;
      end if;
      Flush_Pending_Output_Table;
   end Execute_Commit_Step;

   --------------------------------------------------------------------
   --  Execute_RUN                                                    --
   --------------------------------------------------------------------
   procedure Execute_RUN is
   begin
      Execute_Commit_Step;
   end Execute_RUN;

   --------------------------------------------------------------------
   --  Execute_Rebuild_Filter                                         --
   --------------------------------------------------------------------
   procedure Execute_Rebuild_Filter is
   begin
      Rebuild_Filter_Map;
   end Execute_Rebuild_Filter;

   --------------------------------------------------------------------
   --  Interpreter-state mutators                                     --
   --  (see spec for the rationale and validation contract)           --
   --------------------------------------------------------------------

   --------------------------------------------------------------------
   --  Execute_REPEAT                                                 --
   --------------------------------------------------------------------
   procedure Execute_REPEAT (Count : Natural) is
   begin
      if Count = 0 then
         SData_Core.Config.Runtime.End_Repeat;
      else
         SData_Core.Config.Runtime.Internal.Set_Repeat (Count);
      end if;
   end Execute_REPEAT;

   --------------------------------------------------------------------
   --  Execute_NEW                                                    --
   --------------------------------------------------------------------
   procedure Execute_NEW is
   begin
      SData_Core.Config.Runtime.Reset;
   end Execute_NEW;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_CSVDLM                                         --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_CSVDLM (Value : String) is
   begin
      if Value'Length = 0 then
         raise SData_Core.Script_Error with
            "OPTIONS CSVDLM value cannot be empty";
      end if;
      if Value'Length > Max_Delimiter_Len then
         raise SData_Core.Script_Error with
            "OPTIONS CSVDLM value too long (max" &
            Natural'Image (Max_Delimiter_Len) & " chars)";
      end if;
      SData_Core.Config.Runtime.Internal.Set_Options_CSVDLM (Value);
   end Execute_OPTIONS_CSVDLM;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_Header                                         --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_Header (Value : Boolean) is
   begin
      SData_Core.Config.Runtime.Internal.Set_Options_Header (Value);
   end Execute_OPTIONS_Header;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_SAVEOVERWRT                                    --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_SAVEOVERWRT (Value : Boolean) is
   begin
      SData_Core.Config.Runtime.Internal.Set_Options_SAVEOVERWRT (Value);
   end Execute_OPTIONS_SAVEOVERWRT;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_TXTFMT                                         --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_TXTFMT (Value : String) is
   begin
      if Value'Length = 0 then
         raise SData_Core.Script_Error with
            "OPTIONS TXTFMT value cannot be empty";
      end if;
      if Value'Length > Max_Delimiter_Len then
         raise SData_Core.Script_Error with
            "OPTIONS TXTFMT value too long (max" &
            Natural'Image (Max_Delimiter_Len) & " chars)";
      end if;
      SData_Core.Config.Runtime.Internal.Set_Options_TXTFMT (Value);
   end Execute_OPTIONS_TXTFMT;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_CHARSET                                        --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_CHARSET (Value : String) is
   begin
      if Value'Length > Max_Charset_Len then
         raise SData_Core.Script_Error with
            "OPTIONS CHARSET value too long (max" &
            Natural'Image (Max_Charset_Len) & " chars)";
      end if;
      SData_Core.Config.Runtime.Internal.Set_Options_CHARSET (Value);
   end Execute_OPTIONS_CHARSET;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_IEEE_Divide                                    --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_IEEE_Divide (Value : Boolean) is
   begin
      SData_Core.Config.Runtime.Internal.Set_IEEE_Divide (Value);
   end Execute_OPTIONS_IEEE_Divide;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_Shell_Timeout                                  --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_Shell_Timeout (Value : Natural) is
   begin
      SData_Core.Config.Runtime.Internal.Set_Options_Shell_Timeout (Value);
   end Execute_OPTIONS_Shell_Timeout;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_Join_Warn_Threshold                            --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_Join_Warn_Threshold (Value : Natural) is
   begin
      SData_Core.Config.Runtime.Internal.Set_Options_Join_Warn_Threshold (Value);
   end Execute_OPTIONS_Join_Warn_Threshold;

   --------------------------------------------------------------------
   --  Execute_Record_Error                                           --
   --------------------------------------------------------------------
   procedure Execute_Record_Error (Code : Natural; Line : Natural) is
   begin
      SData_Core.Config.Runtime.Internal.Set_Last_Error (Code, Line);
   end Execute_Record_Error;

   --------------------------------------------------------------------
   --  Warn_Reserved_Columns                                         --
   --------------------------------------------------------------------
   procedure Warn_Reserved_Columns (Keywords : Reserved_Keyword_Sets.Set) is
   begin
      if not SData_Core.Config.Runtime.Options_Warn_Reserved then
         return;
      end if;
      for I in 1 .. SData_Core.Table.Column_Count loop
         declare
            Upper : constant String := To_Upper (SData_Core.Table.Column_Name (I));
         begin
            if Keywords.Contains (Upper) then
               SData_Core.IO.Put_Line_Error
                 ("warning: column """ & Upper
                  & """ matches a reserved keyword; reference it as `"
                  & Upper & "` or rename it");
            end if;
         end;
      end loop;
   end Warn_Reserved_Columns;

   --------------------------------------------------------------------
   --  Execute_OPTIONS_WarnReserved                                  --
   --------------------------------------------------------------------
   procedure Execute_OPTIONS_WarnReserved (Value : Boolean) is
   begin
      SData_Core.Config.Runtime.Internal.Set_Options_Warn_Reserved (Value);
   end Execute_OPTIONS_WarnReserved;

end SData_Core.Commands;
