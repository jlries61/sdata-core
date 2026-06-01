--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with SData_Core.Table;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with SData_Core.Values; use SData_Core.Values;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body SData_Core.Evaluator.Nav_Fns is

   --  BOG/EOG state is owned here: only Handle_BOG/Handle_EOG read it,
   --  and only Set_Boundary (called from Set_Group_Boundary) writes it.
   BOG_Flag : Boolean := False;
   EOG_Flag : Boolean := False;

   procedure Set_Boundary (BOG, EOG : Boolean) is
   begin
      BOG_Flag := BOG;
      EOG_Flag := EOG;
   end Set_Boundary;

   function Handle_Recno (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind    => Val_Integer,
              Int_Val => (if SData_Core.Table.Is_Filtered
                          then Integer (SData_Core.Table.Get_Logical_Record_Index)
                          else Integer (SData_Core.Table.Get_Current_Record_Index)));
   end Handle_Recno;

   function Handle_Ord (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if Has_Args (Vals, 1) then
         declare V : constant Value := Vals.Element (1);
         begin
            if V.Kind /= Val_String or else Length (V.Str_Val) = 0 then
               return (Kind => Val_Missing);
            end if;
            return (Kind    => Val_Integer,
                    Int_Val => Character'Pos (Element (V.Str_Val, 1)));
         end;
      end if;
      return (Kind    => Val_Integer,
              Int_Val => (if SData_Core.Table.Is_Filtered
                          then Integer (SData_Core.Table.Get_Logical_Record_Index)
                          else Integer (SData_Core.Table.Get_Current_Record_Index)));
   end Handle_Ord;

   function Handle_BOF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind    => Val_Integer,
              Int_Val => (if SData_Core.Table.Is_Filtered
                          then (if SData_Core.Table.Get_Logical_Record_Index <= 1 then 1 else 0)
                          else (if SData_Core.Table.Get_Current_Record_Index <= 1 then 1 else 0)));
   end Handle_BOF;

   function Handle_EOF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind    => Val_Integer,
              Int_Val => (if SData_Core.Table.Is_Filtered
                          then (if SData_Core.Table.Get_Logical_Record_Index >= SData_Core.Table.Logical_Row_Count then 1 else 0)
                          else (if SData_Core.Table.Get_Current_Record_Index >= SData_Core.Table.Row_Count then 1 else 0)));
   end Handle_EOF;

   function Handle_BOG (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => (if BOG_Flag then 1 else 0));
   end Handle_BOG;

   function Handle_EOG (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return (Kind => Val_Integer, Int_Val => (if EOG_Flag then 1 else 0));
   end Handle_EOG;

   function Handle_Lag (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare
         Var     : constant Value := Vals.Element (1);
         N_Val   : constant Value :=
            (if Has_Args (Vals, 2) then Vals.Element (2)
             else (Kind => Val_Integer, Int_Val => 1));
         N       : Integer;
         Log_Idx : constant Natural :=
            (if SData_Core.Table.Is_Filtered then SData_Core.Table.Get_Logical_Record_Index
             else SData_Core.Table.Get_Current_Record_Index);
      begin
         if Var.Kind /= Val_String then return (Kind => Val_Missing); end if;
         N := Integer (Convert_To_Float (N_Val));
         if N <= 0 or else Log_Idx <= N then return (Kind => Val_Missing); end if;
         declare
            Phys_Curr : constant Positive := SData_Core.Table.Logical_To_Physical (Log_Idx);
            Phys_Prev : constant Positive := SData_Core.Table.Logical_To_Physical (Log_Idx - N);
         begin
            if not SData_Core.Table.In_Same_Group (Phys_Curr, Phys_Prev) then
               return (Kind => Val_Missing);
            end if;
            return SData_Core.Table.Get_Value_Upper (Phys_Prev, To_Upper (SData_Core.Values.To_String (Var)));
         end;
      end;
   end Handle_Lag;

   function Handle_Next_Val (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare
         Var       : constant Value := Vals.Element (1);
         N_Val     : constant Value :=
            (if Has_Args (Vals, 2) then Vals.Element (2)
             else (Kind => Val_Integer, Int_Val => 1));
         N         : Integer;
         Log_Idx   : constant Natural :=
            (if SData_Core.Table.Is_Filtered then SData_Core.Table.Get_Logical_Record_Index
             else SData_Core.Table.Get_Current_Record_Index);
         Log_Count : constant Natural :=
            (if SData_Core.Table.Is_Filtered then SData_Core.Table.Logical_Row_Count
             else SData_Core.Table.Row_Count);
      begin
         if Var.Kind /= Val_String then return (Kind => Val_Missing); end if;
         N := Integer (Convert_To_Float (N_Val));
         if N <= 0 or else (Log_Idx + N) > Log_Count then return (Kind => Val_Missing); end if;
         declare
            Phys_Curr : constant Positive := SData_Core.Table.Logical_To_Physical (Log_Idx);
            Phys_Next : constant Positive := SData_Core.Table.Logical_To_Physical (Log_Idx + N);
         begin
            if not SData_Core.Table.In_Same_Group (Phys_Curr, Phys_Next) then
               return (Kind => Val_Missing);
            end if;
            return SData_Core.Table.Get_Value_Upper (Phys_Next, To_Upper (SData_Core.Values.To_String (Var)));
         end;
      end;
   end Handle_Next_Val;

   function Handle_Obs (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      declare
         Var     : constant Value := Vals.Element (1);
         Row_Val : constant Value := Vals.Element (2);
         Row     : Integer;
      begin
         if Var.Kind /= Val_String then return (Kind => Val_Missing); end if;
         Row := Integer (Convert_To_Float (Row_Val));
         if Row < 1 or else Row > SData_Core.Table.Row_Count then
            return (Kind => Val_Missing);
         end if;
         return SData_Core.Table.Get_Value_Upper (Row, To_Upper (SData_Core.Values.To_String (Var)));
      end;
   end Handle_Obs;

   ---------------------------------------------------------------------------

   procedure Register is
   begin
      Dispatch_Table.Insert ("RECNO",  Handle_Recno'Access);
      Dispatch_Table.Insert ("BOF",    Handle_BOF'Access);
      Dispatch_Table.Insert ("EOF",    Handle_EOF'Access);
      Dispatch_Table.Insert ("BOG",    Handle_BOG'Access);
      Dispatch_Table.Insert ("EOG",    Handle_EOG'Access);
      Dispatch_Table.Insert ("ORD",    Handle_Ord'Access);
      Dispatch_Table.Insert ("LAG",    Handle_Lag'Access);
      Dispatch_Table.Insert ("LAGC$",  Handle_Lag'Access);
      Dispatch_Table.Insert ("NEXT",   Handle_Next_Val'Access);
      Dispatch_Table.Insert ("NEXTC$", Handle_Next_Val'Access);
      Dispatch_Table.Insert ("OBS",    Handle_Obs'Access);
      Dispatch_Table.Insert ("OBSC$",  Handle_Obs'Access);
   end Register;

begin
   Register;
end SData_Core.Evaluator.Nav_Fns;