--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Character-set conversion (design.md section 4.1): any character set the
--  system's iconv(3) knows can be used for USE / SAVE / OUTPUT.  Inside SData
--  all text is UTF-8; a Converter translates between that and an external
--  character set at the file boundary.

with Ada.Finalization;
with Ada.Strings.Unbounded;
with GNAT.Strings;
with System;

package SData_Core.Charset is

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

private

   type Converter is new Ada.Finalization.Limited_Controlled with record
      To_UTF8_CD   : System.Address := System.Null_Address;
      From_UTF8_CD : System.Address := System.Null_Address;
      Name         : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding procedure Finalize (Conv : in out Converter);

end SData_Core.Charset;
