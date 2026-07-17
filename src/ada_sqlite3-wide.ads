--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  64-bit (native-width) bind/column for SQLite statements.
--
--  ada_sqlite3 0.1.1's high-level Bind_Double / Column_Double take/return Ada
--  'Float' (32-bit) and Bind_Int / Column_Int take/return 'Integer' (32-bit),
--  narrowing values even though SQLite stores REAL as an IEEE 754 double and
--  INTEGER as a 64-bit signed integer, and the C API is 64-bit throughout.
--  With sdata's numeric types now double (Real) and 64-bit (Int) per #54, that
--  narrowing would make spilled data lower-precision / lower-range than the
--  in-memory table.
--
--  This is a child of Ada_Sqlite3 so it can see the (private) raw statement
--  handle and call the low-level 64-bit C entry points directly, preserving
--  full precision and range across the disk spill.  A thin child unit rather
--  than a fork of the pinned dependency.

with Ada_Sqlite3.Low_Level;
pragma Unreferenced (Ada_Sqlite3.Low_Level);

package Ada_Sqlite3.Wide is

   --  Bind Value (IEEE double) to the 1-based parameter Index of a prepared Stmt.
   procedure Bind_Double64
     (Stmt  : in out Statement;
      Index : Positive;
      Value : Long_Float);

   --  Read the 0-based result column Index of the current row as IEEE double.
   function Column_Double64
     (Stmt  : Statement;
      Index : Natural) return Long_Float;

   --  Bind Value (64-bit signed) to the 1-based parameter Index of a Stmt.
   procedure Bind_Int64
     (Stmt  : in out Statement;
      Index : Positive;
      Value : Long_Long_Integer);

   --  Read the 0-based result column Index of the current row as 64-bit signed.
   function Column_Int64
     (Stmt  : Statement;
      Index : Natural) return Long_Long_Integer;

end Ada_Sqlite3.Wide;
