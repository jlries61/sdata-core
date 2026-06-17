--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Containers.Vectors;
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

end SData_Core.File_IO.Helpers;