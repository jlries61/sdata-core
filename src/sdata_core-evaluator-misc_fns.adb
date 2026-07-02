--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;
with Ada.Numerics;
with Ada.Calendar;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Variables; use SData_Core.Variables;
with SData_Core.Config;
with SData_Core.Config.Runtime;
with SData_Core.System;
with SData_Core.IO; use SData_Core.IO;
with SData_Core.Values; use SData_Core.Values;

package body SData_Core.Evaluator.Misc_Fns is

   function Handle_Missing (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if Integer (Vals.Length) < 1 then return (Kind => Val_Missing); end if;
      declare
         V : constant Value := Vals.Element (1);
      begin
         if V.Kind = Val_Missing or else (V.Kind = Val_String and then Length (V.Str_Val) = 0) then
            return (Kind => Val_Integer, Int_Val => 1);
         else
            return (Kind => Val_Integer, Int_Val => 0);
         end if;
      end;
   end Handle_Missing;

   function Handle_Inf_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if Integer (Vals.Length) < 1 then return (Kind => Val_Integer, Int_Val => 0); end if;
      declare
         V : constant Value := Vals.Element (1);
      begin
         if V.Kind = Val_Numeric and then SData_Core.Values.Is_Inf (V.Num_Val) then
            return (Kind => Val_Integer, Int_Val => 1);
         else
            return (Kind => Val_Integer, Int_Val => 0);
         end if;
      end;
   end Handle_Inf_Fn;

   function Handle_False (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => 0);
   end Handle_False;

   function Handle_True (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => 1);
   end Handle_True;

   function Handle_Err_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => SData_Core.Config.Runtime.Last_Error_Code);
   end Handle_Err_Fn;

   function Handle_Erl_Fn (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => SData_Core.Config.Runtime.Last_Error_Line);
   end Handle_Erl_Fn;

   function Handle_Date (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
      R   : Value (Val_String);
      Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Y   : Ada.Calendar.Year_Number;
      Mo  : Ada.Calendar.Month_Number;
      D   : Ada.Calendar.Day_Number;
      Sec : Ada.Calendar.Day_Duration;
      Buf : String (1 .. 10);
   begin
      Ada.Calendar.Split (Now, Y, Mo, D, Sec);
      declare
         use Ada.Strings.Fixed;
         YS : constant String := Y'Image;
         MS : constant String := (if Mo < 10 then "0" else "") & Trim (Mo'Image, Ada.Strings.Both);
         DS : constant String := (if D  < 10 then "0" else "") & Trim (D'Image,  Ada.Strings.Both);
      begin
         Buf := YS (YS'Last - 3 .. YS'Last) & "-" & MS & "-" & DS;
      end;
      R.Str_Val := To_Unbounded_String (Buf);
      return R;
   end Handle_Date;

   function Handle_Time (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
      R         : Value (Val_String);
      Now       : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Y         : Ada.Calendar.Year_Number;
      Mo        : Ada.Calendar.Month_Number;
      D         : Ada.Calendar.Day_Number;
      Sec       : Ada.Calendar.Day_Duration;
      Total_Sec : Natural;
      H, Mi, S  : Natural;
      Buf       : String (1 .. 8);
   begin
      Ada.Calendar.Split (Now, Y, Mo, D, Sec);
      Total_Sec := Natural (Float'Floor (Float (Sec)));
      H  := Total_Sec / 3600;
      Mi := (Total_Sec mod 3600) / 60;
      S  := Total_Sec mod 60;
      declare
         use Ada.Strings.Fixed;
         HS  : constant String := (if H  < 10 then "0" else "") & Trim (H'Image,  Ada.Strings.Both);
         MiS : constant String := (if Mi < 10 then "0" else "") & Trim (Mi'Image, Ada.Strings.Both);
         SS  : constant String := (if S  < 10 then "0" else "") & Trim (S'Image,  Ada.Strings.Both);
      begin
         Buf := HS & ":" & MiS & ":" & SS;
      end;
      R.Str_Val := To_Unbounded_String (Buf);
      return R;
   end Handle_Time;

   function Handle_Shell (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      if SData_Core.Config.Disable_Shell then
         Put_Line_Error ("Error: SHELL function is disabled.");
         return (Kind => Val_Missing);
      end if;
      declare
         Command : constant String := SData_Core.Values.To_String (Vals.Element (1));
         Success : Boolean;
      begin
         SData_Core.System.Shell_Execute (Command, Success);
         return (Kind => Val_Integer, Int_Val => (if Success then 0 else 1));
      end;
   end Handle_Shell;

   function Handle_Num (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare V : constant Value := Vals.Element (1);
      begin
         if V.Kind = Val_Numeric or else V.Kind = Val_Integer then
            return V;
         elsif V.Kind = Val_String then
            begin
               return (Kind    => Val_Numeric,
                       Num_Val => Float'Value (SData_Core.Values.To_String (V)));
            exception
               when Constraint_Error => return (Kind => Val_Missing);
            end;
         else
            return (Kind => Val_Missing);
         end if;
      end;
   end Handle_Num;

   function Handle_Pi (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return Num_Result (Ada.Numerics.Pi);
   end Handle_Pi;

   function Handle_Timer (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return Num_Result (Float (Ada.Calendar.Seconds (Ada.Calendar.Clock)));
   end Handle_Timer;

   function Handle_Truncate (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         X      : constant Float   := Convert_To_Float (Vals.Element (1));
         Places : constant Integer := Integer (Convert_To_Float (Vals.Element (2)));
         Factor : constant Float   := 10.0 ** Float (Places);
      begin
         if Places < 0 then return (Kind => Val_Missing); end if;
         return Num_Result (Float'Truncation (X * Factor) / Factor);
      end;
   end Handle_Truncate;

   function Handle_Lbound (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if Integer (Vals.Length) < 1 or else Vals.Element (1).Kind /= Val_String then
         return (Kind => Val_Missing);
      end if;
      declare
         AName              : constant String := SData_Core.Values.To_String (Vals.Element (1));
         Start_Idx, End_Idx : Integer;
      begin
         Get_Array_Bounds (AName, Start_Idx, End_Idx);
         if End_Idx < Start_Idx then return (Kind => Val_Missing); end if;
         return (Kind => Val_Integer, Int_Val => Start_Idx);
      end;
   end Handle_Lbound;

   function Handle_Ubound (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if Integer (Vals.Length) < 1 or else Vals.Element (1).Kind /= Val_String then
         return (Kind => Val_Missing);
      end if;
      declare
         AName              : constant String := SData_Core.Values.To_String (Vals.Element (1));
         Start_Idx, End_Idx : Integer;
      begin
         Get_Array_Bounds (AName, Start_Idx, End_Idx);
         if End_Idx < Start_Idx then return (Kind => Val_Missing); end if;
         return (Kind => Val_Integer, Int_Val => End_Idx);
      end;
   end Handle_Ubound;

   function Handle_Index_Str (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         Haystack : constant Value := Vals.Element (1);
         Needle   : constant Value := Vals.Element (2);
      begin
         if Haystack.Kind /= Val_String or else Needle.Kind /= Val_String then
            return (Kind => Val_Missing);
         end if;
         if Length (Needle.Str_Val) = 0 then return (Kind => Val_Integer, Int_Val => 1); end if;
         return (Kind    => Val_Integer,
                 Int_Val => Index (Haystack.Str_Val, SData_Core.Values.To_String (Needle)));
      end;
   end Handle_Index_Str;

   function Handle_Match (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      declare
         Haystack : constant Value   := Vals.Element (1);
         Needle   : constant Value   := Vals.Element (2);
         Start    : constant Integer := Integer (Convert_To_Float (Vals.Element (3)));
         H_Str    : constant String  := SData_Core.Values.To_String (Haystack);
         N_Str    : constant String  := SData_Core.Values.To_String (Needle);
         From     : constant Positive := Positive'Max (Start, 1);
      begin
         if Haystack.Kind /= Val_String or else Needle.Kind /= Val_String then
            return (Kind => Val_Missing);
         end if;
         if From > H_Str'Length or else N_Str'Length = 0 then
            return (Kind => Val_Integer, Int_Val => (if N_Str'Length = 0 then From else 0));
         end if;
         return (Kind    => Val_Integer,
                 Int_Val => Ada.Strings.Fixed.Index (H_Str, N_Str, From));
      end;
   end Handle_Match;

   function Handle_Maxlen (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => SData_Core.Config.Max_String_Len);
   end Handle_Maxlen;

   function Handle_Maxlvl (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => 1_000);
   end Handle_Maxlvl;

   function Handle_Maxint (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => Integer'Last);
   end Handle_Maxint;

   function Handle_Maxnum (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return Num_Result (Float'Last);
   end Handle_Maxnum;

   function Handle_Minint (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => Integer'First);
   end Handle_Minint;

   function Handle_Minnum (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return Num_Result (Float'Model_Small);
   end Handle_Minnum;

   function Handle_Rad (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (Convert_To_Float (Vals.Element (1)) * Ada.Numerics.Pi / 180.0);
   end Handle_Rad;

   --  LTW(X) — Lambert W function W₀(x), principal branch (x ≥ -1/e).
   --  Uses Halley's method; typically converges in 5-10 iterations.
   function Handle_Ltw (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      E_Inv : constant Float := 1.0 / Ada.Numerics.e;
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare
         X : constant Float := Convert_To_Float (Vals.Element (1));
         W : Float;
         EW, WEW, F, Fp, Fpp : Float;
      begin
         if X < -E_Inv then
            return Handle_Domain_Error ("LTW: argument must be >= -1/e (~-0.3679).");
         end if;
         if X = 0.0 then return Num_Result (0.0); end if;
         if X >= 0.0 then
            W := Log (1.0 + X);
         else
            W := -1.0 + Sqrt (2.0 * (1.0 + Ada.Numerics.e * X));
         end if;
         for I in 1 .. 100 loop
            EW  := Exp (W);
            WEW := W * EW;
            F   := WEW - X;
            Fp  := EW * (W + 1.0);
            Fpp := EW * (W + 2.0);
            declare
               Denom : constant Float := Fp - F * Fpp / (2.0 * Fp);
            begin
               exit when abs Denom < Float'Model_Small;
               declare Step : constant Float := F / Denom;
               begin
                  W := W - Step;
                  exit when abs Step < Float'Epsilon * abs W + Float'Model_Small;
               end;
            end;
         end loop;
         return Num_Result (W);
      end;
   end Handle_Ltw;

   ---------------------------------------------------------------------------

   procedure Register is
   begin
      Dispatch_Table.Insert ("MISSING", Handle_Missing'Access);
      Dispatch_Table.Insert ("INF",     Handle_Inf_Fn'Access);
      Dispatch_Table.Insert ("FALSE",   Handle_False'Access);
      Dispatch_Table.Insert ("TRUE",    Handle_True'Access);
      Dispatch_Table.Insert ("DATE$",   Handle_Date'Access);
      Dispatch_Table.Insert ("TIME$",   Handle_Time'Access);
      Dispatch_Table.Insert ("SHELL",   Handle_Shell'Access);
      Dispatch_Table.Insert ("NUM",     Handle_Num'Access);
      Dispatch_Table.Insert ("ERR",     Handle_Err_Fn'Access);
      Dispatch_Table.Insert ("ERL",     Handle_Erl_Fn'Access);
      Dispatch_Table.Insert ("PI",      Handle_Pi'Access);
      Dispatch_Table.Insert ("TIMER",   Handle_Timer'Access);
      Dispatch_Table.Insert ("TRUNCATE", Handle_Truncate'Access);
      Dispatch_Table.Insert ("LBOUND",  Handle_Lbound'Access);
      Dispatch_Table.Insert ("UBOUND",  Handle_Ubound'Access);
      Dispatch_Table.Insert ("HBOUND",  Handle_Ubound'Access);
      Dispatch_Table.Insert ("INDEX",   Handle_Index_Str'Access);
      Dispatch_Table.Insert ("MATCH",   Handle_Match'Access);
      Dispatch_Table.Insert ("MAXLEN",  Handle_Maxlen'Access);
      Dispatch_Table.Insert ("MAXLVL",  Handle_Maxlvl'Access);
      Dispatch_Table.Insert ("MAXINT",  Handle_Maxint'Access);
      Dispatch_Table.Insert ("MAXNUM",  Handle_Maxnum'Access);
      Dispatch_Table.Insert ("MININT",  Handle_Minint'Access);
      Dispatch_Table.Insert ("MINNUM",  Handle_Minnum'Access);
      Dispatch_Table.Insert ("RAD",     Handle_Rad'Access);
      Dispatch_Table.Insert ("RADIAN",  Handle_Rad'Access);
      Dispatch_Table.Insert ("LTW",     Handle_Ltw'Access);

      --  Arity metadata (one entry per Dispatch_Table insert above).
      Register_Arity ("MISSING",  1, 1);
      Register_Arity ("INF",      1, 1);
      Register_Arity ("FALSE",    0, 0);
      Register_Arity ("TRUE",     0, 0);
      Register_Arity ("DATE$",    0, 0);
      Register_Arity ("TIME$",    0, 0);
      Register_Arity ("SHELL",    1, 1);
      Register_Arity ("NUM",      1, 1);
      Register_Arity ("ERR",      0, 0);
      Register_Arity ("ERL",      0, 0);
      Register_Arity ("PI",       0, 0);
      Register_Arity ("TIMER",    0, 0);
      Register_Arity ("TRUNCATE", 2, 2);   -- TRUNCATE(x,places)
      Register_Arity ("LBOUND",   1, 1);   -- identifier-ref (array name)
      Register_Arity ("UBOUND",   1, 1);   -- identifier-ref (array name)
      Register_Arity ("HBOUND",   1, 1);   -- identifier-ref (array name)
      Register_Arity ("INDEX",    2, 2);   -- INDEX(haystack$,needle$)
      Register_Arity ("MATCH",    3, 3);   -- MATCH(haystack$,needle$,start)
      Register_Arity ("MAXLEN",   1, 1);   -- MAXLEN(A$)
      Register_Arity ("MAXLVL",   0, 0);
      Register_Arity ("MAXINT",   0, 0);
      Register_Arity ("MAXNUM",   0, 0);
      Register_Arity ("MININT",   0, 0);
      Register_Arity ("MINNUM",   0, 0);
      Register_Arity ("RAD",      1, 1);
      Register_Arity ("RADIAN",   1, 1);
      Register_Arity ("LTW",      1, 1);
   end Register;

begin
   Register;
end SData_Core.Evaluator.Misc_Fns;