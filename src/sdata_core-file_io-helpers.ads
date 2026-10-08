--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with DOM.Core;
with DOM.Readers;
with Input_Sources;
with Unicode.CES;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Table;  use SData_Core.Table;

private package SData_Core.File_IO.Helpers is

   package Name_Vecs is new Ada.Containers.Vectors (Positive, Unbounded_String);
   type Column_Type_Array is array (Positive range <>) of Column_Type;

   --  ADR-0028: O(1)-amortized duplicate-name membership test for
   --  Warn_If_Duplicate_Name, replacing an O(n) linear scan. Names are
   --  stored upper-cased at insertion (once), not re-uppercased on every
   --  comparison.
   package Name_Sets is new Ada.Containers.Indefinite_Hashed_Sets
      (Element_Type        => String,
       Hash                => Ada.Strings.Hash,
       Equivalent_Elements => "=");

   --  XML reader hardened against XXE (external-entity injection).  XML/Ada
   --  opens external entities -- e.g. <!ENTITY x SYSTEM "file:///etc/passwd">
   --  or a relative SYSTEM id -- whenever it expands an entity reference, and
   --  its External_*_Entities feature flags are NOT consulted on that content
   --  inclusion path (see sax-readers.adb, the V.External branch of entity
   --  expansion).  Overriding the entity resolver is therefore the only
   --  effective defence.  Secure_Reader refuses every external entity by
   --  resolving it to empty content, so a crafted ODS/XLSX cannot read local
   --  files or fetch remote URIs and surface them as cell text.  Predefined
   --  and internal entities do not pass through Resolve_Entity, so normal XML
   --  escaping is unaffected.  Use this type for every Parse of untrusted
   --  spreadsheet XML.
   type Secure_Reader is new DOM.Readers.Tree_Reader with null record;
   overriding function Resolve_Entity
      (Handler   : Secure_Reader;
       Public_Id : Unicode.CES.Byte_Sequence;
       System_Id : Unicode.CES.Byte_Sequence)
       return Input_Sources.Input_Source_Access;

   --  ADR-084 (sdata) / ADR-0027: USE /TYPES=, the per-column type override.
   --  One parser and one applier, shared by all three readers, so CSV, ODF and
   --  OOXML cannot drift apart -- the same discipline ADR-0026 adopted for
   --  MISSING= after the two-independent-checks defect it was built to close.
   type Declared_Type is (Dec_Float, Dec_Integer, Dec_Character);
   type Declared_Entry is record
      Name : Unbounded_String;   --  base name: suffix stripped, upper-cased
      Kind : Declared_Type;
   end record;
   package Declared_Vecs is new Ada.Containers.Vectors (Positive, Declared_Entry);
   type Lock_Array is array (Positive range <>) of Boolean;

   --  Parse the canonical "NAME,NAME$,NAME%" specification the sdata parser
   --  produces from either surface syntax.  An empty Spec yields an empty
   --  vector.  Raises Script_Error on an empty entry ("A,,B") or a repeated
   --  base name ("A$,A%") -- one rule, at most one declaration per column.
   procedure Parse_Declared_Types
      (Spec     : String;
       Declared : out Declared_Vecs.Vector);

   --  Apply declarations to a reader's column state.  Sets Col_Types for each
   --  matched column and marks it in Col_Locked so the reader's own inference
   --  skips it.  Raises Script_Error naming any declared column the file does
   --  not have (KEEP/DROP's precedent: validate before doing anything).  Emits
   --  the ADR-084 conflict note when the header's own suffix implies a type
   --  different from the declared one.  Matching strips $/% from BOTH sides,
   --  which is what lets /TYPES="CODE" demote a header that says CODE$.
   procedure Apply_Declared_Types
      (Declared     : Declared_Vecs.Vector;
       Col_Name_Vec : Name_Vecs.Vector;
       Col_Types    : in out Column_Type_Array;
       Col_Locked   : out Lock_Array;
       File_Name    : String);

   --  The single naming rule: a column's final name carries the suffix its
   --  TYPE implies -- "$" for character, "%" for integer, none for float.
   --  Behavior-identical to what each reader open-coded before (a $-header is
   --  Col_String and keeps its $; a %-header is Col_Integer and keeps its %),
   --  but it also handles the case only /TYPES= can create: a DEMOTED column,
   --  where the header says CODE$ and the declaration says float, whose name
   --  must lose the suffix rather than stay CODE$ on a numeric column.
   function Final_Column_Name (Base_Name : String; Col_Typ : Column_Type)
      return String;

   --  Strip one trailing $ or % if present.  Exposed because the readers need
   --  the same base-name rule the matcher uses.
   function Strip_Type_Suffix (S : String) return String;

   function Get_Text (N : DOM.Core.Node) return String;
   function Detect_Inf (S : String) return Value;
   procedure Apply_Name_Suffix_Types
      (Col_Name_Vec : Name_Vecs.Vector;
       Col_Types    : in out Column_Type_Array);
   function Safe_Name (S : String; Default : String) return String;
   function Col_To_Letters (Col : Positive) return String;
   function Escape_XML (S : String) return String;
   function Has_Formulas_XML (Temp_File : String; Is_ODF : Boolean) return Boolean;
   function Convert_Via_LibreOffice (File_Name : String; Fmt : Format_Type) return String;

   --  ADR-0026 (amended): USE /MISSING=, the declared-missing-value token
   --  list.  Lifted out of Parse_CSV (where it was private) so ODF/OOXML can
   --  share the identical parse-and-match behavior rather than each growing
   --  their own copy -- the same discipline /TYPES= already established
   --  above for Declared_Vecs/Parse_Declared_Types/Apply_Declared_Types.
   package Missing_Token_Vecs is new Ada.Containers.Vectors
      (Positive, Unbounded_String);

   --  Split Spec on "," -- deliberately hardcoded, independent of any
   --  reader's own field delimiter: the MISSING= list's own separator is a
   --  fixed part of its syntax, not inherited from the input file's format.
   --  Reuses Split_Indices/CSV_Unquote -- the same quote-aware splitter a
   --  CSV row's own fields already go through -- so a token containing a
   --  literal comma can be expressed by quoting it (MISSING="NA,""a,b""").
   --  Each token is then trimmed of surrounding whitespace, the same
   --  treatment a header column name already gets.  Spec = "" (the default)
   --  yields an empty Tokens vector.
   procedure Parse_Missing_Tokens
      (Spec   : String;
       Tokens : out Missing_Token_Vecs.Vector);

   --  Exact, untrimmed, case-sensitive match against F -- a field/cell's own
   --  text is compared as-is; only the token list itself was trimmed above.
   function Is_Declared_Missing
      (Tokens : Missing_Token_Vecs.Vector;
       F      : String) return Boolean;

   --  ADR-0018: warns once per duplicate column name (design.md sec4.2's
   --  documented "last occurrence wins, warning issued" -- the warning half
   --  was never implemented for any of CSV/ODF/OOXML). Final_Name must be
   --  the exact string the caller is about to pass to Add_Column (or, for
   --  CSV, append to its own name list) -- the fully $-suffix-decorated
   --  name, not the raw header text, so this check can never diverge from
   --  what Table.Add_Column will actually treat as a collision (its own key,
   --  Column_Names.To_Column_Name, only uppercases -- no other
   --  normalization). Seen accumulates across the caller's whole naming
   --  loop; call once per column, in header order.
   procedure Warn_If_Duplicate_Name
      (File_Name  : String;
       Final_Name : String;
       Seen       : in out Name_Sets.Set);

end SData_Core.File_IO.Helpers;