--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with SData_Core.Real_Functions; use SData_Core.Real_Functions;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Values; use SData_Core.Values;

package body SData_Core.Evaluator.Aggregate_Fns is

   type Stats_Pass_Result is record
      N_Count     : Natural    := 0;
      NMISS_Count : Natural    := 0;
      Sum         : Long_Float := 0.0;
      Sum_Sq      : Long_Float := 0.0;
      Min_V       : Long_Float := 0.0;
      Max_V       : Long_Float := 0.0;
      Has_Values  : Boolean    := False;
   end record;

   function Compute_Stats_Pass (Vals : Value_Vectors.Vector) return Stats_Pass_Result is
      R : Stats_Pass_Result;
   begin
      for V of Vals loop
         if V.Kind = Val_Missing then
            R.NMISS_Count := R.NMISS_Count + 1;
         else
            declare FV : constant Long_Float := Long_Float (Convert_To_Float (V));
            begin
               R.N_Count := R.N_Count + 1;
               R.Sum     := R.Sum + FV;
               R.Sum_Sq  := R.Sum_Sq + FV ** 2;
               if not R.Has_Values then
                  R.Min_V := FV; R.Max_V := FV; R.Has_Values := True;
               else
                  if FV < R.Min_V then R.Min_V := FV; end if;
                  if FV > R.Max_V then R.Max_V := FV; end if;
               end if;
            end;
         end if;
      end loop;
      return R;
   end Compute_Stats_Pass;

   function Handle_Sum (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : constant Stats_Pass_Result := Compute_Stats_Pass (Vals);
   begin
      if R.N_Count = 0 then return (Kind => Val_Missing); end if;
      return Numeric_Result_Checked (Real (R.Sum));
   end Handle_Sum;

   function Handle_Mean (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : constant Stats_Pass_Result := Compute_Stats_Pass (Vals);
   begin
      if R.N_Count = 0 then return (Kind => Val_Missing); end if;
      return Numeric_Result_Checked (Real (R.Sum / Long_Float (R.N_Count)));
   end Handle_Mean;

   function Handle_Var_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R  : constant Stats_Pass_Result := Compute_Stats_Pass (Vals);
      NF : Long_Float;
   begin
      if R.N_Count < 2 then return (Kind => Val_Missing); end if;
      NF := Long_Float (R.N_Count);
      return Numeric_Result_Checked
         (Real ((R.Sum_Sq - (R.Sum ** 2 / NF)) / (NF - 1.0)));
   end Handle_Var_Fn;

   function Handle_Std_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R  : constant Stats_Pass_Result := Compute_Stats_Pass (Vals);
      NF : Long_Float;
   begin
      if R.N_Count < 2 then return (Kind => Val_Missing); end if;
      NF := Long_Float (R.N_Count);
      return Numeric_Result_Checked
         (Sqrt (Real ((R.Sum_Sq - (R.Sum ** 2 / NF)) / (NF - 1.0))));
   end Handle_Std_Fn;

   function Handle_Min_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : constant Stats_Pass_Result := Compute_Stats_Pass (Vals);
   begin
      if R.N_Count = 0 then return (Kind => Val_Missing); end if;
      return (Kind => Val_Numeric, Num_Val => Real (R.Min_V));
   end Handle_Min_Fn;

   function Handle_Max_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      R : constant Stats_Pass_Result := Compute_Stats_Pass (Vals);
   begin
      if R.N_Count = 0 then return (Kind => Val_Missing); end if;
      return (Kind => Val_Numeric, Num_Val => Real (R.Max_V));
   end Handle_Max_Fn;

   function Handle_N_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      Count : Integer := 0;
   begin
      for V of Vals loop
         if not (V.Kind = Val_Missing
                 or else (V.Kind = Val_String and then Length (V.Str_Val) = 0))
         then
            Count := Count + 1;
         end if;
      end loop;
      return (Kind => Val_Integer, Int_Val => Count);
   end Handle_N_Fn;

   function Handle_Nmiss_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      Count : Integer := 0;
   begin
      for V of Vals loop
         if V.Kind = Val_Missing or else (V.Kind = Val_String and then Length (V.Str_Val) = 0) then
            Count := Count + 1;
         end if;
      end loop;
      return (Kind => Val_Integer, Int_Val => Count);
   end Handle_Nmiss_Fn;

   function Handle_Gmean (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      Log_Sum : Long_Float := 0.0;
      N_Count : Natural   := 0;
   begin
      for V of Vals loop
         if V.Kind /= Val_Missing then
            declare FV : constant Real := Convert_To_Float (V);
            begin
               if FV <= 0.0 then return (Kind => Val_Missing); end if;
               Log_Sum := Log_Sum + Long_Float (Log (FV));
               N_Count := N_Count + 1;
            end;
         end if;
      end loop;
      if N_Count = 0 then return (Kind => Val_Missing); end if;
      return Num_Result (Exp (Real (Log_Sum / Long_Float (N_Count))));
   end Handle_Gmean;

   function Handle_Hmean (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      Recip_Sum : Long_Float := 0.0;
      N_Count   : Natural   := 0;
   begin
      for V of Vals loop
         if V.Kind /= Val_Missing then
            declare FV : constant Long_Float := Long_Float (Convert_To_Float (V));
            begin
               if FV = 0.0 then return (Kind => Val_Missing); end if;
               Recip_Sum := Recip_Sum + 1.0 / FV;
               N_Count   := N_Count + 1;
            end;
         end if;
      end loop;
      if N_Count = 0 then return (Kind => Val_Missing); end if;
      return Num_Result (Real (Long_Float (N_Count) / Recip_Sum));
   end Handle_Hmean;

   function Handle_Median (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      package Float_Vecs is new Ada.Containers.Vectors (Positive, Real);
      package Float_Sort  is new Float_Vecs.Generic_Sorting;
      FVals   : Float_Vecs.Vector;
      N_Count : Natural := 0;
   begin
      for I in 1 .. Integer (Vals.Length) loop
         declare V : constant Value := Vals.Element (I);
         begin
            if V.Kind /= Val_Missing then
               FVals.Append (Convert_To_Float (V));
               N_Count := N_Count + 1;
            end if;
         end;
      end loop;
      if N_Count = 0 then return (Kind => Val_Missing); end if;
      Float_Sort.Sort (FVals);
      if N_Count mod 2 = 1 then
         return Num_Result (FVals.Element ((N_Count + 1) / 2));
      else
         return Num_Result ((FVals.Element (N_Count / 2) + FVals.Element (N_Count / 2 + 1)) / 2.0);
      end if;
   end Handle_Median;

   ---------------------------------------------------------------------------

   procedure Register is
      --  Numeric-only aggregates: accept numeric input, reject character.
      Num  : constant Aggregate_Metadata := (Accepts_Numeric   => True,
                                             Accepts_Character => False);
      --  N and NMISS additionally accept character input (they count rows /
      --  count missings regardless of value type).
      Both : constant Aggregate_Metadata := (Accepts_Numeric   => True,
                                             Accepts_Character => True);
   begin
      Dispatch_Table.Insert ("SUM",    Handle_Sum'Access);
      Dispatch_Table.Insert ("MEAN",   Handle_Mean'Access);
      Dispatch_Table.Insert ("STD",    Handle_Std_Fn'Access);
      Dispatch_Table.Insert ("VAR",    Handle_Var_Fn'Access);
      Dispatch_Table.Insert ("MIN",    Handle_Min_Fn'Access);
      Dispatch_Table.Insert ("MAX",    Handle_Max_Fn'Access);
      Dispatch_Table.Insert ("N",      Handle_N_Fn'Access);
      Dispatch_Table.Insert ("NMISS",  Handle_Nmiss_Fn'Access);
      Dispatch_Table.Insert ("GMEAN",  Handle_Gmean'Access);
      Dispatch_Table.Insert ("HMEAN",  Handle_Hmean'Access);
      Dispatch_Table.Insert ("MEDIAN", Handle_Median'Access);

      --  Paired aggregate-only type metadata (per ADR-046 / architect C1).
      Aggregate_Meta_Table.Insert ("SUM",    Num);
      Aggregate_Meta_Table.Insert ("MEAN",   Num);
      Aggregate_Meta_Table.Insert ("STD",    Num);
      Aggregate_Meta_Table.Insert ("VAR",    Num);
      Aggregate_Meta_Table.Insert ("MIN",    Num);
      Aggregate_Meta_Table.Insert ("MAX",    Num);
      Aggregate_Meta_Table.Insert ("N",      Both);
      Aggregate_Meta_Table.Insert ("NMISS",  Both);
      Aggregate_Meta_Table.Insert ("GMEAN",  Num);
      Aggregate_Meta_Table.Insert ("HMEAN",  Num);
      Aggregate_Meta_Table.Insert ("MEDIAN", Num);

      --  Arity metadata.  Aggregates are variadic (row-wise across the whole
      --  argument list / a whole group column), so Max is Natural'Last.  Most
      --  need at least one value; N and NMISS additionally accept the zero-arg
      --  form (N() is the group row count), hence Min = 0 for those.
      Register_Arity ("SUM",    1, Natural'Last);
      Register_Arity ("MEAN",   1, Natural'Last);
      Register_Arity ("STD",    1, Natural'Last);
      Register_Arity ("VAR",    1, Natural'Last);
      Register_Arity ("MIN",    1, Natural'Last);
      Register_Arity ("MAX",    1, Natural'Last);
      Register_Arity ("N",      0, Natural'Last);
      Register_Arity ("NMISS",  0, Natural'Last);
      Register_Arity ("GMEAN",  1, Natural'Last);
      Register_Arity ("HMEAN",  1, Natural'Last);
      Register_Arity ("MEDIAN", 1, Natural'Last);
   end Register;

begin
   Register;
end SData_Core.Evaluator.Aggregate_Fns;