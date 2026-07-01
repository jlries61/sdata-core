--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
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

with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
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
   --  Resolve_Use_Defaults — the single authority for the
   --  "specified on the USE statement, else fall back to OPTIONS state"
   --  merge that consumers previously open-coded.  Front ends parse the
   --  surface syntax, then call this to obtain the effective delimiter /
   --  header / charset to hand to Execute_USE, so the merge rule lives in
   --  one place rather than drifting between consumers (per ADR; closes
   --  the Evans "two authorities for USE defaults" finding).
   --
   --  Each *_Specified flag MUST be supplied by the caller and MUST NOT be
   --  inferred from emptiness: an empty Charset is a legal explicit value
   --  ("autodetect") distinct from "charset unspecified".  When a flag is
   --  False the corresponding SData_Core.Config.Runtime.Options_* accessor
   --  supplies the value.  The Delimiter passed in must already be decoded
   --  to its literal form (e.g. TAB -> HT); the OPTIONS fallback is used
   --  verbatim.  Raises SData_Core.Script_Error if an effective delimiter
   --  or charset exceeds its bound (Max_Delimiter_Len / Max_Charset_Len) —
   --  friendlier than the bare Constraint_Error a slice assignment raises.
   type Use_Defaults is record
      Delimiter     : String (1 .. Max_Delimiter_Len) := (others => ' ');
      Delimiter_Len : Natural := 0;
      Read_Header   : Boolean := True;
      Charset       : String (1 .. Max_Charset_Len)   := (others => ' ');
      Charset_Len   : Natural := 0;
   end record;

   function Resolve_Use_Defaults
     (Delimiter           : String  := "";
      Delimiter_Specified : Boolean := False;
      Read_Header         : Boolean := True;
      Header_Specified    : Boolean := False;
      Charset             : String  := "";
      Charset_Specified   : Boolean := False) return Use_Defaults;

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
   --  non-empty, with the same length validation as the OPTIONS command
   --  (raising SData_Core.Script_Error on overflow).
   procedure Execute_OUTPUT
     (File_Name : String;
      TXTFMT    : String := "";
      Charset   : String := "");

   ----------------------------------------------------------------
   --  OUTPUT (table form) — register a default table-output path.
   --
   --  Unlike Execute_OUTPUT (which redirects console text), this form
   --  records the path so that Execute_RUN will write the current table
   --  there if no explicit SAVE is pending.  Used by front ends such as
   --  data-vandal where OUTPUT means "save the dataset here" rather than
   --  "redirect PRINT to here".  An empty File_Name clears any pending
   --  table output.  The format is inferred from the file extension by
   --  the underlying writer, with CSV as the default.
   procedure Execute_OUTPUT_Table
     (File_Name : String;
      Fmt       : SData_Core.Config.Format_Type := SData_Core.Config.CSV);

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
   --  AGGREGATE — collapse the current table into one row per active BY
   --  group, computing registered aggregate functions over chosen input
   --  columns.  Grouping is taken from the active BY statement (no /BY=);
   --  the active SELECT filter is respected during the input scan.  On
   --  success the fresh one-row-per-group table replaces the in-memory
   --  table, a pending SAVE is flushed, and the active SELECT and BY are
   --  cleared.  All errors abort before any side effect (see ADR-046).
   --
   --  An Aggregate_Spec describes one "<outvar> = <fn>(<invar>)" clause:
   --    Outvar      target column name (may end in '$' for character output).
   --    Fn_Name     registered aggregate function name (case-insensitive).
   --    Invar_Kind  shape of the input reference (see below).
   --    Invar_Name  input column / array base name (empty for Invar_Empty).
   --    Invar_Index array element subscript (only for Invar_Array_Element).
   type Aggregate_Invar_Kind is
     (Invar_Empty,          --  N() with no argument -> group row count
      Invar_Scalar,         --  a scalar column name
      Invar_Array_Element,  --  an array element, e.g. x(1)
      Invar_Array_Name);    --  a whole registered array, element-wise

   type Aggregate_Spec is record
      Outvar      : Ada.Strings.Unbounded.Unbounded_String;
      Fn_Name     : Ada.Strings.Unbounded.Unbounded_String;
      Invar_Kind  : Aggregate_Invar_Kind := Invar_Empty;
      Invar_Name  : Ada.Strings.Unbounded.Unbounded_String;
      Invar_Index : Natural := 0;
   end record;

   package Aggregate_Spec_Vectors is
     new Ada.Containers.Vectors (Positive, Aggregate_Spec);

   --  Raises SData_Core.Script_Error (per the AGGREGATE error catalog,
   --  ADR-046 / design spec sec 5) on any validation failure; on such a
   --  failure the in-memory table, the pending SAVE, and the active
   --  SELECT/BY are all left untouched.
   procedure Execute_AGGREGATE (Specs : Aggregate_Spec_Vectors.Vector);

   ----------------------------------------------------------------
   --  TRANSPOSE — reshape the current table so that each transposed input
   --  column becomes one output row.  Either each input row of a block
   --  becomes one element of an output array (/ARRAY, default _X_), or
   --  named subsets of rows become named output columns (/ID).  With an
   --  active BY, each consecutive-key block is transposed separately into
   --  the same fresh output table.  The active SELECT filter is respected
   --  during the scan; on success the fresh table replaces the in-memory
   --  table, a pending SAVE is flushed, and the active SELECT and BY are
   --  cleared.  All validation precedes any side effect (see ADR-047).
   --
   --  A Transpose_Options record carries the parsed options:
   --    Keep_List   columns/arrays to transpose (empty = every non-BY column).
   --    Drop_List   columns/arrays to exclude from the transposed set.
   --    Name_Col    name of the character column holding each source column's
   --                name (empty -> default _NAME_$).
   --    Id_Col      /ID column whose values become output column names.
   --    Array_Name  /ARRAY base name (empty -> _X_ when neither /ID nor
   --                /ARRAY is given).
   --    Has_Id      True when /ID was specified.
   --    Has_Array   True when /ARRAY was specified.
   --  /ID and /ARRAY are mutually exclusive (enforced by the front-end
   --  parser, error #1).
   type Transpose_Options is record
      Keep_List  : SData_Core.Table.Name_Vectors.Vector;
      Drop_List  : SData_Core.Table.Name_Vectors.Vector;
      Name_Col   : Ada.Strings.Unbounded.Unbounded_String;
      Id_Col     : Ada.Strings.Unbounded.Unbounded_String;
      Array_Name : Ada.Strings.Unbounded.Unbounded_String;
      Has_Id     : Boolean := False;
      Has_Array  : Boolean := False;
   end record;

   --  Raises SData_Core.Script_Error (per the TRANSPOSE error catalog,
   --  ADR-047 / design spec sec 4) on any validation failure; on such a
   --  failure the in-memory table, the pending SAVE, and the active
   --  SELECT/BY are all left untouched.  A failure during the post-commit
   --  SAVE flush (error #13) is rethrown as Script_Error but, as with
   --  AGGREGATE, the in-memory replacement has already happened.
   procedure Execute_TRANSPOSE (Options : Transpose_Options);

   ----------------------------------------------------------------
   --  STATS — compute summary statistics for the chosen (or, by default,
   --  all numeric) variables, one row per (active BY group x variable),
   --  with one column per requested statistic.  Reuses the registered
   --  aggregate functions.  Mirrors AGGREGATE's build-and-swap: on success
   --  the fresh stats table replaces the in-memory table, a pending SAVE is
   --  flushed, and the active SELECT and BY are cleared.  All validation
   --  precedes any side effect.  Printing is the caller's concern.
   --
   --    Var_List   analysis variables; empty => all numeric columns (minus BY).
   --               A whole-array base name expands to its elements.
   --    Stat_List  registered aggregate names; empty => N MIN MEAN MAX STD.
   type Stats_Options is record
      Var_List  : SData_Core.Table.Name_Vectors.Vector;
      Stat_List : SData_Core.Table.Name_Vectors.Vector;
   end record;

   procedure Execute_STATS (Options : Stats_Options);

   ----------------------------------------------------------------
   --  Execute_Commit_Step — perform the end-of-step actions shared by
   --  every front end: rebuild the SELECT filter map against the current
   --  table and, if a SAVE or table-output is pending, write the table
   --  out.  Call this wherever a step's results must be committed and the
   --  filter map refreshed — at the end of a data step, or after a SORT
   --  reorders the table.  This is the intention-revealing name for that
   --  work; Execute_RUN below is a thin alias for front ends whose RUN
   --  statement maps directly onto it.
   procedure Execute_Commit_Step;

   ----------------------------------------------------------------
   --  RUN — the user-issued RUN statement.  Currently identical to the
   --  end-of-step commit: it delegates to Execute_Commit_Step.  The two
   --  are kept distinct so a host's "the user typed RUN" dispatch and its
   --  internal "commit this step" calls read differently at the call site.
   procedure Execute_RUN;

   ----------------------------------------------------------------
   --  Execute_Rebuild_Filter — rebuild the SELECT logical→physical index
   --  map against the current table without flushing a pending SAVE.
   --  Front ends call this at the *start* of a data step (before iterating
   --  records) so the filter map is current for the initial record set.
   --  Execute_RUN rebuilds the map at the *end* of a step (after the output
   --  table has been committed).  Both paths share the same implementation.
   procedure Execute_Rebuild_Filter;

   ----------------------------------------------------------------
   --  Interpreter-state mutators (added per audit Findings R1/U2/E2).
   --
   --  These wrap the corresponding SData_Core.Config.Runtime field
   --  writes that consumers previously performed inline.  Each is a
   --  thin pass-through, except that the String-valued OPTIONS setters
   --  validate length up-front and raise SData_Core.Script_Error on
   --  overflow — friendlier than the bare Constraint_Error a direct
   --  slice assignment would raise.
   ----------------------------------------------------------------

   ----------------------------------------------------------------
   --  REPEAT — set or clear the deferred-program repeat state.
   --
   --  Count > 0  sets Repeat_Active := True and Repeat_Count := Count.
   --  Count = 0  clears Repeat_Active and Repeat_Count.
   procedure Execute_REPEAT (Count : Natural);

   ----------------------------------------------------------------
   --  NEW — reset all runtime interpreter state to defaults.
   --
   --  Delegates to SData_Core.Config.Runtime.Reset.  Host applications
   --  call this from their Stmt_NEW handler.  Note: this does NOT clear
   --  the data table, variables, or the active program — those are the
   --  consumer's responsibility (each is a distinct concern in core).
   procedure Execute_NEW;

   ----------------------------------------------------------------
   --  OPTIONS — update one OPTIONS-command runtime setting.
   --
   --  Each procedure mirrors a single Options_* field in
   --  SData_Core.Config.Runtime.  String-valued setters validate
   --  Value'Length up-front:
   --    Execute_OPTIONS_CSVDLM rejects empty values (a zero-length
   --      delimiter is nonsense) and values longer than Max_Delimiter_Len.
   --    Execute_OPTIONS_TXTFMT rejects empty values and values longer
   --      than Max_Delimiter_Len (note: the recognised TXTFMT set lives
   --      in the host application's grammar, not in core).
   --    Execute_OPTIONS_CHARSET allows empty (meaning "autodetect") and
   --      rejects values longer than Max_Charset_Len.
   --  Boolean / Natural setters need no validation beyond the parameter
   --  type.

   procedure Execute_OPTIONS_CSVDLM        (Value : String);
   procedure Execute_OPTIONS_Header        (Value : Boolean);
   procedure Execute_OPTIONS_SAVEOVERWRT   (Value : Boolean);
   procedure Execute_OPTIONS_TXTFMT        (Value : String);
   procedure Execute_OPTIONS_CHARSET       (Value : String);
   procedure Execute_OPTIONS_IEEE_Divide   (Value : Boolean);
   procedure Execute_OPTIONS_Shell_Timeout (Value : Natural);

   ----------------------------------------------------------------
   --  OPTIONS JOIN_WARN_THRESHOLD — set the per-BY-group product
   --  threshold above which /JOIN merges emit a warning.  Value 0
   --  disables the warning entirely.
   procedure Execute_OPTIONS_Join_Warn_Threshold (Value : Natural);

   ----------------------------------------------------------------
   --  Reserved-keyword warning support (per quoted-identifiers design,
   --  2026-05-30; promoted to sdata-core 2026-06-17 as the one shareable
   --  sliver). Each consumer passes its own grammar-specific keyword set.
   package Reserved_Keyword_Sets is
     new Ada.Containers.Indefinite_Ordered_Sets (String);

   --  Walk the current table's columns; for each upper-cased column name
   --  that is a member of Keywords, emit one stderr warning. No-op when
   --  Config.Runtime.Options_Warn_Reserved is False (gating lives here, the
   --  single authority — callers do not check the toggle).
   procedure Warn_Reserved_Columns (Keywords : Reserved_Keyword_Sets.Set);

   --  OPTIONS WARNRESERVED — enable (True, the default) or suppress (False)
   --  the reserved-keyword column warning emitted by Warn_Reserved_Columns
   --  at USE time.  Sets Config.Runtime.Options_Warn_Reserved.
   procedure Execute_OPTIONS_WarnReserved (Value : Boolean);

   ----------------------------------------------------------------
   --  Record_Error — set the Last_Error_Code / Last_Error_Line pair
   --  observed via the ERROR_CODE and ERROR_LINE expression functions.
   --
   --  Host applications call this from their per-record exception
   --  handlers in lieu of writing the Runtime fields directly.
   procedure Execute_Record_Error (Code : Natural; Line : Natural);

end SData_Core.Commands;
