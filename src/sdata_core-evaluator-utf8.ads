--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  UTF-8 helpers shared by the string-function families (F25, 2026-10-19
--  stress test).  Strings are byte sequences that are UTF-8 by convention
--  (design.md: UTF-8 is a portable charset).  LEN, LEFT$, RIGHT$, MID$, SEG$,
--  POS, INSTR, INDEX, MATCH and the case functions work in characters (code
--  points), never splitting a multi-byte sequence.  A byte that does not begin
--  a well-formed UTF-8 sequence (e.g. Latin-1 data) counts as one character
--  and is passed through unchanged, so non-UTF-8 text degrades to byte
--  behaviour instead of failing.
private package SData_Core.Evaluator.UTF8 is

   --  Byte length of the character starting at S (I), and its code point when
   --  it is a well-formed multi-byte sequence (CP = 0 and Len = 1 otherwise).
   procedure Char_At
      (S : String; I : Positive; Len : out Positive; CP : out Natural);

   function Count_Chars (S : String) return Natural;

   --  1-based byte index of character number N (S'Last + 1 when N is one past
   --  the end or beyond).
   function Byte_Of_Char (S : String; N : Positive) return Positive;

   --  Number of the character that contains byte B (0 when B is 0).
   function Char_Of_Byte (S : String; B : Natural) return Natural;

   --  Characters First .. Last (1-based, inclusive, clipped to the string).
   function Slice_Chars (S : String; First, Last : Integer) return String;

   --  Upper- or lower-case by code point: ASCII directly, well-formed
   --  multi-byte characters through Unicode simple case mapping, anything
   --  else unchanged.
   function Map_Case (S : String; Upper : Boolean) return String;

end SData_Core.Evaluator.UTF8;
