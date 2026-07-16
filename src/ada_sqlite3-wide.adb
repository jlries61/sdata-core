--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada_Sqlite3.Low_Level;
with Interfaces.C;
with System;

package body Ada_Sqlite3.Wide is

   package LL renames Ada_Sqlite3.Low_Level;
   use type Interfaces.C.int;
   use type System.Address;

   -------------------
   -- Bind_Double64 --
   -------------------
   procedure Bind_Double64
     (Stmt  : in out Statement;
      Index : Positive;
      Value : Long_Float)
   is
      Result : Result_Code;
   begin
      if Stmt.Handle = System.Null_Address then
         raise SQLite_Error with "Statement is not prepared";
      end if;
      Result := LL.Sqlite3_Bind_Double
        (Stmt  => Sqlite3_Stmt (Stmt.Handle),
         Index => Interfaces.C.int (Index),
         Value => Interfaces.C.double (Value));
      if Result /= LL.SQLITE_OK then
         raise SQLite_Error with "sqlite3_bind_double failed";
      end if;
   end Bind_Double64;

   ---------------------
   -- Column_Double64 --
   ---------------------
   function Column_Double64
     (Stmt  : Statement;
      Index : Natural) return Long_Float is
   begin
      return Long_Float
        (LL.Sqlite3_Column_Double
           (Stmt  => Sqlite3_Stmt (Stmt.Handle),
            Index => Interfaces.C.int (Index)));
   end Column_Double64;

   ----------------
   -- Bind_Int64 --
   ----------------
   procedure Bind_Int64
     (Stmt  : in out Statement;
      Index : Positive;
      Value : Long_Long_Integer)
   is
      Result : Result_Code;
   begin
      if Stmt.Handle = System.Null_Address then
         raise SQLite_Error with "Statement is not prepared";
      end if;
      Result := LL.Sqlite3_Bind_Int64
        (Stmt  => Sqlite3_Stmt (Stmt.Handle),
         Index => Interfaces.C.int (Index),
         Value => Interfaces.C.long (Value));
      if Result /= LL.SQLITE_OK then
         raise SQLite_Error with "sqlite3_bind_int64 failed";
      end if;
   end Bind_Int64;

   ------------------
   -- Column_Int64 --
   ------------------
   function Column_Int64
     (Stmt  : Statement;
      Index : Natural) return Long_Long_Integer is
   begin
      return Long_Long_Integer
        (LL.Sqlite3_Column_Int64
           (Stmt  => Sqlite3_Stmt (Stmt.Handle),
            Index => Interfaces.C.int (Index)));
   end Column_Int64;

end Ada_Sqlite3.Wide;
