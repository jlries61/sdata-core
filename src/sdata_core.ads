--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1

--  Root package for the sdata-core shared library.
package SData_Core is

   --  Capacity limits -- single authoritative source for all name/path/string
   --  constraints across the interpreter.  Every String(1..N) declaration in
   --  the codebase that encodes a user-visible limit should reference one of
   --  these constants rather than a bare literal.

   Max_Name_Len        : constant := 64;   -- max variable, column, array, or function name
   Max_Path_Len        : constant := 1024; -- max file or directory path
   Max_Sheet_Name_Len  : constant := 64;   -- max spreadsheet sheet name
   Max_Delimiter_Len   : constant := 8;    -- max delimiter or short format string
   Max_Charset_Len     : constant := 64;   -- max charset name (e.g. "UTF-8", "ISO-8859-1")
   Max_Options_Val_Len : constant := 256;  -- max OPTIONS command value string

   Script_Error : exception;

end SData_Core;
