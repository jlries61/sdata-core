--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body SData_Core.Column_Names is

   function To_Column_Name (S : String) return Column_Name is
   begin
      return (Value => To_Unbounded_String (Ada.Characters.Handling.To_Upper (S)));
   end To_Column_Name;

   function Image (N : Column_Name) return String is
   begin
      return To_String (N.Value);
   end Image;

   overriding function "=" (L, R : Column_Name) return Boolean is
   begin
      return L.Value = R.Value;
   end "=";

   --  Hash the upper-cased payload as a plain String, so this is identical to
   --  the pre-J1 Ada.Strings.Hash on the upper-cased map key -- no change to
   --  bucket distribution or equality.
   function Hash (N : Column_Name) return Ada.Containers.Hash_Type is
   begin
      return Ada.Strings.Hash (To_String (N.Value));
   end Hash;

end SData_Core.Column_Names;
