--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--------------------------------------------------------------------
--  Execute_TRANSPOSE                                              --
--------------------------------------------------------------------
--  Reshapes the current table: each transposed input column becomes one
--  output row.  Direct sibling of Execute_AGGREGATE; mirrors its
--  "validate -> scan the SELECT-filtered logical view -> build a fresh
--  output table -> swap -> flush a pending SAVE -> clear SELECT and BY"
--  structure verbatim.  All validation precedes any side effect; the
--  scan-phase errors (#6/#7/#10 on /ID values) abort before the output
--  table is committed.  See ADR-047 and the design spec (sec 3-4).
separate (SData_Core.Commands)
procedure Execute_TRANSPOSE (Options : Transpose_Options) is

   package Tbl  renames SData_Core.Table;
   package Vars renames SData_Core.Variables;

   function Img (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));

   function Ends_Dollar (S : String) return Boolean is
     (S'Length > 0 and then S (S'Last) = '$');

   --  Effective options after defaults (spec sec 2).
   Id_Mode    : constant Boolean := Options.Has_Id;
   Name_Col   : constant String :=
     (if Length (Options.Name_Col) = 0 then "_NAME_$"
      else To_String (Options.Name_Col));
   Array_Name : constant String :=
     (if Options.Has_Array then To_String (Options.Array_Name) else "_X_");
   Id_Col     : constant String := To_String (Options.Id_Col);

   --  UTF-8 em dash (U+2014) for the #11 message, built from its
   --  bytes so the source itself stays 7-bit ASCII.
   Em_Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#)
     & Character'Val (16#94#);

   --  Resolved transposed set, in input-schema order.
   T_Set : Tbl.Name_Vectors.Vector;

   --  Uniform type of the transposed set.
   Set_Is_Char : Boolean := False;
   Set_Type    : Tbl.Column_Type := Tbl.Col_Numeric;

   --  /ID union: derived output-column names in first-encounter order.
   package Id_Vectors is new Ada.Containers.Vectors
     (Positive, Unbounded_String);
   Id_Union : Id_Vectors.Vector;
   Id_Seen  : Name_Sets.Set;             --  upper(colname) membership

   --  /ID block -> output-column-position lookup.
   package Name_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Positive,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   --  Active BY-variable upper-names (exclusion + collision checks).
   By_Set : Name_Sets.Set;

   --  /ARRAY bound (max block size) and filtered row count.
   K      : Natural := 0;
   N_Rows : Natural := 0;

   --  Consecutive BY groups of the SELECT-filtered view (Phase 2 assigns;
   --  Phases 2 and 3 both iterate it).  Empty <=> N_Rows = 0.
   Groups : Row_Group_Vectors.Vector;

   --  Legal column identifier: letter|'_' first; letter|digit|'_' rest;
   --  an optional single trailing '$'.
   function Is_Legal_Identifier (S : String) return Boolean is
      Last : Integer := S'Last;
   begin
      if S'Length = 0 then
         return False;
      end if;
      if S (S'Last) = '$' then
         Last := S'Last - 1;
         if Last < S'First then
            return False;          --  "$" alone is not legal
         end if;
      end if;
      if not (Is_Letter (S (S'First)) or else S (S'First) = '_') then
         return False;
      end if;
      for I in S'First .. Last loop
         if not (Is_Alphanumeric (S (I)) or else S (I) = '_') then
            return False;
         end if;
      end loop;
      return True;
   end Is_Legal_Identifier;

   --  Output column name for a raw /ID value (spec sec 3.5).  A character
   --  transposed set forces a trailing '$' (added if absent); a numeric
   --  set leaves the value as-is (a '$'-terminated value is rejected as
   --  error #7 by the scan).
   function Id_Column_Name (Raw : String) return String is
     (if Set_Is_Char and then not Ends_Dollar (Raw) then Raw & "$"
      else Raw);

   procedure Raise_Collision (Name, Source : String) is
   begin
      raise SData_Core.Script_Error with
        "TRANSPOSE: output column name '" & Name &
        "' collides with " & Source;
   end Raise_Collision;

   --  Expand a /KEEP or /DROP name to its physical column(s), upper-cased,
   --  into Target.  Validates error #4.
   procedure Add_Var_To_Set
     (Raw : String; Which : String; Target : in out Name_Sets.Set) is
   begin
      if Vars.Has_Array (Raw) then
         declare
            Lo, Hi : Integer;
         begin
            Vars.Get_Array_Bounds (Raw, Lo, Hi);
            for I in Lo .. Hi loop
               Target.Include
                 (To_Upper (Vars.Get_Array_Element_Column (Raw, I)));
            end loop;
         end;
      elsif Tbl.Has_Column (Raw) then
         Target.Include (To_Upper (Raw));
      else
         raise SData_Core.Script_Error with
           "TRANSPOSE: unknown variable '" & Raw & "' in /" & Which;
      end if;
   end Add_Var_To_Set;

begin
   ------------------------------------------------------------------
   --  Phase 1 — validation only.  No side effects, no output table. --
   ------------------------------------------------------------------
   for I in 1 .. Tbl.By_Var_Count loop
      By_Set.Include (To_Upper (Tbl.By_Var_Name (I)));
   end loop;

   --  #4 (KEEP then DROP) and #5 (/ID exists); then resolve the
   --  transposed set in input-schema order: (KEEP) \ DROP \ {ID} \ BY.
   declare
      Keep_Set : Name_Sets.Set;
      Drop_Set : Name_Sets.Set;
      Use_Keep : constant Boolean := not Options.Keep_List.Is_Empty;
      Id_Upper : constant String :=
        (if Id_Mode then To_Upper (Id_Col) else "");
   begin
      for N of Options.Keep_List loop
         Add_Var_To_Set (To_String (N), "KEEP", Keep_Set);
      end loop;
      for N of Options.Drop_List loop
         Add_Var_To_Set (To_String (N), "DROP", Drop_Set);
      end loop;

      if Id_Mode and then not Tbl.Has_Column (Id_Col) then
         raise SData_Core.Script_Error with
           "TRANSPOSE: /ID column '" & Id_Col & "' does not exist";
      end if;

      for I in 1 .. Tbl.Column_Count loop
         declare
            Col   : constant String := Tbl.Column_Name (I);
            Upper : constant String := To_Upper (Col);
         begin
            if (not Use_Keep or else Keep_Set.Contains (Upper))
              and then not Drop_Set.Contains (Upper)
              and then not By_Set.Contains (Upper)
              and then (not Id_Mode or else Upper /= Id_Upper)
            then
               T_Set.Append (To_Unbounded_String (Col));
            end if;
         end;
      end loop;
   end;

   --  #8 — type uniformity; derive Set_Type.
   declare
      First : Boolean := True;
   begin
      for C of T_Set loop
         declare
            Is_Char : constant Boolean := Tbl."="
              (Tbl.Get_Column_Type (To_String (C)), Tbl.Col_String);
         begin
            if First then
               Set_Is_Char := Is_Char;
               First := False;
            elsif Is_Char /= Set_Is_Char then
               raise SData_Core.Script_Error with
                 "TRANSPOSE: columns to transpose must share a type " &
                 "(numeric or character); got mixed";
            end if;
         end;
      end loop;
      Set_Type := (if Set_Is_Char then Tbl.Col_String else Tbl.Col_Numeric);
   end;

   --  #9 — transposed set must be non-empty.
   if T_Set.Is_Empty then
      raise SData_Core.Script_Error with
        "TRANSPOSE: no columns to transpose (transposed set is empty)";
   end if;

   --  #11 — /ARRAY name '$'-suffix must match the set's type.
   if not Id_Mode then
      if Set_Is_Char and then not Ends_Dollar (Array_Name) then
         raise SData_Core.Script_Error with
           "TRANSPOSE: /ARRAY name '" & Array_Name &
           "' type mismatch " & Em_Dash & " transposed set is character";
      elsif not Set_Is_Char and then Ends_Dollar (Array_Name) then
         raise SData_Core.Script_Error with
           "TRANSPOSE: /ARRAY name '" & Array_Name &
           "' type mismatch " & Em_Dash & " transposed set is numeric";
      end if;
   end if;

   --  #10 (static part) — Name_Col / Array_Name collisions with BY vars
   --  and with each other.  /ID-value collisions are detected as the
   --  union is built (below), still before the output table is committed.
   declare
      Name_Upper : constant String := To_Upper (Name_Col);
   begin
      if By_Set.Contains (Name_Upper) then
         Raise_Collision (Name_Col, "active BY variable");
      end if;
      if not Id_Mode then
         declare
            Arr_Upper : constant String := To_Upper (Array_Name);
         begin
            if By_Set.Contains (Arr_Upper) then
               Raise_Collision (Array_Name, "active BY variable");
            elsif Arr_Upper = Name_Upper then
               Raise_Collision (Array_Name, "the /NAME column");
            end if;
         end;
      end if;
   end;

   ------------------------------------------------------------------
   --  Phase 2 — reflect SELECT, then pre-scan the logical view.     --
   ------------------------------------------------------------------
   Groups := Group_Boundaries;
   N_Rows := Tbl.Logical_Row_Count;

   --  Pre-scan: /ARRAY -> K (max block size); /ID -> union of derived
   --  column names (first-encounter), with per-block duplicate detection
   --  (#6), legal-identifier validation (#7) and BY/NAME collision (#10).
   if not Groups.Is_Empty then
      declare
         Block_First : Positive := 1;
         Block_Ids   : Name_Sets.Set;

         function By_Group_Desc return String is
            R : Unbounded_String;
         begin
            for I in 1 .. Tbl.By_Var_Count loop
               if I > 1 then
                  Append (R, ", ");
               end if;
               Append (R, Tbl.By_Var_Name (I) & "=" &
                       To_String (Tbl.Get_Value
                         (Block_First, Tbl.By_Var_Name (I))));
            end loop;
            return To_String (R);
         end By_Group_Desc;

         procedure Scan_Id (P : Positive) is
            Raw     : constant String :=
              To_String (Tbl.Get_Value (P, Id_Col));
            Colname : constant String := Id_Column_Name (Raw);
            Upper   : constant String := To_Upper (Colname);
         begin
            if not Is_Legal_Identifier (Colname) then
               raise SData_Core.Script_Error with
                 "TRANSPOSE: /ID value '" & Raw &
                 "' is not a legal column identifier";
            end if;
            if Block_Ids.Contains (Upper) then
               raise SData_Core.Script_Error with
                 "TRANSPOSE: duplicate /ID value '" & Raw &
                 "' in BY group " & By_Group_Desc;
            end if;
            Block_Ids.Include (Upper);
            if not Id_Seen.Contains (Upper) then
               if By_Set.Contains (Upper) then
                  Raise_Collision (Colname, "active BY variable");
               elsif Upper = To_Upper (Name_Col) then
                  Raise_Collision (Colname, "the /NAME column");
               end if;
               Id_Seen.Include (Upper);
               Id_Union.Append (To_Unbounded_String (Colname));
            end if;
         end Scan_Id;
      begin
         for G of Groups loop
            if Natural (G.Length) > K then
               K := Natural (G.Length);
            end if;
            if Id_Mode then
               Block_First := G.First_Element;
               Block_Ids.Clear;
               for P of G loop
                  Scan_Id (P);
               end loop;
            end if;
         end loop;
      end;
   end if;

   ------------------------------------------------------------------
   --  Phase 3 — build the fresh output table and emit rows.         --
   ------------------------------------------------------------------
   Tbl.Initialize_Output_Table;
   Add_By_Output_Columns;
   Tbl.Add_Output_Column (Name_Col, Tbl.Col_String);

   --  Value columns exist only for non-empty input (spec sec 3.7).
   if N_Rows > 0 then
      if Id_Mode then
         for V of Id_Union loop
            Tbl.Add_Output_Column (To_String (V), Set_Type);
         end loop;
      else
         for J in 1 .. K loop
            Tbl.Add_Output_Column
              (Array_Name & "(" & Img (J) & ")", Set_Type);
         end loop;
      end if;

      declare
         Name_Pos : constant Positive := Tbl.By_Var_Count + 1;

         --  Emit one output row per transposed column for the block.
         procedure Emit_Block (Group : Row_Index_Vectors.Vector) is
            First_P : constant Positive := Group.First_Element;
            Id_Pos  : Name_Maps.Map;     --  upper(colname) -> phys row
            R       : Positive;
         begin
            if Id_Mode then
               for P of Group loop
                  Id_Pos.Include
                    (To_Upper (Id_Column_Name
                       (To_String (Tbl.Get_Value (P, Id_Col)))), P);
               end loop;
            end if;

            for C of T_Set loop
               declare
                  Cn : constant String := To_String (C);
               begin
                  Tbl.Add_Output_Row;
                  R := Tbl.Output_Row_Count;
                  Set_By_Output_Values (R, First_P);
                  Tbl.Set_Output_Value_By_Col
                    (R, Name_Pos,
                     (Kind => Val_String, Str_Val => To_Unbounded_String (Cn)));
                  if Id_Mode then
                     for U in Id_Union.First_Index .. Id_Union.Last_Index loop
                        declare
                           Up : constant String :=
                             To_Upper (To_String (Id_Union (U)));
                        begin
                           if Id_Pos.Contains (Up) then
                              Tbl.Set_Output_Value_By_Col
                                (R, Name_Pos + U,
                                 Tbl.Get_Value (Id_Pos.Element (Up), Cn));
                           end if;
                        end;
                     end loop;
                  else
                     for J in Group.First_Index .. Group.Last_Index loop
                        Tbl.Set_Output_Value_By_Col
                          (R, Name_Pos + J, Tbl.Get_Value (Group (J), Cn));
                     end loop;
                  end if;
               end;
            end loop;
         end Emit_Block;
      begin
         for G of Groups loop
            Emit_Block (G);
         end loop;
      end;
   end if;

   ------------------------------------------------------------------
   --  Phase 4 — commit the fresh table and apply side effects.      --
   ------------------------------------------------------------------
   Commit_Reshaped_Table ("TRANSPOSE");
end Execute_TRANSPOSE;
