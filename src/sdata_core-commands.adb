--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;        use Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;          use Ada.Strings.Unbounded;
with SData_Core.Config.Runtime;
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
      SData_Core.Config.Runtime.Save_File_Active := False;
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
      SData_Core.Config.Runtime.Repeat_Active := False;
      SData_Core.Config.Runtime.Repeat_Count  := 0;

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

      SData_Core.Variables.Refresh_PDV_Names;
      SData_Core.Variables.Register_Subscripted_Columns;
   end Execute_USE;

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
         SData_Core.Config.Runtime.Save_File_Active := False;
         SData_Core.Config.Runtime.Save_File_Len    := 0;
         return;
      end if;

      declare
         Full : constant String := Full_Path (File_Name, "SAVE");
         SLen : constant Natural := Sheet_Name'Length;
         DLen : constant Natural := Delimiter'Length;
         CLen : constant Natural := Charset'Length;
      begin
         SData_Core.Config.Runtime.Save_File_Path := (others => ' ');
         SData_Core.Config.Runtime.Save_File_Path (1 .. Full'Length) := Full;
         SData_Core.Config.Runtime.Save_File_Len := Full'Length;
         SData_Core.Config.Runtime.Save_File_Fmt := Fmt;

         SData_Core.Config.Runtime.Save_Sheet_Name := (others => ' ');
         if SLen > 0 then
            SData_Core.Config.Runtime.Save_Sheet_Name (1 .. SLen) :=
               Sheet_Name;
         end if;
         SData_Core.Config.Runtime.Save_Sheet_Name_Len := SLen;

         SData_Core.Config.Runtime.Save_File_Active := True;

         SData_Core.Config.Runtime.Save_DLM := (others => ' ');
         if DLen > 0 then
            SData_Core.Config.Runtime.Save_DLM (1 .. DLen) := Delimiter;
            SData_Core.Config.Runtime.Save_DLM_Len := DLen;
         else
            SData_Core.Config.Runtime.Save_DLM (1) := ',';
            SData_Core.Config.Runtime.Save_DLM_Len := 1;
         end if;

         SData_Core.Config.Runtime.Save_Header := Write_Header;

         SData_Core.Config.Runtime.Save_Charset := (others => ' ');
         if CLen > 0 then
            SData_Core.Config.Runtime.Save_Charset (1 .. CLen) := Charset;
            SData_Core.Config.Runtime.Save_Charset_Len := CLen;
         else
            SData_Core.Config.Runtime.Save_Charset :=
               SData_Core.Config.Runtime.Options_CHARSET;
            SData_Core.Config.Runtime.Save_Charset_Len :=
               SData_Core.Config.Runtime.Options_CHARSET_Len;
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
         SData_Core.Config.Runtime.FPath_Use    := P;
      end if;
      if Reset_All or else Save_Flag   then
         SData_Core.Config.Runtime.FPath_Save   := P;
      end if;
      if Reset_All or else Submit_Flag then
         SData_Core.Config.Runtime.FPath_Submit := P;
      end if;
      if Reset_All or else Output_Flag then
         SData_Core.Config.Runtime.FPath_Output := P;
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
      if TXTFMT'Length > 0 then
         SData_Core.Config.Runtime.Options_TXTFMT := (others => ' ');
         SData_Core.Config.Runtime.Options_TXTFMT (1 .. TXTFMT'Length) :=
            TXTFMT;
         SData_Core.Config.Runtime.Options_TXTFMT_Len := TXTFMT'Length;
      end if;
      if Charset'Length > 0 then
         SData_Core.Config.Runtime.Options_CHARSET := (others => ' ');
         SData_Core.Config.Runtime.Options_CHARSET (1 .. Charset'Length) :=
            Charset;
         SData_Core.Config.Runtime.Options_CHARSET_Len := Charset'Length;
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
         SData_Core.Config.Runtime.Output_Table_Active := False;
         SData_Core.Config.Runtime.Output_Table_Len    := 0;
         return;
      end if;

      if File_Name'Length > SData_Core.Max_Path_Len then
         raise SData_Core.Script_Error with
            "OUTPUT: path too long: " & File_Name;
      end if;

      SData_Core.Config.Runtime.Output_Table_Path := (others => ' ');
      SData_Core.Config.Runtime.Output_Table_Path
         (1 .. File_Name'Length) := File_Name;
      SData_Core.Config.Runtime.Output_Table_Len := File_Name'Length;
      SData_Core.Config.Runtime.Output_Table_Fmt := Fmt;
      SData_Core.Config.Runtime.Output_Table_Active := True;
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
      SData_Core.Config.Runtime.Select_Filter_Expr := Expr;
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
   --  Execute_RUN                                                    --
   --------------------------------------------------------------------
   procedure Execute_RUN is
   begin
      Rebuild_Filter_Map;
      Flush_Pending_Save;
      Flush_Pending_Output_Table;
   end Execute_RUN;

   --------------------------------------------------------------------
   --  Execute_Rebuild_Filter                                         --
   --------------------------------------------------------------------
   procedure Execute_Rebuild_Filter is
   begin
      Rebuild_Filter_Map;
   end Execute_Rebuild_Filter;

end SData_Core.Commands;
