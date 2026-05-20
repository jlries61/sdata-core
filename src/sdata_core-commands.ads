--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Commands provides execution procedures for the shared
--  command set used by both sdata and data-vandal.  Each procedure reads and
--  writes interpreter state held in SData_Core.Config and
--  SData_Core.Config.Runtime, and operates on the global data table.
--
--  These procedures encapsulate the *semantics* of each command.  The host
--  application is still responsible for parsing the surface syntax and
--  resolving the parameter values to pass in here.  Procedures take only
--  primitive types and types defined in sdata-core, so callers do not need
--  to depend on any host-specific AST.

with SData_Core.Config;
with SData_Core.Evaluator;
with SData_Core.Table;

package SData_Core.Commands is

   ----------------------------------------------------------------
   --  USE — open and read an input dataset into the data table.
   --
   --  File_Name      Path or "MOCK" for the synthetic test dataset.
   --  Fmt            Target file format.
   --  Sheet_Name     Spreadsheet sheet name; empty selects the first sheet.
   --  Delimiter      CSV field delimiter (already decoded; e.g. "," or HT).
   --  Read_Header    Treat first row as column header.
   --  Charset        Character set name; empty means autodetect.
   --  Skip_Rows      Initial rows to skip before reading data.
   --  Max_Rows       Maximum rows to read (0 = unlimited).
   --  Nscan_Rows     Sample rows for type inference (0 = default).
   --  Is_Mock        True when the input is the synthetic MOCK dataset.
   --
   --  Side effects: clears REPEAT state, refreshes the PDV column map.
   procedure Execute_USE
     (File_Name   : String;
      Fmt         : SData_Core.Config.Format_Type;
      Sheet_Name  : String  := "";
      Delimiter   : String  := ",";
      Read_Header : Boolean := True;
      Charset     : String  := "";
      Skip_Rows   : Natural := 0;
      Max_Rows    : Natural := 0;
      Nscan_Rows  : Natural := 0;
      Is_Mock     : Boolean := False);

   ----------------------------------------------------------------
   --  SAVE — register a pending output dataset.
   --
   --  When File_Name is empty, any pending SAVE is cancelled.  Otherwise the
   --  parameters are stored in SData_Core.Config.Runtime so that the actual
   --  write occurs at the end of the next RUN.
   procedure Execute_SAVE
     (File_Name   : String;
      Fmt         : SData_Core.Config.Format_Type;
      Sheet_Name  : String  := "";
      Delimiter   : String  := ",";
      Write_Header : Boolean := True;
      Charset     : String  := "");

   ----------------------------------------------------------------
   --  FPATH — set search directories per category.
   --
   --  When all four flags are False the procedure resets every FPath_*
   --  category to Path (matching the original behaviour of the bare
   --  "FPATH dir" command).  Otherwise only categories whose flag is True
   --  are updated.
   procedure Execute_FPATH
     (Path        : String;
      Use_Flag    : Boolean := False;
      Save_Flag   : Boolean := False;
      Submit_Flag : Boolean := False;
      Output_Flag : Boolean := False);

   ----------------------------------------------------------------
   --  OUTPUT — redirect console output and update text format options.
   --
   --  An empty File_Name closes any active redirection without opening a
   --  new one.  TXTFMT and CHARSET parameters update OPTIONS state when
   --  non-empty.
   procedure Execute_OUTPUT
     (File_Name : String;
      TXTFMT    : String := "";
      Charset   : String := "");

   ----------------------------------------------------------------
   --  SELECT — install (or, with null, clear) the persistent filter
   --  expression that is rebuilt into the logical→physical index map at
   --  the start of every RUN.  Ownership of the passed expression
   --  transfers to the runtime; any previously held expression is freed.
   procedure Execute_SELECT
     (Expr : SData_Core.Evaluator.Expression_Access);

   ----------------------------------------------------------------
   --  KEEP / DROP — restrict the current table's column set.
   --
   --  KEEP drops every column not in the list; DROP removes the listed
   --  columns.  Names are matched case-insensitively after upper-casing.
   --  Missing column names are silently ignored.
   procedure Execute_KEEP
     (Names : SData_Core.Table.Name_Vectors.Vector);

   procedure Execute_DROP
     (Names : SData_Core.Table.Name_Vectors.Vector);

   ----------------------------------------------------------------
   --  ARRAY — define a virtual array as a list of existing variables.
   --  Passing an empty Constituents vector undefines the named array.
   --  Passing an empty Name lists every defined virtual array on stdout.
   procedure Execute_ARRAY
     (Name         : String;
      Constituents : SData_Core.Table.Name_Vectors.Vector);

   ----------------------------------------------------------------
   --  DIM — define or resize a real array.  Bounds are integer indices
   --  with End_Idx >= Start_Idx; otherwise the underlying call raises an
   --  exception.  Is_Temp = True declares a /TEMP DIM array.
   procedure Execute_DIM
     (Base_Name : String;
      Start_Idx : Integer;
      End_Idx   : Integer;
      Is_Temp   : Boolean := False);

   ----------------------------------------------------------------
   --  RUN — perform the end-of-step actions shared by every front end:
   --  rebuild the SELECT filter map against the current table and, if a
   --  SAVE is pending, write the table out.  Hosts call this from their
   --  data-step loop after iterating records, in addition to whatever
   --  per-record processing they perform.
   procedure Execute_RUN;

end SData_Core.Commands;
