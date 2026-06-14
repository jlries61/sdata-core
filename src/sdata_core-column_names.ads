--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Column_Names defines Column_Name: the single, private,
--  always-upper-cased internal representation of a column name (closes audit
--  J1-internal).  It lives in its own package -- separate from SData_Core.Columns
--  which instantiates the column map/vectors over it -- because a generic
--  instantiation over a private type must occur where the type is already
--  complete; instantiating in Column_Name's own visible part would freeze the
--  partial view (Ada premature-use error).  Keeping it private makes the
--  upper-cased invariant compiler-enforced: To_Column_Name is the only
--  constructor, so no caller can build a non-canonical name.

with Ada.Containers;
with Ada.Strings.Unbounded;

package SData_Core.Column_Names is

   type Column_Name is private;

   --  THE upper-casing chokepoint -- the only way to construct a Column_Name.
   function To_Column_Name (S : String) return Column_Name;

   --  Back to String for the public API boundary and diagnostics.
   function Image (N : Column_Name) return String;

   overriding function "=" (L, R : Column_Name) return Boolean;
   function Hash (N : Column_Name) return Ada.Containers.Hash_Type;

private

   type Column_Name is record
      Value : Ada.Strings.Unbounded.Unbounded_String;  -- always upper-cased
   end record;

end SData_Core.Column_Names;
