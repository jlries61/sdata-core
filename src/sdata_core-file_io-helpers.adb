--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Text_IO;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Fixed;       use Ada.Strings.Fixed;
with GNAT.OS_Lib;
with GNAT.Strings;            use GNAT.Strings;
with DOM.Core.Nodes;
with Input_Sources.Strings;
with Unicode.CES.Utf8;

package body SData_Core.File_IO.Helpers is

   overriding function Resolve_Entity
      (Handler   : Secure_Reader;
       Public_Id : Unicode.CES.Byte_Sequence;
       System_Id : Unicode.CES.Byte_Sequence)
       return Input_Sources.Input_Source_Access
   is
      pragma Unreferenced (Handler, Public_Id, System_Id);
      --  Resolve every external entity to an empty byte sequence: the parser
      --  uses this in place of opening the referenced file or URI, so no
      --  external resource is ever read.  The parser takes ownership of the
      --  returned access value and frees it.
      Empty : constant Input_Sources.Strings.String_Input_Access :=
         new Input_Sources.Strings.String_Input;
   begin
      Input_Sources.Strings.Open
         ("", Unicode.CES.Utf8.Utf8_Encoding, Empty.all);
      return Input_Sources.Input_Source_Access (Empty);
   end Resolve_Entity;

   function File_Base (File_Name : String) return String is
   begin
      for I in reverse File_Name'Range loop
         if File_Name (I) = '/' or else File_Name (I) = '\' then
            return File_Name (I + 1 .. File_Name'Last);
         end if;
      end loop;
      return File_Name;
   end File_Base;

   function File_Stem (Base : String) return String is
   begin
      for I in reverse Base'Range loop
         if Base (I) = '.' then
            return Base (Base'First .. I - 1);
         end if;
      end loop;
      return Base;
   end File_Stem;

   function Get_Text (N : DOM.Core.Node) return String is
      use DOM.Core;
      use DOM.Core.Nodes;
      Child : Node := First_Child (N);
      Res   : Unbounded_String := Null_Unbounded_String;
   begin
      while Child /= null loop
         if Node_Type (Child) = Text_Node then
            Append (Res, Node_Value (Child));
         elsif Node_Type (Child) = Element_Node then
            Append (Res, Get_Text (Child));
         end if;
         Child := Next_Sibling (Child);
      end loop;
      return To_String (Res);
   end Get_Text;

   function Detect_Inf (S : String) return Value is
      SU : constant String := To_Upper (S);
   begin
      if SU = "INF" or else SU = "+INF"
         or else SU = "INFINITY" or else SU = "+INFINITY"
      then
         return (Kind => Val_Numeric, Num_Val => Pos_Inf);
      elsif SU = "-INF" or else SU = "-INFINITY" then
         return (Kind => Val_Numeric, Num_Val => Neg_Inf);
      end if;
      return (Kind => Val_Missing);
   end Detect_Inf;

   procedure Apply_Name_Suffix_Types
      (Col_Name_Vec : Name_Vecs.Vector;
       Col_Types    : in out Column_Type_Array) is
   begin
      for I in 1 .. Natural (Col_Name_Vec.Length) loop
         declare
            Raw : constant String := To_String (Col_Name_Vec (I));
         begin
            if Raw'Length > 0 and then Raw (Raw'Last) = '$' then
               Col_Types (I) := Col_String;
            elsif Raw'Length > 0 and then Raw (Raw'Last) = '%' then
               Col_Types (I) := Col_Integer;
            end if;
         end;
      end loop;
   end Apply_Name_Suffix_Types;

   function Safe_Name (S : String; Default : String) return String is
      T : constant String := Trim (S, Ada.Strings.Both);
   begin
      if T = "" then return Default; end if;
      if T'Length > Max_Name_Len then
         return T (T'First .. T'First + Max_Name_Len - 1);
      end if;
      return T;
   end Safe_Name;

   function Col_To_Letters (Col : Positive) return String is
      C   : Natural := Col;
      Res : String (1 .. 10);
      Idx : Natural := 10;
   begin
      while C > 0 loop
         declare
            Remm : constant Natural := (C - 1) mod 26;
         begin
            Res (Idx) := Character'Val (Character'Pos ('A') + Remm);
            C   := (C - 1) / 26;
            Idx := Idx - 1;
         end;
      end loop;
      return Res (Idx + 1 .. 10);
   end Col_To_Letters;

   function Escape_XML (S : String) return String is
      Res : Unbounded_String := Null_Unbounded_String;
   begin
      for I in S'Range loop
         case S (I) is
            when '&'  => Append (Res, "&amp;");
            when '<'  => Append (Res, "&lt;");
            when '>'  => Append (Res, "&gt;");
            when '"'  => Append (Res, "&quot;");
            when '''  => Append (Res, "&apos;");
            when others => Append (Res, S (I));
         end case;
      end loop;
      return To_String (Res);
   end Escape_XML;

   function Has_Formulas_XML (Temp_File : String; Is_ODF : Boolean) return Boolean is
      File   : Ada.Text_IO.File_Type;
      Line   : String (1 .. 8192);
      Last   : Natural;
      Marker : constant String := (if Is_ODF then "table:formula=" else "<f");
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Temp_File);
      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line, Last);
         if Index (Line (1 .. Last), Marker) > 0 then
            Ada.Text_IO.Close (File);
            return True;
         end if;
      end loop;
      Ada.Text_IO.Close (File);
      return False;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then Ada.Text_IO.Close (File); end if;
         return False;
   end Has_Formulas_XML;

   --  2026-08-13 re-audit PD-4: locates a `timeout`(1) utility to bound
   --  Convert_Via_LibreOffice's soffice call, mirroring the PATH-preference
   --  logic in sdata's SYSTEM/SHELL timeout (ADR-037): prefer GNU
   --  coreutils' `gtimeout` (the name it installs under on macOS/BSD, where
   --  the bare `timeout` may be a different, noisier utility), falling
   --  back to `timeout`. Returns null if neither is on PATH, so the caller
   --  can fall back to an unbounded call rather than fail outright --
   --  unlike SHELL's OPTIONS SHELLTIMEOUT (an explicit user request that
   --  must fail loudly if it can't be honored), this is opportunistic
   --  defense-in-depth with no user-visible toggle, so degrading gracefully
   --  is the right default. Not shared with sdata_core-system.adb's own
   --  private Resolve_Timeout_Cmd (not part of that package's public
   --  contract) -- the two call sites have different failure semantics
   --  (loud-fail-if-requested vs. quiet-degrade), so duplicating this
   --  ~10-line lookup is clearer than forcing a shared abstraction across
   --  them.
   function Locate_Timeout_Exec return GNAT.OS_Lib.String_Access is
      G : constant GNAT.OS_Lib.String_Access :=
         GNAT.OS_Lib.Locate_Exec_On_Path ("gtimeout");
   begin
      if G /= null then
         return G;
      end if;
      return GNAT.OS_Lib.Locate_Exec_On_Path ("timeout");
   end Locate_Timeout_Exec;

   function Convert_Via_LibreOffice
     (File_Name : String; Fmt : Format_Type) return String
   is
      Soffice_Acc : GNAT.OS_Lib.String_Access :=
         GNAT.OS_Lib.Locate_Exec_On_Path ("soffice");
      Target_Ext : constant String := (if Fmt = ODF then "xlsx" else "ods");
      Dir        : constant String := "/tmp/";
      Base_Stem  : constant String := File_Stem (File_Base (File_Name));
      Converted  : constant String := Dir & Base_Stem & "." & Target_Ext;

      --  Fixed, non-configurable wall-clock bound (not an OPTIONS key --
      --  see the architect note in
      --  .ssd/features/audit-2026-08-13-tier1-remediation/01-architect.md
      --  for why this stays internal rather than user-surfaced). Generous
      --  enough that ordinary conversions never approach it; only exists to
      --  turn a hang into a bounded failure.
      Timeout_Secs : constant String := "90";

      Status : Integer;
   begin
      if Soffice_Acc = null then
         return "";
      end if;

      --  Resolved only once soffice is confirmed present -- code review
      --  round 1 (MAJOR-1) caught that resolving this unconditionally in
      --  the declarative part, alongside Soffice_Acc, leaked the resolved
      --  String_Access on the early return above whenever a timeout
      --  utility was on PATH but soffice was not.
      declare
         Timeout_Acc : GNAT.OS_Lib.String_Access := Locate_Timeout_Exec;
      begin
         --  The bug this fixes: File_Name was never appended to Args, so
         --  soffice was invoked with no input file and (depending on
         --  version/platform) waited indefinitely -- an unbounded hang on
         --  ordinary, spec-compliant input, not a fast failure.
         if Timeout_Acc /= null then
            --  Argv-based invocation throughout: `timeout`/`gtimeout` execs
            --  soffice directly (no shell), so File_Name -- which may
            --  contain spaces or shell metacharacters -- never needs
            --  quoting and cannot reach a shell interpreter.
            declare
               A1 : GNAT.OS_Lib.String_Access := new String'(Timeout_Secs);
               A2 : GNAT.OS_Lib.String_Access := new String'("soffice");
               A3 : GNAT.OS_Lib.String_Access := new String'("--headless");
               A4 : GNAT.OS_Lib.String_Access := new String'("--convert-to");
               A5 : GNAT.OS_Lib.String_Access := new String'(Target_Ext);
               A6 : GNAT.OS_Lib.String_Access := new String'("--outdir");
               A7 : GNAT.OS_Lib.String_Access := new String'(Dir);
               A8 : GNAT.OS_Lib.String_Access := new String'(File_Name);
               Args : constant GNAT.OS_Lib.Argument_List :=
                  (1 => A1, 2 => A2, 3 => A3, 4 => A4,
                   5 => A5, 6 => A6, 7 => A7, 8 => A8);
            begin
               Status := GNAT.OS_Lib.Spawn (Timeout_Acc.all, Args);
               GNAT.OS_Lib.Free (A1); GNAT.OS_Lib.Free (A2);
               GNAT.OS_Lib.Free (A3); GNAT.OS_Lib.Free (A4);
               GNAT.OS_Lib.Free (A5); GNAT.OS_Lib.Free (A6);
               GNAT.OS_Lib.Free (A7); GNAT.OS_Lib.Free (A8);
            end;
         else
            --  No timeout utility on PATH: fall back to the unbounded call
            --  (still correctly includes File_Name -- the required part of
            --  this fix does not depend on timeout being available).
            declare
               A1 : GNAT.OS_Lib.String_Access := new String'("--headless");
               A2 : GNAT.OS_Lib.String_Access := new String'("--convert-to");
               A3 : GNAT.OS_Lib.String_Access := new String'(Target_Ext);
               A4 : GNAT.OS_Lib.String_Access := new String'("--outdir");
               A5 : GNAT.OS_Lib.String_Access := new String'(Dir);
               A6 : GNAT.OS_Lib.String_Access := new String'(File_Name);
               Args : constant GNAT.OS_Lib.Argument_List :=
                  (1 => A1, 2 => A2, 3 => A3, 4 => A4, 5 => A5, 6 => A6);
            begin
               Status := GNAT.OS_Lib.Spawn (Soffice_Acc.all, Args);
               GNAT.OS_Lib.Free (A1); GNAT.OS_Lib.Free (A2);
               GNAT.OS_Lib.Free (A3); GNAT.OS_Lib.Free (A4);
               GNAT.OS_Lib.Free (A5); GNAT.OS_Lib.Free (A6);
            end;
         end if;

         --  Code review round 1 (SUGGESTION-1): no null guard needed --
         --  GNAT.OS_Lib.Free (an Ada.Unchecked_Deallocation instance) is a
         --  documented no-op on a null access value, same as the
         --  unconditional Free (Soffice_Acc) below.
         GNAT.OS_Lib.Free (Timeout_Acc);
      end;

      GNAT.OS_Lib.Free (Soffice_Acc);

      --  A fired timeout is treated the same as any other conversion
      --  failure: Is_Regular_File (Converted) will be False, so this falls
      --  through to the existing "" return, which both call sites already
      --  handle as "conversion unavailable" and fall back to the file's
      --  cached (pre-formula) values -- graceful degradation, not a new
      --  exception path.
      if Status = 0 and then GNAT.OS_Lib.Is_Regular_File (Converted) then
         return Converted;
      end if;
      return "";
   end Convert_Via_LibreOffice;

end SData_Core.File_IO.Helpers;