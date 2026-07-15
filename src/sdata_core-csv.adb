--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Strings;
with Ada.Strings.Fixed;     use Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Values;

package body SData_Core.CSV is

   --  Fast decimal parser: handles integers and simple N.M decimals
   --  without invoking the Ada runtime.  Scientific notation and other
   --  edge cases fall through to Real'Value.
   --  Returns True and sets Result for any valid floating-point value.
   --  Returns False only if the string cannot represent a number.
   function Try_Fast_Float (S : String; Result : out Real) return Boolean is
      T         : constant String := Ada.Strings.Fixed.Trim (S, Ada.Strings.Both);
      I         : Integer := T'First;
      Whole     : Real   := 0.0;
      Frac      : Real   := 0.0;
      Denom     : Real   := 1.0;
      Sign      : Real   := 1.0;
      After_Dot : Boolean := False;
      Has_Digit : Boolean := False;
      TU        : String (T'Range);
   begin
      for K in T'Range loop TU (K) := Ada.Characters.Handling.To_Upper (T (K)); end loop;
      if TU = "INF" or else TU = "+INF" or else TU = "INFINITY" or else TU = "+INFINITY" then
         Result := SData_Core.Values.Pos_Inf;
         return True;
      elsif TU = "-INF" or else TU = "-INFINITY" then
         Result := SData_Core.Values.Neg_Inf;
         return True;
      end if;
      if I > T'Last then return False; end if;
      if    T (I) = '-' then Sign := -1.0; I := I + 1;
      elsif T (I) = '+' then               I := I + 1;
      end if;
      while I <= T'Last loop
         case T (I) is
            when '0' .. '9' =>
               Has_Digit := True;
               if After_Dot then
                  Denom := Denom * 10.0;
                  Frac  := Frac + Real (Character'Pos (T (I)) - 48) / Denom;
               else
                  Whole := Whole * 10.0 + Real (Character'Pos (T (I)) - 48);
               end if;
            when '.' =>
               if After_Dot then return False; end if;
               After_Dot := True;
            when 'E' | 'e' | 'D' | 'd' =>
               begin
                  Result := Real'Value (T);
                  return True;
               exception
                  when Constraint_Error => return False;
               end;
            when others => return False;
         end case;
         I := I + 1;
      end loop;
      if not Has_Digit then return False; end if;
      Result := Sign * (Whole + Frac);
      return True;
   end Try_Fast_Float;

   function Is_Numeric_Field (F : String) return Boolean is
      Dummy : Real;
   begin
      return Try_Fast_Float (F, Dummy);
   end Is_Numeric_Field;

   function At_Delimiter (Line      : String;
                           Pos       : Positive;
                           Delimiter : String) return Boolean is
      DLen : constant Positive := Delimiter'Length;
   begin
      if Pos + DLen - 1 > Line'Last then return False; end if;
      if DLen = 1 then return Line (Pos) = Delimiter (Delimiter'First); end if;
      return Line (Pos .. Pos + DLen - 1) = Delimiter;
   end At_Delimiter;

   function CSV_Field_End (Line      : String;
                            From      : Positive;
                            Delimiter : String) return Natural is
      I : Positive := From;
      Q : Character;
   begin
      if I > Line'Last then return 0; end if;
      if Line (I) = '"' or else Line (I) = ''' then
         Q := Line (I);
         I := I + 1;
         while I <= Line'Last loop
            if Line (I) = Q then
               if I < Line'Last and then Line (I + 1) = Q then
                  I := I + 2;   --  doubled quote → literal
               else
                  I := I + 1;   --  closing quote
                  exit;
               end if;
            else
               I := I + 1;
            end if;
         end loop;
         --  After the closing quote, the next chars must be the delimiter.
         if At_Delimiter (Line, I, Delimiter) then return I; end if;
         return 0;
      else
         for K in From .. Line'Last loop
            if At_Delimiter (Line, K, Delimiter) then return K; end if;
         end loop;
         return 0;
      end if;
   end CSV_Field_End;

   function CSV_Unquote (Raw : String) return String is
      T : constant String := Trim (Raw, Ada.Strings.Both);
      Q : Character;
      R : Unbounded_String;
      I : Positive;
   begin
      if T'Length >= 2
         and then (T (T'First) = '"' or else T (T'First) = ''')
         and then T (T'Last) = T (T'First)
      then
         Q := T (T'First);
         I := T'First + 1;
         while I <= T'Last - 1 loop
            if T (I) = Q and then I < T'Last - 1 and then T (I + 1) = Q then
               Append (R, Q);
               I := I + 2;
            else
               Append (R, T (I));
               I := I + 1;
            end if;
         end loop;
         return To_String (R);
      end if;
      return T;
   end CSV_Unquote;

   procedure Split_Indices (Line      : String;
                             Delimiter : String;
                             Fields    : in out Field_Vectors.Vector) is
      Start : Integer  := Line'First;
      DLen  : constant Positive := Delimiter'Length;
   begin
      Fields.Clear;
      if Line'Length = 0 then return; end if;
      loop
         declare
            Delim : constant Natural := CSV_Field_End (Line, Start, Delimiter);
         begin
            Fields.Append
               ((S => Start,
                 E => (if Delim > 0 then Delim - 1 else Line'Last)));
            exit when Delim = 0;
            Start := Delim + DLen;
         end;
      end loop;
   end Split_Indices;

end SData_Core.CSV;