--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Wide_Wide_Characters.Handling;

package body SData_Core.Evaluator.UTF8 is

   procedure Char_At
      (S : String; I : Positive; Len : out Positive; CP : out Natural)
   is
      function Cont (K : Positive) return Boolean is
        (K <= S'Last and then Character'Pos (S (K)) in 16#80# .. 16#BF#);
      B0 : constant Natural := Character'Pos (S (I));
      B1 : Natural;
   begin
      Len := 1;
      CP  := 0;
      if B0 < 16#C2# or else B0 > 16#F4# or else I = S'Last then
         return;
      end if;
      B1 := Character'Pos (S (I + 1));
      if B0 <= 16#DF# then
         if Cont (I + 1) then
            Len := 2;
            CP  := (B0 - 16#C0#) * 64 + (B1 - 16#80#);
         end if;
      elsif B0 <= 16#EF# then
         if Cont (I + 1) and then Cont (I + 2)
            and then not (B0 = 16#E0# and then B1 < 16#A0#)
            and then not (B0 = 16#ED# and then B1 > 16#9F#)
         then
            Len := 3;
            CP  := (B0 - 16#E0#) * 4096 + (B1 - 16#80#) * 64
                   + (Character'Pos (S (I + 2)) - 16#80#);
         end if;
      else
         if Cont (I + 1) and then Cont (I + 2) and then Cont (I + 3)
            and then not (B0 = 16#F0# and then B1 < 16#90#)
            and then not (B0 = 16#F4# and then B1 > 16#8F#)
         then
            Len := 4;
            CP  := (B0 - 16#F0#) * 262144 + (B1 - 16#80#) * 4096
                   + (Character'Pos (S (I + 2)) - 16#80#) * 64
                   + (Character'Pos (S (I + 3)) - 16#80#);
         end if;
      end if;
   end Char_At;

   function Count_Chars (S : String) return Natural is
      I : Natural := S'First;
      N : Natural := 0;
      L : Positive;
      C : Natural;
   begin
      while I <= S'Last loop
         Char_At (S, I, L, C);
         I := I + L;
         N := N + 1;
      end loop;
      return N;
   end Count_Chars;

   --  1-based byte index of character number N (S'Last + 1 when N is one past
   --  the end or beyond).
   function Byte_Of_Char (S : String; N : Positive) return Positive is
      I : Natural := S'First;
      K : Natural := 1;
      L : Positive;
      C : Natural;
   begin
      while I <= S'Last and then K < N loop
         Char_At (S, I, L, C);
         I := I + L;
         K := K + 1;
      end loop;
      return I;
   end Byte_Of_Char;

   --  Number of the character that contains byte B (0 when B is 0).
   function Char_Of_Byte (S : String; B : Natural) return Natural is
      I : Natural := S'First;
      K : Natural := 0;
      L : Positive;
      C : Natural;
   begin
      if B = 0 then return 0; end if;
      while I <= S'Last and then I <= B loop
         Char_At (S, I, L, C);
         I := I + L;
         K := K + 1;
      end loop;
      return K;
   end Char_Of_Byte;

   --  Characters First .. Last (1-based, inclusive, clipped to the string).
   function Slice_Chars (S : String; First, Last : Integer) return String is
      F : constant Integer := Integer'Max (First, 1);
      N : constant Natural := Count_Chars (S);
      L : constant Integer := Integer'Min (Last, N);
   begin
      if F > L then return ""; end if;
      declare
         B1 : constant Positive := Byte_Of_Char (S, F);
         B2 : constant Natural  :=
            (if L >= N then S'Last else Byte_Of_Char (S, L + 1) - 1);
      begin
         return S (B1 .. B2);
      end;
   end Slice_Chars;

   --  Upper- or lower-case a UTF-8 string by code point.  ASCII is mapped
   --  directly; well-formed multi-byte characters through Unicode simple case
   --  mapping; anything else is left alone.
   function Map_Case (S : String; Upper : Boolean) return String is
      use Ada.Wide_Wide_Characters.Handling;
      Result : Unbounded_String;
      I      : Natural := S'First;
      L      : Positive;
      C      : Natural;
   begin
      while I <= S'Last loop
         Char_At (S, I, L, C);
         if L = 1 then
            declare
               Ch : constant Character := S (I);
            begin
               if Character'Pos (Ch) >= 128 then
                  Append (Result, Ch);
               elsif Upper then
                  Append (Result, (if Ch in 'a' .. 'z'
                     then Character'Val (Character'Pos (Ch) - 32) else Ch));
               else
                  Append (Result, (if Ch in 'A' .. 'Z'
                     then Character'Val (Character'Pos (Ch) + 32) else Ch));
               end if;
            end;
         else
            declare
               WC : constant Wide_Wide_Character :=
                  Wide_Wide_Character'Val (C);
               M  : constant Wide_Wide_Character :=
                  (if Upper then To_Upper (WC) else To_Lower (WC));
            begin
               Append (Result,
                  Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Encode
                     (Wide_Wide_String'(1 => M)));
            exception
               when others => Append (Result, S (I .. I + L - 1));
            end;
         end if;
         I := I + L;
      end loop;
      return To_String (Result);
   end Map_Case;

end SData_Core.Evaluator.UTF8;
