--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;
with Ada.Numerics;
with SData_Core.Values; use SData_Core.Values;

package body SData_Core.Evaluator.Numeric_Fns is

   ---------------------------------------------------------------------------
   --  Math handlers
   ---------------------------------------------------------------------------

   function Handle_Abs (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      if Vals.Element (1).Kind = Val_Integer then
         return (Kind => Val_Integer, Int_Val => abs Vals.Element (1).Int_Val);
      else
         return Num_Result (abs Convert_To_Float (Vals.Element (1)));
      end if;
   end Handle_Abs;

   function Handle_Log_Nat (Name : String; Vals : Value_Vectors.Vector) return Value is
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V <= 0.0 then
            return Handle_Domain_Error ("Argument to " & Name & " must be positive.");
         end if;
         return Num_Result (Log (V));
      end;
   end Handle_Log_Nat;

   function Handle_Log10_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V <= 0.0 then
            return Handle_Domain_Error ("Argument to " & Name & " must be positive.");
         end if;
         return Num_Result (Log (V, 10.0));
      end;
   end Handle_Log10_Fn;

   function Handle_Log2_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V <= 0.0 then
            return Handle_Domain_Error ("Argument to " & Name & " must be positive.");
         end if;
         return Num_Result (Log (V) / Log (2.0));
      end;
   end Handle_Log2_Fn;

   function Handle_Exp_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V > 88.0 then
            return Handle_Domain_Error ("Argument to " & Name & " is too large (overflow).");
         end if;
         return Num_Result (Exp (V));
      end;
   end Handle_Exp_Fn;

   function Handle_Round_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare
         V        : constant Float := Convert_To_Float (Vals.Element (1));
         Decimals : Float := 0.0;
         Factor   : Float;
      begin
         if Integer (Vals.Length) >= 2 and then Vals.Element (2).Kind /= Val_Missing then
            Decimals := Convert_To_Float (Vals.Element (2));
         end if;
         Factor := 10.0 ** Decimals;
         return Num_Result (Float'Rounding (V * Factor) / Factor);
      end;
   end Handle_Round_Fn;

   function Handle_Ceil_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Float'Ceiling (Convert_To_Float (Vals.Element (1))));
   end Handle_Ceil_Fn;

   function Handle_Floor_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Float'Floor (Convert_To_Float (Vals.Element (1))));
   end Handle_Floor_Fn;

   function Handle_Fix_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Float'Truncation (Convert_To_Float (Vals.Element (1))));
   end Handle_Fix_Fn;

   function Handle_Fp_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin return Num_Result (V - Float'Truncation (V)); end;
   end Handle_Fp_Fn;

   function Handle_Mod_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         V1 : constant Float := Convert_To_Float (Vals.Element (1));
         V2 : constant Float := Convert_To_Float (Vals.Element (2));
      begin
         if V2 /= 0.0 then return Num_Result (V1 - Float'Floor (V1 / V2) * V2);
         else return Handle_Domain_Error ("Division by zero in MOD."); end if;
      end;
   end Handle_Mod_Fn;

   function Handle_Sqrt_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V >= 0.0 then return Num_Result (Sqrt (V));
         else return Handle_Domain_Error ("Argument to SQRT must be non-negative."); end if;
      end;
   end Handle_Sqrt_Fn;

   function Handle_Sgn_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V > 0.0 then return (Kind => Val_Integer, Int_Val => 1);
         elsif V < 0.0 then return (Kind => Val_Integer, Int_Val => -1);
         else return (Kind => Val_Integer, Int_Val => 0);
         end if;
      end;
   end Handle_Sgn_Fn;

   ---------------------------------------------------------------------------
   --  Trig handlers
   ---------------------------------------------------------------------------

   function Handle_Sin_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Sin (Convert_To_Float (Vals.Element (1))));
   end Handle_Sin_Fn;

   function Handle_Cos_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Cos (Convert_To_Float (Vals.Element (1))));
   end Handle_Cos_Fn;

   function Handle_Tan_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Tan (Convert_To_Float (Vals.Element (1))));
   end Handle_Tan_Fn;

   function Handle_Atn_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Arctan (Convert_To_Float (Vals.Element (1))));
   end Handle_Atn_Fn;

   function Handle_Atan2_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (Arctan (Convert_To_Float (Vals.Element (1)),
                                 Convert_To_Float (Vals.Element (2))));
   end Handle_Atan2_Fn;

   function Handle_Sinh_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Sinh (Convert_To_Float (Vals.Element (1))));
   end Handle_Sinh_Fn;

   function Handle_Cosh_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Cosh (Convert_To_Float (Vals.Element (1))));
   end Handle_Cosh_Fn;

   function Handle_Tanh_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Tanh (Convert_To_Float (Vals.Element (1))));
   end Handle_Tanh_Fn;

   function Handle_Hcs_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (1.0 / Cosh (Convert_To_Float (Vals.Element (1))));
   end Handle_Hcs_Fn;

   function Handle_Hsn_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (1.0 / Sinh (Convert_To_Float (Vals.Element (1))));
   end Handle_Hsn_Fn;

   function Handle_Htn_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin return Num_Result (Cosh (V) / Sinh (V)); end;
   end Handle_Htn_Fn;

   function Handle_Arcsin_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V < -1.0 or else V > 1.0 then
            return Handle_Domain_Error ("ARCSIN argument must be in [-1, 1].");
         end if;
         return Num_Result (Arcsin (V));
      end;
   end Handle_Arcsin_Fn;

   function Handle_Arccos_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if V < -1.0 or else V > 1.0 then
            return Handle_Domain_Error ("ARCCOS argument must be in [-1, 1].");
         end if;
         return Num_Result (Arccos (V));
      end;
   end Handle_Arccos_Fn;

   function Handle_Arctan_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Arctan (Convert_To_Float (Vals.Element (1))));
   end Handle_Arctan_Fn;

   function Handle_Cot_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Float := Convert_To_Float (Vals.Element (1));
      begin return Num_Result (Cos (V) / Sin (V)); end;
   end Handle_Cot_Fn;

   function Handle_Csc_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (1.0 / Sin (Convert_To_Float (Vals.Element (1))));
   end Handle_Csc_Fn;

   function Handle_Sec_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (1.0 / Cos (Convert_To_Float (Vals.Element (1))));
   end Handle_Sec_Fn;

   function Handle_Deg_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Convert_To_Float (Vals.Element (1)) * 180.0 / Ada.Numerics.Pi);
   end Handle_Deg_Fn;

   function Handle_Sind_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Sin (Convert_To_Float (Vals.Element (1)) * Ada.Numerics.Pi / 180.0));
   end Handle_Sind_Fn;

   function Handle_Cosd_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Cos (Convert_To_Float (Vals.Element (1)) * Ada.Numerics.Pi / 180.0));
   end Handle_Cosd_Fn;

   function Handle_Tand_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Tan (Convert_To_Float (Vals.Element (1)) * Ada.Numerics.Pi / 180.0));
   end Handle_Tand_Fn;

   function Handle_Atnd_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Arctan (Convert_To_Float (Vals.Element (1))) * 180.0 / Ada.Numerics.Pi);
   end Handle_Atnd_Fn;

   function Handle_Atan2d_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (Arctan (Convert_To_Float (Vals.Element (1)),
                                 Convert_To_Float (Vals.Element (2))) * 180.0 / Ada.Numerics.Pi);
   end Handle_Atan2d_Fn;

   ---------------------------------------------------------------------------

   procedure Register is
   begin
      --  Math
      Dispatch_Table.Insert ("ABS",    Handle_Abs'Access);
      Dispatch_Table.Insert ("LOG",    Handle_Log_Nat'Access);
      Dispatch_Table.Insert ("LN",     Handle_Log_Nat'Access);
      Dispatch_Table.Insert ("LOGE",   Handle_Log_Nat'Access);
      Dispatch_Table.Insert ("LOG10",  Handle_Log10_Fn'Access);
      Dispatch_Table.Insert ("CLG",    Handle_Log10_Fn'Access);
      Dispatch_Table.Insert ("LGT",    Handle_Log10_Fn'Access);
      Dispatch_Table.Insert ("LOG2",   Handle_Log2_Fn'Access);
      Dispatch_Table.Insert ("EXP",    Handle_Exp_Fn'Access);
      Dispatch_Table.Insert ("ROUND",  Handle_Round_Fn'Access);
      Dispatch_Table.Insert ("CEIL",   Handle_Ceil_Fn'Access);
      Dispatch_Table.Insert ("FLOOR",  Handle_Floor_Fn'Access);
      Dispatch_Table.Insert ("INT",    Handle_Floor_Fn'Access);
      Dispatch_Table.Insert ("FIX",    Handle_Fix_Fn'Access);
      Dispatch_Table.Insert ("IP",     Handle_Fix_Fn'Access);
      Dispatch_Table.Insert ("FP",     Handle_Fp_Fn'Access);
      Dispatch_Table.Insert ("FRAC",   Handle_Fp_Fn'Access);
      Dispatch_Table.Insert ("MOD",    Handle_Mod_Fn'Access);
      Dispatch_Table.Insert ("SQRT",   Handle_Sqrt_Fn'Access);
      Dispatch_Table.Insert ("SQR",    Handle_Sqrt_Fn'Access);
      Dispatch_Table.Insert ("SGN",    Handle_Sgn_Fn'Access);
      --  Trigonometry
      Dispatch_Table.Insert ("SIN",    Handle_Sin_Fn'Access);
      Dispatch_Table.Insert ("COS",    Handle_Cos_Fn'Access);
      Dispatch_Table.Insert ("TAN",    Handle_Tan_Fn'Access);
      Dispatch_Table.Insert ("ATN",    Handle_Atn_Fn'Access);
      Dispatch_Table.Insert ("ATAN2",  Handle_Atan2_Fn'Access);
      Dispatch_Table.Insert ("SINH",   Handle_Sinh_Fn'Access);
      Dispatch_Table.Insert ("COSH",   Handle_Cosh_Fn'Access);
      Dispatch_Table.Insert ("TANH",   Handle_Tanh_Fn'Access);
      Dispatch_Table.Insert ("HCS",    Handle_Hcs_Fn'Access);
      Dispatch_Table.Insert ("HSN",    Handle_Hsn_Fn'Access);
      Dispatch_Table.Insert ("HTN",    Handle_Htn_Fn'Access);
      Dispatch_Table.Insert ("ARCSIN", Handle_Arcsin_Fn'Access);
      Dispatch_Table.Insert ("ARCCOS", Handle_Arccos_Fn'Access);
      Dispatch_Table.Insert ("ARCTAN", Handle_Arctan_Fn'Access);
      Dispatch_Table.Insert ("COT",    Handle_Cot_Fn'Access);
      Dispatch_Table.Insert ("CSC",    Handle_Csc_Fn'Access);
      Dispatch_Table.Insert ("SEC",    Handle_Sec_Fn'Access);
      Dispatch_Table.Insert ("DEG",    Handle_Deg_Fn'Access);
      Dispatch_Table.Insert ("DEGREE", Handle_Deg_Fn'Access);
      Dispatch_Table.Insert ("SIND",   Handle_Sind_Fn'Access);
      Dispatch_Table.Insert ("COSD",   Handle_Cosd_Fn'Access);
      Dispatch_Table.Insert ("TAND",   Handle_Tand_Fn'Access);
      Dispatch_Table.Insert ("ATND",   Handle_Atnd_Fn'Access);
      Dispatch_Table.Insert ("ATAN2D", Handle_Atan2d_Fn'Access);
   end Register;

begin
   Register;
end SData_Core.Evaluator.Numeric_Fns;