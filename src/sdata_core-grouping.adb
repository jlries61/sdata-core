--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Columns; use SData_Core.Columns;

package body SData_Core.Grouping is

   Table_By_Vars : Columns.Column_Name_Vectors.Vector;

   --  Read one cell, live-segment-or-spilled, mirroring the old
   --  Table.Get_Value_Upper exactly.
   function Cell
     (Row           : Positive;
      Key           : Columns.Column_Name;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Value
   is
      Cur : constant Columns.Column_Maps.Cursor := T.Find (Key);
   begin
      if not Columns.Column_Maps.Has_Element (Cur) then
         return (Kind => Val_Missing);
      end if;
      declare
         Ref : constant Columns.Column_Maps.Constant_Reference_Type :=
            T.Constant_Reference (Cur);
         Len : constant Natural := Natural (Ref.Element.all.Data.Length);
      begin
         if Row >= Segment_Start and then Row < Segment_Start + Len then
            return Ref.Element.all.Data.Element (Row - Segment_Start + 1);
         elsif Store.Is_Active then
            return Store.Fetch (Row, Columns.Image (Key), T, Row_Count);
         else
            return (Kind => Val_Missing);
         end if;
      end;
   end Cell;

   procedure Clear_By_Vars is
   begin
      Table_By_Vars.Clear;
   end Clear_By_Vars;

   procedure Add_By_Var (Name : String) is
   begin
      Table_By_Vars.Append (Columns.To_Column_Name (Name));
   end Add_By_Var;

   function By_Var_Count return Natural is
   begin
      return Natural (Table_By_Vars.Length);
   end By_Var_Count;

   function By_Var_Name (I : Positive) return String is
   begin
      return Columns.Image (Table_By_Vars.Element (I));
   end By_Var_Name;

   function In_Same_Group
     (Idx1, Idx2    : Positive;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Boolean is
   begin
      if Table_By_Vars.Is_Empty then return True; end if;
      if Idx1 = Idx2 then return True; end if;
      if Idx1 > Row_Count or else Idx2 > Row_Count then return False; end if;
      for V of Table_By_Vars loop
         declare
            Val1 : constant Value := Cell (Idx1, V, T, Store, Segment_Start, Row_Count);
            Val2 : constant Value := Cell (Idx2, V, T, Store, Segment_Start, Row_Count);
         begin
            if not (Val1 = Val2) then return False; end if;
         end;
      end loop;
      return True;
   end In_Same_Group;

   -----------------------
   -- Partition_By_Key --
   -----------------------
   function Partition_By_Key
     (Physical_Rows : Row_Index_Vectors.Vector;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Row_Group_Vectors.Vector
   is
      --  Composite BY-key encoded as a single self-delimiting string:
      --  each field is "<length>:<formatted value>", concatenated with no
      --  separator between fields.  This is injective (two different
      --  BY-value tuples can never encode to the same string) without
      --  needing a custom composite key type + Hash function -- unlike a
      --  naive fixed-separator join, a length prefix can't be confused
      --  with in-band data, since the reader (here, nothing ever decodes
      --  it -- it is only ever used as an opaque hash-map key) always
      --  knows exactly how many characters belong to the current field
      --  before looking for the next length prefix.
      function Key_Of (Row : Positive) return String is
         Result : Unbounded_String;
      begin
         for I in 1 .. Natural (Table_By_Vars.Length) loop
            declare
               Val : constant Value :=
                  Cell (Row, Table_By_Vars.Element (I), T, Store,
                        Segment_Start, Row_Count);
               Formatted : constant String := To_String (Val);
               Len_Img   : constant String :=
                  Ada.Strings.Fixed.Trim
                    (Integer'Image (Formatted'Length), Ada.Strings.Both);
            begin
               Append (Result, Len_Img);
               Append (Result, ":");
               Append (Result, Formatted);
            end;
         end loop;
         return To_String (Result);
      end Key_Of;

      package Key_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type        => String,
         Element_Type    => Row_Index_Vectors.Vector,
         Hash            => Ada.Strings.Hash,
         Equivalent_Keys => "=",
         "="             => Row_Index_Vectors."=");

      Buckets : aliased Key_Maps.Map;
      Result  : Row_Group_Vectors.Vector;
   begin
      --  Empty BY: the whole supplied row list is one group, in the given
      --  order -- matches In_Same_Group's own "empty BY => always True"
      --  convention and the pre-existing Group_Boundaries "no active BY"
      --  contract.  No grouping/sorting work needed.
      if Table_By_Vars.Is_Empty then
         if not Physical_Rows.Is_Empty then
            Result.Append (Physical_Rows);
         end if;
         return Result;
      end if;

      --  Pass 1: bucket physical rows by composite BY-key.  Bucket order
      --  (map iteration order) is irrelevant -- pass 2 sorts explicitly.
      --
      --  Code review round 1 (MAJOR-1): appending via a copy-out
      --  (Key_Maps.Element, a by-value return for this controlled
      --  Vector element type) then Replace (a copy back in) made each
      --  append O(current bucket size) -- O(k^2) total to build one
      --  k-member bucket, not the O(n) this primitive was designed and
      --  reviewed for. Buckets.Reference mutates the vector stored in
      --  the map in place instead -- O(1) amortized per append, same as
      --  the adjacency scan this replaces.
      for Row of Physical_Rows loop
         declare
            Key : constant String := Key_Of (Row);
            Cur : constant Key_Maps.Cursor := Buckets.Find (Key);
         begin
            if Key_Maps.Has_Element (Cur) then
               Buckets.Reference (Cur).Append (Row);
            else
               declare
                  New_Bucket : Row_Index_Vectors.Vector;
               begin
                  New_Bucket.Append (Row);
                  Buckets.Insert (Key, New_Bucket);
               end;
            end if;
         end;
      end loop;

      --  Pass 2: collect buckets, then sort the resulting GROUP LIST (one
      --  entry per distinct key, never the rows within a group, never any
      --  table) by BY-key value ascending -- reproducing the row order
      --  BY's old forced Table.Sort produced as a side effect, using each
      --  group's first row's actual BY-var values (not the encoded string
      --  key, which would sort lexicographically rather than by each
      --  BY-var's real type -- e.g. numeric "2" must sort before "10").
      for Pos in Buckets.Iterate loop
         Result.Append (Key_Maps.Element (Pos));
      end loop;

      declare
         function Group_Less (Left, Right : Row_Index_Vectors.Vector)
            return Boolean
         is
            L_Row : constant Positive := Left.First_Element;
            R_Row : constant Positive := Right.First_Element;
         begin
            for I in 1 .. Natural (Table_By_Vars.Length) loop
               declare
                  V : constant Columns.Column_Name := Table_By_Vars.Element (I);
                  L_Val : constant Value :=
                     Cell (L_Row, V, T, Store, Segment_Start, Row_Count);
                  R_Val : constant Value :=
                     Cell (R_Row, V, T, Store, Segment_Start, Row_Count);
               begin
                  if L_Val < R_Val then
                     return True;
                  elsif R_Val < L_Val then
                     return False;
                  end if;
                  --  Equal on this BY-var: fall through to the next one.
               end;
            end loop;
            --  Code review round 1 (SUGGESTION-1): unreachable by
            --  construction -- distinct hash-map buckets have distinct
            --  composite keys, so two groups' representative rows can
            --  never compare equal on every BY-var. Asserted rather than
            --  silently returning False, so a future Key_Of regression
            --  that broke that invariant (e.g. reintroducing the exact
            --  collision this encoding exists to prevent) fails loudly
            --  instead of silently degrading to an unspecified sort
            --  order -- same loud-invariant convention as
            --  Get_Value_By_Col's Column_Cursor_Cache check.
            pragma Assert
              (False, "unreachable: two distinct BY-key groups compared " &
                      "fully equal -- Key_Of collision or Buckets " &
                      "invariant broken");
            return False;
         end Group_Less;

         package Group_Sorting is new Row_Group_Vectors.Generic_Sorting
           ("<" => Group_Less);
      begin
         Group_Sorting.Sort (Result);
      end;

      return Result;
   end Partition_By_Key;

end SData_Core.Grouping;
