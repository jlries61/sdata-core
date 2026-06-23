--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;        use Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;          use Ada.Strings.Unbounded;
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
         if not SData_Core.Config.Quiet_Mode then
            SData_Core.IO.Put_Line
              ("Dataset saved: " &
               SData_Core.Config.Runtime.Output_Table_Path
                  (1 .. SData_Core.Config.Runtime.Output_Table_Len));
         end if;
      exception
         when SData_Core.File_IO.Save_Refused => null;
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
                (1 .. SData_Core.Config.Runtime.Save_Charset_Len));
         if not SData_Core.Config.Quiet_Mode then
            SData_Core.IO.Put_Line
              ("Dataset saved: " &
               SData_Core.Config.Runtime.Save_File_Path
                  (1 .. SData_Core.Config.Runtime.Save_File_Len));
         end if;
      exception
         when SData_Core.File_IO.Save_Refused => null;
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
      Is_Mock     : Boolean := False)
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
            Nscan_Rows);
      end;

      --  Final progress total for the load (per-row ticks are emitted inside
      --  each format reader); no-op unless --progress is set.
      SData_Core.IO.Show_Progress
        ("USE", SData_Core.Table.Row_Count, Final => True);

      SData_Core.Variables.Refresh_PDV_Names;
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
      Charset      : String  := "")
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
      for N of Names loop
         Keep.Include (To_Upper (To_String (N)));
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
   begin
      for N of Names loop
         declare
            Col : constant String := To_Upper (To_String (N));
         begin
            if SData_Core.Table.Has_Column (Col) then
               SData_Core.Table.Drop_Column (Col);
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

   package Row_Vectors  is new Ada.Containers.Vectors (Positive, Positive);

   procedure Execute_AGGREGATE (Specs : Aggregate_Spec_Vectors.Vector) is

      package Tbl renames SData_Core.Table;
      package Vars renames SData_Core.Variables;
      package Eval renames SData_Core.Evaluator;

      --  Specs with each bare-name (Invar_Scalar) input resolved against the
      --  live array registry: a name that is a registered array becomes
      --  Invar_Array_Name (applied element-wise).  The parser cannot make this
      --  decision because in batch mode the registry is empty until USE runs.
      Resolved : Aggregate_Spec_Vectors.Vector;

      function Img (N : Integer) return String is
        (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

      function Ends_Dollar (S : String) return Boolean is
        (S'Length > 0 and then S (S'Last) = '$');

      --  Physical input column(s) backing a spec (empty for Invar_Empty).
      function First_Input_Column (Spec : Aggregate_Spec) return String is
      begin
         case Spec.Invar_Kind is
            when Invar_Empty =>
               return "";
            when Invar_Scalar =>
               return To_String (Spec.Invar_Name);
            when Invar_Array_Element =>
               return Vars.Get_Array_Element_Column
                        (To_String (Spec.Invar_Name), Spec.Invar_Index);
            when Invar_Array_Name =>
               declare
                  Lo, Hi : Integer;
               begin
                  Vars.Get_Array_Bounds (To_String (Spec.Invar_Name), Lo, Hi);
                  return Vars.Get_Array_Element_Column
                           (To_String (Spec.Invar_Name), Lo);
               end;
         end case;
      end First_Input_Column;

      --  True when Fn returns an integer scalar (N / NMISS); else numeric.
      function Returns_Integer (Fn : String) return Boolean is
         U : constant String := To_Upper (Fn);
      begin
         return U = "N" or else U = "NMISS";
      end Returns_Integer;

      --  Output-column descriptor, flattened across BY vars + spec columns.
      type Out_Source is (Src_By, Src_Count, Src_Fn);
      type Out_Desc is record
         Name   : Unbounded_String;
         Ctype  : Tbl.Column_Type;
         Source : Out_Source;
         By_Idx : Natural := 0;            --  Src_By: 1-based BY-var index
         Fn     : Unbounded_String;        --  Src_Fn: function name
         Col    : Unbounded_String;        --  Src_Fn: physical input column
      end record;
      package Desc_Vectors is new Ada.Containers.Vectors (Positive, Out_Desc);
      Descs : Desc_Vectors.Vector;

      --------------------------------------------------------------
      --  Phase 1 — validation (errors 4..8).  No side effects.    --
      --------------------------------------------------------------
      procedure Validate is
      begin
         for Spec of Resolved loop
            declare
               Fn      : constant String := To_String (Spec.Fn_Name);
               Outvar  : constant String := To_String (Spec.Outvar);
               Meta    : constant Eval.Aggregate_Metadata := Eval.Lookup (Fn);

               procedure Check_Type (Col : String) is
                  T       : constant Tbl.Column_Type := Tbl.Get_Column_Type (Col);
                  Is_Char : constant Boolean := Tbl."=" (T, Tbl.Col_String);
               begin
                  if Is_Char and then not Meta.Accepts_Character then
                     raise SData_Core.Script_Error with
                       "AGGREGATE: function '" & Fn &
                       "' does not accept input of type character";
                  elsif (not Is_Char) and then not Meta.Accepts_Numeric then
                     raise SData_Core.Script_Error with
                       "AGGREGATE: function '" & Fn &
                       "' does not accept input of type numeric";
                  end if;
               end Check_Type;
            begin
               --  #4 / #5 / #6 — input variable existence and type.
               case Spec.Invar_Kind is
                  when Invar_Empty =>
                     null;
                  when Invar_Scalar =>
                     declare
                        Col : constant String := To_String (Spec.Invar_Name);
                     begin
                        if not Tbl.Has_Column (Col) then
                           raise SData_Core.Script_Error with
                             "AGGREGATE: unknown variable '" & Col & "'";
                        end if;
                        Check_Type (Col);
                     end;
                  when Invar_Array_Element =>
                     declare
                        Base   : constant String := To_String (Spec.Invar_Name);
                        Lo, Hi : Integer;
                     begin
                        if not Vars.Has_Array (Base) then
                           raise SData_Core.Script_Error with
                             "AGGREGATE: unknown variable '" & Base & "'";
                        end if;
                        Vars.Get_Array_Bounds (Base, Lo, Hi);
                        if Spec.Invar_Index < Lo
                          or else Spec.Invar_Index > Hi
                        then
                           raise SData_Core.Script_Error with
                             "AGGREGATE: subscript" & Spec.Invar_Index'Image &
                             " out of range for array '" & Base & "' (" &
                             Img (Lo) & ".." & Img (Hi) & ")";
                        end if;
                        Check_Type
                          (Vars.Get_Array_Element_Column (Base, Spec.Invar_Index));
                     end;
                  when Invar_Array_Name =>
                     declare
                        Base   : constant String := To_String (Spec.Invar_Name);
                        Lo, Hi : Integer;
                     begin
                        if not Vars.Has_Array (Base) then
                           raise SData_Core.Script_Error with
                             "AGGREGATE: unknown variable '" & Base & "'";
                        end if;
                        Vars.Get_Array_Bounds (Base, Lo, Hi);
                        Check_Type (Vars.Get_Array_Element_Column (Base, Lo));
                     end;
               end case;

               --  #7 — outvar '$' suffix must match the function's return
               --  type.  No current aggregate returns character, so a '$'
               --  suffix is always a mismatch.
               if Ends_Dollar (Outvar) then
                  raise SData_Core.Script_Error with
                    "AGGREGATE: outvar '" & Outvar &
                    "' suffix mismatch -- function '" & Fn & "' on input '" &
                    To_String (Spec.Invar_Name) & "' returns " &
                    (if Returns_Integer (Fn) then "integer" else "numeric");
               end if;

               --  #8 — outvar collides with an active BY variable.
               for I in 1 .. Tbl.By_Var_Count loop
                  if To_Upper (Outvar) = To_Upper (Tbl.By_Var_Name (I)) then
                     raise SData_Core.Script_Error with
                       "AGGREGATE: outvar '" & Outvar &
                       "' collides with active BY variable";
                  end if;
               end loop;
            end;
         end loop;
      end Validate;

      --------------------------------------------------------------
      --  Phase 2 — build the flattened output-column descriptors. --
      --------------------------------------------------------------
      procedure Build_Descriptors is
      begin
         for I in 1 .. Tbl.By_Var_Count loop
            Descs.Append
              (Out_Desc'(Name   => To_Unbounded_String (Tbl.By_Var_Name (I)),
                         Ctype  => Tbl.Get_Column_Type (Tbl.By_Var_Name (I)),
                         Source => Src_By, By_Idx => I, others => <>));
         end loop;

         for Spec of Resolved loop
            declare
               Fn     : constant String := To_String (Spec.Fn_Name);
               Outvar : constant String := To_String (Spec.Outvar);
               Ct     : constant Tbl.Column_Type :=
                 (if Returns_Integer (Fn) then Tbl.Col_Integer
                  else Tbl.Col_Numeric);
            begin
               case Spec.Invar_Kind is
                  when Invar_Empty =>
                     Descs.Append
                       (Out_Desc'(Name   => To_Unbounded_String (Outvar),
                                  Ctype  => Tbl.Col_Integer,
                                  Source => Src_Count, others => <>));
                  when Invar_Scalar | Invar_Array_Element =>
                     Descs.Append
                       (Out_Desc'(Name   => To_Unbounded_String (Outvar),
                                  Ctype  => Ct, Source => Src_Fn,
                                  Fn     => Spec.Fn_Name,
                                  Col    => To_Unbounded_String
                                              (First_Input_Column (Spec)),
                                  others => <>));
                  when Invar_Array_Name =>
                     declare
                        Base   : constant String := To_String (Spec.Invar_Name);
                        Lo, Hi : Integer;
                     begin
                        Vars.Get_Array_Bounds (Base, Lo, Hi);
                        for K in Lo .. Hi loop
                           Descs.Append
                             (Out_Desc'(Name  => To_Unbounded_String
                                                   (Outvar & "(" & Img (K) & ")"),
                                        Ctype  => Ct, Source => Src_Fn,
                                        Fn     => Spec.Fn_Name,
                                        Col    => To_Unbounded_String
                                          (Vars.Get_Array_Element_Column (Base, K)),
                                        others => <>));
                        end loop;
                     end;
               end case;
            end;
         end loop;
      end Build_Descriptors;

      --------------------------------------------------------------
      --  Warning W1 — outvar pre-exists with a different shape.    --
      --  Emitted before the table is replaced; same-shape pre-     --
      --  existence is silent.                                      --
      --------------------------------------------------------------
      procedure Warn_Resizing is

         procedure Warn (Name, Old_Shape, New_Shape : String) is
         begin
            SData_Core.IO.Put_Line
              ("AGGREGATE: resizing existing variable '" & Name & "' (" &
               Old_Shape & " -> " & New_Shape & ")");
         end Warn;

         function Array_Shape (Lo, Hi : Integer) return String is
           ("array " & Img (Lo) & ".." & Img (Hi));

      begin
         for Spec of Resolved loop
            declare
               Outvar       : constant String := To_String (Spec.Outvar);
               New_Is_Array : constant Boolean :=
                 Spec.Invar_Kind = Invar_Array_Name;
               New_Lo, New_Hi : Integer := 0;
            begin
               if New_Is_Array then
                  Vars.Get_Array_Bounds
                    (To_String (Spec.Invar_Name), New_Lo, New_Hi);
               end if;

               if Vars.Has_Array (Outvar) then
                  declare
                     Old_Lo, Old_Hi : Integer;
                  begin
                     Vars.Get_Array_Bounds (Outvar, Old_Lo, Old_Hi);
                     if not New_Is_Array then
                        Warn (Outvar, Array_Shape (Old_Lo, Old_Hi), "scalar");
                     elsif Old_Lo /= New_Lo or else Old_Hi /= New_Hi then
                        Warn (Outvar, Array_Shape (Old_Lo, Old_Hi),
                              Array_Shape (New_Lo, New_Hi));
                     end if;
                  end;
               elsif Tbl.Has_Column (Outvar) and then New_Is_Array then
                  Warn (Outvar, "scalar", Array_Shape (New_Lo, New_Hi));
               end if;
            end;
         end loop;
      end Warn_Resizing;

      --  Gather one column's values across a group's physical rows.
      function Group_Values (Rows : Row_Vectors.Vector; Col : String)
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

      --  Emit one output row for the completed group.
      procedure Emit_Group (Rows : Row_Vectors.Vector) is
         First_Phys : constant Positive := Rows.First_Element;
         R          : Positive;
      begin
         Tbl.Add_Output_Row;
         R := Tbl.Output_Row_Count;
         for J in Descs.First_Index .. Descs.Last_Index loop
            declare
               D : constant Out_Desc := Descs (J);
            begin
               case D.Source is
                  when Src_By =>
                     Tbl.Set_Output_Value_By_Col
                       (R, J, Tbl.Get_Value (First_Phys,
                                             Tbl.By_Var_Name (D.By_Idx)));
                  when Src_Count =>
                     Tbl.Set_Output_Value_By_Col
                       (R, J, (Kind    => Val_Integer,
                               Int_Val => Integer (Rows.Length)));
                  when Src_Fn =>
                     Tbl.Set_Output_Value_By_Col
                       (R, J, Eval.Call_Function
                                (To_String (D.Fn),
                                 Group_Values (Rows, To_String (D.Col))));
               end case;
            end;
         end loop;
      end Emit_Group;

      Group  : Row_Vectors.Vector;
      Prev_P : Natural := 0;

   begin
      --  Phase 1: validate everything first; raising here leaves the table,
      --  the pending SAVE, and the active SELECT/BY untouched.
      --  Resolve each bare-name input against the live array registry.
      for Spec of Specs loop
         declare
            S : Aggregate_Spec := Spec;
         begin
            if S.Invar_Kind = Invar_Scalar
              and then Vars.Has_Array (To_String (S.Invar_Name))
            then
               S.Invar_Kind := Invar_Array_Name;
            end if;
            Resolved.Append (S);
         end;
      end loop;

      Validate;
      Warn_Resizing;

      --  Phase 2: reflect the active SELECT, then build the output table.
      Rebuild_Filter_Map;
      Build_Descriptors;

      Tbl.Initialize_Output_Table;
      for D of Descs loop
         Tbl.Add_Output_Column (To_String (D.Name), D.Ctype);
      end loop;

      for L in 1 .. Tbl.Logical_Row_Count loop
         declare
            P : constant Positive := Tbl.Logical_To_Physical (L);
         begin
            if L = 1 then
               Group.Append (P);
            elsif Tbl.By_Var_Count = 0
              or else Tbl.In_Same_Group (P, Prev_P)
            then
               Group.Append (P);
            else
               Emit_Group (Group);
               Group.Clear;
               Group.Append (P);
            end if;
            Prev_P := P;
         end;
      end loop;
      if not Group.Is_Empty then
         Emit_Group (Group);
      end if;

      --  Phase 3: commit the fresh table and apply post-execution effects
      --  (spec sec 3.6).
      Tbl.Commit_Output_Table;
      Tbl.Clear_Index_Map;                  --  stale SELECT map no longer valid
      Vars.Refresh_PDV_Names;
      Vars.Register_Subscripted_Columns;    --  ADR-041 array re-detection

      if SData_Core.Config.Runtime.Save_File_Active then
         begin
            Flush_Pending_Save;
         exception
            when E : others =>
               raise SData_Core.Script_Error with
                 "AGGREGATE: SAVE flush failed: " &
                 Ada.Exceptions.Exception_Message (E);
         end;
      end if;

      Execute_SELECT (null);                --  free the stale filter expression
      Tbl.Clear_By_Vars;                    --  grouping consumed
   end Execute_AGGREGATE;

   procedure Execute_Commit_Step is
   begin
      Rebuild_Filter_Map;
      Flush_Pending_Save;
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
