--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Config holds startup configuration set by the CLI and
--  constant across the lifetime of the process.  Per-run interpreter state
--  that changes during execution (SAVE path, REPEAT mode, FPATH directories)
--  lives in the child package SData_Core.Config.Runtime.

package SData_Core.Config is

   --  Supported file formats for data I/O.
   type Format_Type is (CSV, ODF, OOXML);

   --  The expected format of the input dataset (set via --infmt).
   Input_Format  : Format_Type := CSV;

   --  The desired format for the output dataset (set via --outfmt).
   Output_Format : Format_Type := CSV;

   --  Optional input file from command line (-u).
   Input_File_Path : String (1 .. Max_Path_Len) := (others => ' ');
   Input_File_Len  : Natural := 0;

   --  If True, suppresses informational messages (e.g., "Dataset opened").
   Quiet_Mode    : Boolean := False;

   --  Optional output dataset from command line (-s).
   Output_Dataset_Path : String (1 .. Max_Path_Len) := (others => ' ');
   Output_Dataset_Len  : Natural := 0;

   --  Optional file to redirect console output (set via -o).
   Output_File     : String (1 .. Max_Path_Len) := (others => ' ');
   Output_File_Len : Natural := 0;

   --  DIGITS state (controlling float precision in output).
   Print_Digits  : Natural := 5;

   --  Constraint limits
   Max_Table_Cells : Natural := 50_000_000;  -- ~1.5 GB at 32 bytes/cell; 0 = unlimited
   Max_String_Len  : Natural := 0;      -- 0 means no limit
   Max_Temp_Vars   : Natural := 0;      -- 0 means no limit
   Disable_Shell      : Boolean := False;
   Disable_Submit     : Boolean := False;
   Continue_On_Error  : Boolean := False;
   Ignore_Math_Errors : Boolean := False; -- If True, domain errors return Val_Missing instead of halting.
   Debug_Level        : Natural := 0;     -- 0=off 1=I/O 2=+record/flow 3=+assignments
   Shell_Timeout_Default : Natural := 0;

   --  Version information
   Version_Major : constant Natural := 0;
   Version_Minor : constant Natural := 7;
   Version_Patch : constant Natural := 1;
   Version_Str   : constant String :=
      Natural'Image (Version_Major)(2 .. Natural'Image (Version_Major)'Last) & "." &
      Natural'Image (Version_Minor)(2 .. Natural'Image (Version_Minor)'Last) & "." &
      Natural'Image (Version_Patch)(2 .. Natural'Image (Version_Patch)'Last);

   --  Copyright and license information
   Copyright_Str : constant String :=
      "Copyright (C) 2026 John L. Ries <john@theyarnbard.com>";

   Copyright_Notice : constant String :=
      "SData version " & Version_Str & ASCII.LF &
      Copyright_Str & ASCII.LF & ASCII.LF &
      "This program is free software: you can redistribute it and/or modify" & ASCII.LF &
      "it under the terms of the GNU General Public License as published by" & ASCII.LF &
      "the Free Software Foundation, either version 3 of the License, or" & ASCII.LF &
      "(at your option) any later version." & ASCII.LF & ASCII.LF &
      "This program is distributed in the hope that it will be useful," & ASCII.LF &
      "but WITHOUT ANY WARRANTY; without even the implied warranty of" & ASCII.LF &
      "MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the" & ASCII.LF &
      "GNU General Public License for more details." & ASCII.LF & ASCII.LF &
      "You should have received a copy of the GNU General Public License" & ASCII.LF &
      "along with this program. If not, see <https://www.gnu.org/licenses/>.";

end SData_Core.Config;