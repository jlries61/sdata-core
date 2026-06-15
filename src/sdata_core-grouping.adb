--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

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

end SData_Core.Grouping;
