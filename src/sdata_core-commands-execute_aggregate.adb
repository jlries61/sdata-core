--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Design note: AGGREGATE deliberately does NOT use Add_By_Output_Columns /
--  Set_By_Output_Values (compare Execute_TRANSPOSE / Execute_STATS, which
--  do).  AGGREGATE's Build_Descriptors/Emit_Group interleave BY columns
--  and function-result columns into one flattened Out_Desc list, because
--  each spec's output position and source (Src_By vs Src_Fn) must line up
--  positionally when Emit_Group walks Descs.  Adopting the positional BY
--  helpers here would mean either abandoning that unified descriptor list
--  (rewriting the emit loop) or bolting the helpers on awkwardly beside it
--  for no behavioral gain -- "contort that design for no gain", per the R4
--  refactor's own reasoning (commit c94a1c0, 2026-07-07) when it extracted
--  those helpers for TRANSPOSE/STATS and explicitly left AGGREGATE alone.
--  Re-confirmed 2026-07-24: a proposal to unify all three reshape
--  commands under one generic template was withdrawn after full
--  inspection reached this same conclusion independently, before
--  finding this prior commit.  See ADR-0008 for the fuller analysis if
--  this reasoning is ever revisited.
separate (SData_Core.Commands)
procedure Execute_AGGREGATE (Specs : Aggregate_Spec_Vectors.Vector) is

   package Vars renames SData_Core.Variables;

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
      Name           : Unbounded_String;
      Ctype          : Tbl.Column_Type;
      Source         : Out_Source;
      By_Idx         : Natural := 0;    --  Src_By: 1-based BY-var index
      Fn             : Unbounded_String; --  Src_Fn: function name
      Col            : Unbounded_String; --  Src_Fn: physical input column
      Has_Pctl_Value : Boolean := False; --  Src_Fn: PCTL(<invar>, <p>)
      Pctl_Value     : Natural := 0;    --  Src_Fn: percentile (0..100)
   end record;
   package Desc_Vectors is new Ada.Containers.Vectors (Positive, Out_Desc);
   Descs : Desc_Vectors.Vector;

   --------------------------------------------------------------
   --  Phase 1 — validation (errors 4..8).  No side effects.    --
   --------------------------------------------------------------
   procedure Validate is
      Seen_Outvars : Name_Sets.Set;
   begin
      for Spec of Resolved loop
         declare
            Outvar  : constant String := To_String (Spec.Outvar);
         begin
            --  #9 (defensive): the sdata parser rejects duplicate outvars,
            --  but Execute_AGGREGATE is public sdata-core API and the output
            --  column build (Emit_Group) assumes one distinct column per
            --  spec — a duplicate base name would misalign columns.  Reject
            --  it here so any direct caller is protected, not just sdata.
            if Seen_Outvars.Contains (To_Upper (Outvar)) then
               raise SData_Core.Script_Error with
                 "AGGREGATE: duplicate outvar name '" & Outvar & "'";
            end if;
            Seen_Outvars.Insert (To_Upper (Outvar));
         end;

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
                    (Out_Desc'(Name           => To_Unbounded_String (Outvar),
                               Ctype          => Ct, Source => Src_Fn,
                               Fn             => Spec.Fn_Name,
                               Col            => To_Unbounded_String
                                           (First_Input_Column (Spec)),
                               Has_Pctl_Value => Spec.Has_Pctl_Value,
                               Pctl_Value     => Spec.Pctl_Value,
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
                                     Has_Pctl_Value => Spec.Has_Pctl_Value,
                                     Pctl_Value     => Spec.Pctl_Value,
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

   --  Emit one output row for the completed group.
   procedure Emit_Group (Rows : Row_Index_Vectors.Vector) is
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
                            Int_Val => Int (Rows.Length)));
               when Src_Fn =>
                  --  ADR-075/sdata#93: PCTL(<invar>, <p>) appends its
                  --  percentile as the TRAILING element of a fresh copy
                  --  of Gather_Group_Values's result (heap copy;
                  --  non-destructive -- Fn_Handler's shared (Name, Vals)
                  --  signature is unchanged). Every other function's
                  --  call is unaffected.
                  declare
                     Base : Group_Vals;
                     Full : Group_Vals;
                  begin
                     Gather_Group_Values (Base, Rows, To_String (D.Col));
                     if D.Has_Pctl_Value then
                        Gather_With_Trailing
                          (Full, Base.Ptr.all,
                           Value'(Kind    => Val_Integer,
                                  Int_Val => Int (D.Pctl_Value)));
                     end if;
                     Tbl.Set_Output_Value_By_Col
                       (R, J, Eval.Call_Function
                                (To_String (D.Fn),
                                 (if D.Has_Pctl_Value then Full.Ptr.all
                                  else Base.Ptr.all)));
                  end;
            end case;
         end;
      end loop;
   end Emit_Group;

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
   Build_Descriptors;

   Tbl.Initialize_Output_Table;
   for D of Descs loop
      Tbl.Add_Output_Column (To_String (D.Name), D.Ctype);
   end loop;

   for G of Group_Boundaries loop
      Emit_Group (G);
   end loop;

   --  Phase 3: commit the fresh table and apply post-execution effects
   --  (spec sec 3.6).
   Commit_Reshaped_Table ("AGGREGATE");
end Execute_AGGREGATE;
