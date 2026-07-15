--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  64-bit (C double) bind/column for SQLite statements.
--
--  ada_sqlite3 0.1.1's high-level Bind_Double / Column_Double take and return
--  Ada 'Float' (32-bit), narrowing values even though SQLite stores REAL as an
--  IEEE 754 double and the C API (sqlite3_bind_double / sqlite3_column_double)
--  is 64-bit.  With sdata's numeric type now double precision (Real, #54), that
--  narrowing would make spilled data lower-precision than the in-memory table.
--
--  This is a child of Ada_Sqlite3 so it can see the (private) raw statement
--  handle and call the low-level 64-bit C entry points directly, preserving
--  full double precision across the disk spill.  Kept as a thin child unit
--  rather than a fork of the pinned dependency.

with Ada_Sqlite3.Low_Level;
pragma Unreferenced (Ada_Sqlite3.Low_Level);

package Ada_Sqlite3.Double64 is

   --  Bind Value (64-bit) to the 1-based parameter Index of a prepared Stmt.
   procedure Bind_Double64
     (Stmt  : in out Statement;
      Index : Positive;
      Value : Long_Float);

   --  Read the 0-based result column Index of the current row as 64-bit.
   function Column_Double64
     (Stmt  : Statement;
      Index : Natural) return Long_Float;

end Ada_Sqlite3.Double64;
