--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Character-set conversion (design.md section 4.1): any character set the
--  system's iconv(3) knows can be used for USE / SAVE / OUTPUT.
--
--  How it works.  Inside SData all text is UTF-8.  Only at the file boundary
--  is text translated, by a Converter -- a pair of iconv descriptors, one for
--  each direction:
--
--    reading   the file's bytes are read whole (on the heap), To_UTF8 turns
--              them into UTF-8, and the CSV reader then splits that text into
--              records exactly as it would for a UTF-8 file;
--    writing   each field is turned from UTF-8 into the external bytes by
--              From_UTF8 as it is written, so a large table is never held in
--              memory twice.
--
--  Plain UTF-8 needs no Converter (Is_UTF8): an explicit CHARSET=UTF-8 is
--  checked for well-formedness instead (First_Invalid_UTF8).  The system call
--  itself is made by sdata_iconv.c, a small C wrapper, because <iconv.h>
--  maps the portable names onto libiconv's on macOS and Windows.
--
--  Byte-order marks.  A reader recognises one at the start of a file (see
--  BOM_UTF32LE / BOM_UTF32BE below, and Ada.Strings.UTF_Encoding for UTF-8
--  and UTF-16).  Some iconv names (UTF-32, UCS-2, ...) write a mark every
--  time they are used; a file is written in many pieces, so From_UTF8 leaves
--  the mark out and the writer emits Preamble once, at the start.

with Ada.Finalization;
with Ada.Strings.Unbounded;
with GNAT.Strings;
with System;

package SData_Core.Charset is

   --  Byte-order marks of UTF-32, as they appear in a file.  (UTF-8 and
   --  UTF-16 have BOM_8, BOM_16LE and BOM_16BE in Ada.Strings.UTF_Encoding.)
   BOM_UTF32LE : constant String :=
      Character'Val (16#FF#) & Character'Val (16#FE#)
      & Character'Val (0) & Character'Val (0);
   BOM_UTF32BE : constant String :=
      Character'Val (0) & Character'Val (0)
      & Character'Val (16#FE#) & Character'Val (16#FF#);

   --  True for the names that mean "UTF-8, no conversion": the empty string,
   --  AUTO, UTF-8 and UTF8 (case-insensitive).
   function Is_UTF8 (Name : String) return Boolean;

   --  True when Name is UTF-8 or a character set the system can convert to
   --  and from UTF-8.
   function Is_Supported (Name : String) return Boolean;

   --  Index of the first byte of S that is not well-formed UTF-8, or 0 when
   --  S is well-formed.
   function First_Invalid_UTF8 (S : String) return Natural;

   function Valid_UTF8 (S : String) return Boolean;

   --  How many bytes at the end of S are the start of a UTF-8 character that
   --  is cut off (0 .. 3).  Lets a reader that works in blocks hold those
   --  bytes back until the rest of the character arrives.
   function Incomplete_Tail (S : String) return Natural;

   type Converter is limited private;

   --  Prepares Conv to translate between UTF-8 and Name.  Raises
   --  Script_Error if the system does not support Name.
   procedure Open (Conv : in out Converter; Name : String);

   --  External bytes -> UTF-8.  Raises Script_Error naming Context and the
   --  character set when Raw contains a byte sequence invalid in it.
   function To_UTF8
     (Conv : Converter; Raw : String; Context : String) return String;

   --  The same, for text too large to return on the stack (whole files): the
   --  result is allocated on the heap and the caller frees it.
   procedure To_UTF8
     (Conv    : Converter;
      Raw     : String;
      Context : String;
      Result  : out GNAT.Strings.String_Access);

   --  UTF-8 -> external bytes.  Raises Script_Error naming Context when Text
   --  has a character the character set cannot represent (Strict), or
   --  substitutes '?' for it (not Strict).
   function From_UTF8
     (Conv    : Converter;
      Text    : String;
      Context : String;
      Strict  : Boolean := True) return String;

   --  Bytes (a byte-order mark) that this character set puts at the start of
   --  every conversion -- UTF-32, UCS-2 and the like -- or "".  From_UTF8
   --  omits them so that a file made of many pieces does not repeat the
   --  mark; the writer emits Preamble once, at the start of the file.
   function Preamble (Conv : Converter) return String;

private

   type Converter is new Ada.Finalization.Limited_Controlled with record
      To_UTF8_CD   : System.Address := System.Null_Address;
      From_UTF8_CD : System.Address := System.Null_Address;
      Name         : Ada.Strings.Unbounded.Unbounded_String;
      Pre          : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding procedure Finalize (Conv : in out Converter);

end SData_Core.Charset;
