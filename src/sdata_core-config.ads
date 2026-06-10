--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
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
   Progress           : Boolean := False; -- If True, emit record-count progress to stderr for long USE/RUN/SORT runs.
   Debug_Level        : Natural := 0;     -- 0=off 1=I/O 2=+record/flow 3=+assignments
   Shell_Timeout_Default : Natural := 0;

   --  Application-specific version and copyright constants live in each
   --  consuming application (e.g., SData.Version in the sdata crate) so
   --  that sdata-core can evolve its own version independently.

end SData_Core.Config;