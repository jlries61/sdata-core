--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling; use Ada.Characters.Handling;
with GNAT.Strings; use GNAT.Strings;
with Ada.Containers; use Ada.Containers; -- For Count_Type
with Ada.Strings.Fixed;
with SData_Core.Config;
with SData_Core.IO;

package body SData_Core.Variables is

   ---------------------------
   -- Array_Definition_Type --
   ---------------------------
   function "=" (Left, Right : Array_Definition_Type) return Boolean is
   begin
      if Left.Kind /= Right.Kind then return False; end if;
      if Left.Is_Temporary /= Right.Is_Temporary then return False; end if;
      if Left.Start_Index /= Right.Start_Index then return False; end if;
      if Left.End_Index /= Right.End_Index then return False; end if;
      -- Only compare constituents if it's a virtual array
      if Left.Kind = Virtual_Array then
         return SData_Core.Table.Name_Vectors."=" (Left.Constituents, Right.Constituents);
      else -- Real_Array
         -- Real arrays are defined by their bounds and temporary status, not explicit constituents list
         return True; 
      end if;
   end "=";

   -------------------------
   -- Get_Real_Var_Name --
   -------------------------
   function Get_Real_Var_Name (Array_Name : String; Index : Integer) return String is
   begin
      --  Converts "MYARRAY" and 5 to "MYARRAY(5)"
      return Array_Name & "(" & Ada.Strings.Fixed.Trim(Integer'Image(Index), Ada.Strings.Both) & ")";
   end Get_Real_Var_Name;

   -------------------
   -- Set_Temporary --
   -------------------
   procedure Set_Temporary (Name : String; Val : Value) is
      Upper_Name : constant String := To_Upper (Name);
   begin
      --  Rule: SET implicitly drops permanent variable from table (Exclusivity)
      if SData_Core.Table.Has_Column (Upper_Name) then
         SData_Core.IO.Put_Line_Error ("Warning: Column '" & Upper_Name & "' dropped from table and converted to session variable.");
         SData_Core.Table.Drop_Column (Upper_Name);
      end if;

      if Temp_Symbols.Contains (Upper_Name) then
         Temp_Symbols.Replace (Upper_Name, Val);
      else
         -- Check limit if set
         if SData_Core.Config.Max_Temp_Vars > 0 and then Natural (Temp_Symbols.Length) >= SData_Core.Config.Max_Temp_Vars then
            raise Program_Error with "Temporary variable limit (" & Integer'Image(SData_Core.Config.Max_Temp_Vars) & ") exceeded.";
         end if;
         Temp_Symbols.Insert (Upper_Name, Val);
      end if;
   end Set_Temporary;

   -------------------
   -- Set_Permanent --
   -------------------
   procedure Set_Permanent (Name : String; Val : Value) is
      Upper_Name : constant String := To_Upper (Name);
      Cur        : constant PDV_Index_Pkg.Cursor := PDV_Index.Find (Upper_Name);
   begin
      --  Rule: LET implicitly unsets session variable (Promotion/Exclusivity)
      if Temp_Symbols.Contains (Upper_Name) and then not Is_Held (Upper_Name) then
         Temp_Symbols.Delete (Upper_Name);
      end if;

      if PDV_Index_Pkg.Has_Element (Cur) then
         PDV_Vec.Replace_Element (PDV_Index_Pkg.Element (Cur), Val);
      else
         --  New computed variable — allocate a new PDV slot.
         PDV_Names.Append (To_Unbounded_String (Upper_Name));
         PDV_Vec.Append (Val);
         PDV_Index.Insert (Upper_Name, Positive (PDV_Names.Length));
      end if;

      if Is_Held (Upper_Name) then
         if Temp_Symbols.Contains (Upper_Name) then
            Temp_Symbols.Replace (Upper_Name, Val);
         else
            Temp_Symbols.Insert (Upper_Name, Val);
         end if;
      end if;
   end Set_Permanent;

   -----------
   -- Unset --
   -----------
   procedure Unset (Name : String) is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if Temp_Symbols.Contains (Upper_Name) then
         Temp_Symbols.Delete (Upper_Name);
      end if;
   end Unset;

   ---------
   -- Get --
   ---------
   function Get (Name : String) return Value is
      Upper_Name : constant String := To_Upper (Name);
      Cur        : constant PDV_Index_Pkg.Cursor := PDV_Index.Find (Upper_Name);
   begin
      --  1. Check PDV vector first (one hash lookup, then direct access).
      if PDV_Index_Pkg.Has_Element (Cur) then
         declare
            V : constant Value := PDV_Vec.Element (PDV_Index_Pkg.Element (Cur));
         begin
            if V.Kind /= Val_Missing then
               return V;
            end if;
         end;
      end if;

      --  2. Check Temporary symbols (held values, session vars, BOG/EOG flags).
      if Temp_Symbols.Contains (Upper_Name) then
         return Temp_Symbols.Element (Upper_Name);
      else
         return (Kind => Val_Missing);
      end if;
   end Get;

   -------------
   -- Defined --
   -------------
   function Defined (Name : String) return Boolean is
      Upper_Name : constant String := To_Upper (Name);
   begin
      return PDV_Index.Contains (Upper_Name) or else Temp_Symbols.Contains (Upper_Name);
   end Defined;

   ---------------------
   -- Clear_Temporary --
   ---------------------
   procedure Clear_Temporary is
   begin
      Temp_Symbols.Clear;
      -- Permanent_Symbols are NOT cleared here. They are managed by the Data Step loop.
      -- (i.e., Reset_PDV_Non_Held and Load_PDV_From_Table)
      declare
         Cursor : Array_Table_Pkg.Cursor := Array_Symbols.First;
      begin
         while Array_Table_Pkg.Has_Element (Cursor) loop
            declare
               Arr_Def : constant Array_Definition_Type := Array_Table_Pkg.Element (Cursor);
            begin
               --  Permanent arrays (Real, non-temporary) survive RUN boundaries by
               --  design — they model variables the user expects to persist across
               --  datasets.  Only temporary Real arrays and Virtual arrays are scoped
               --  to the current data step and must be freed here.
               if Arr_Def.Kind = Virtual_Array or else
                  (Arr_Def.Kind = Real_Array and then Arr_Def.Is_Temporary)
               then
                  if Arr_Def.Kind = Real_Array then
                     for I in Arr_Def.Start_Index .. Arr_Def.End_Index loop
                        declare
                           Var_Name : constant String := Get_Real_Var_Name (To_String (Arr_Def.Constituents.First_Element), I);
                        begin
                           if Temp_Symbols.Contains (Var_Name) then
                              Symbol_Table_Pkg.Delete (Temp_Symbols, Var_Name);
                           end if;
                        end;
                     end loop;
                  end if;
                  Array_Table_Pkg.Delete (Array_Symbols, Cursor);
                  -- Note: Restart scan as map might have reordered due to deletion.
                  Cursor := Array_Symbols.First;
               else
                  Array_Table_Pkg.Next (Cursor);
               end if;
            end;
         end loop;
      end;
   end Clear_Temporary;

   --------------------
   -- Initialize_PDV --
   --------------------
   procedure Initialize_PDV is
      C : constant Natural := SData_Core.Table.Column_Count;
   begin
      PDV_Vec.Clear;
      PDV_Index.Clear;
      PDV_Names.Clear;
      PDV_Vec.Reserve_Capacity (Ada.Containers.Count_Type (C + 16));
      for I in 1 .. C loop
         declare
            Name : constant String := SData_Core.Table.Column_Name (I);
         begin
            PDV_Names.Append (To_Unbounded_String (Name));
            PDV_Index.Insert (Name, I);
            PDV_Vec.Append ((Kind => Val_Missing));
         end;
      end loop;
   end Initialize_PDV;

   -------------------------
   -- Load_PDV_From_Table --
   -------------------------
   --  Loads table columns into pre-allocated PDV_Vec slots via the cursor cache;
   --  slot I corresponds to column I.  O(1) per column — no hash lookup.
   procedure Load_PDV_From_Table (Row : Positive) is
      C : constant Natural := SData_Core.Table.Column_Count;
   begin
      for I in 1 .. C loop
         PDV_Vec.Replace_Element (I, SData_Core.Table.Get_Value_By_Col (Row, I));
      end loop;
   end Load_PDV_From_Table;

   -------------------------
   -- Load_PDV_One_Column --
   -------------------------
   procedure Load_PDV_One_Column (Row : Positive; Col_Name : String) is
      Val : constant Value := SData_Core.Table.Get_Value_Upper (Row, Col_Name);
      Cur : constant PDV_Index_Pkg.Cursor := PDV_Index.Find (Col_Name);
   begin
      if PDV_Index_Pkg.Has_Element (Cur) then
         PDV_Vec.Replace_Element (PDV_Index_Pkg.Element (Cur), Val);
      else
         PDV_Names.Append (To_Unbounded_String (Col_Name));
         PDV_Vec.Append (Val);
         PDV_Index.Insert (Col_Name, Positive (PDV_Names.Length));
      end if;
   end Load_PDV_One_Column;

   -----------------------
   -- Refresh_PDV_Names --
   -----------------------
   procedure Refresh_PDV_Names is
   begin
      for I in 1 .. SData_Core.Table.Column_Count loop
         declare
            Name : constant String := SData_Core.Table.Column_Name (I);
         begin
            if not PDV_Index.Contains (Name) then
               PDV_Names.Append (To_Unbounded_String (Name));
               PDV_Vec.Append ((Kind => Val_Missing));
               PDV_Index.Insert (Name, Positive (PDV_Names.Length));
            end if;
         end;
      end loop;
   end Refresh_PDV_Names;

   ------------------------
   -- Reset_PDV_Non_Held --
   ------------------------
   procedure Reset_PDV_Non_Held is
   begin
      for I in 1 .. Natural (PDV_Names.Length) loop
         declare
            Name : constant String := To_String (PDV_Names.Element (I));
         begin
            if not Is_Held (Name) then
               PDV_Vec.Replace_Element (I, (Kind => Val_Missing));
            else
               declare
                  V : constant Value := PDV_Vec.Element (I);
               begin
                  if not Temp_Symbols.Contains (Name) then
                     Temp_Symbols.Insert (Name, V);
                  else
                     Temp_Symbols.Replace (Name, V);
                  end if;
               end;
            end if;
         end;
      end loop;
   end Reset_PDV_Non_Held;

   -----------------------
   -- Flush_PDV_To_Output --
   -----------------------
   procedure Flush_PDV_To_Output is
   begin
      for I in 1 .. Natural (PDV_Names.Length) loop
         declare
            Name : constant String := To_String (PDV_Names.Element (I));
            V    : constant Value  := PDV_Vec.Element (I);
            Typ  : Column_Type := Col_Numeric;
         begin
            if V.Kind = Val_Integer then
               Typ := Col_Integer;
            elsif V.Kind = Val_String then
               Typ := Col_String;
            elsif V.Kind = Val_Missing
              and then SData_Core.Table.Has_Column (Name)
            then
               --  A leading missing value carries no type information.  Use
               --  the source column's declared type so a column that is
               --  missing in its first row(s) but populated (e.g. with a
               --  character value) later is not locked to Numeric on the
               --  first flush.  Add_Output_Column ignores the type on every
               --  call after the first, so the first row decides it.
               Typ := SData_Core.Table.Get_Column_Type (Name);
            end if;
            SData_Core.Table.Add_Output_Column (Name, Typ);
         end;
      end loop;

      SData_Core.Table.Add_Output_Row;
      declare
         R : constant Positive := SData_Core.Table.Output_Row_Count;
      begin
         for I in 1 .. Natural (PDV_Names.Length) loop
            SData_Core.Table.Set_Output_Value_By_Col (R, I, PDV_Vec.Element (I));
         end loop;
      end;
   end Flush_PDV_To_Output;

   function Get_Type (Name : String) return Value_Kind is
      Upper : constant String := To_Upper (Name);
      Cur   : constant PDV_Index_Pkg.Cursor := PDV_Index.Find (Upper);
   begin
      if PDV_Index_Pkg.Has_Element (Cur) then
         return PDV_Vec.Element (PDV_Index_Pkg.Element (Cur)).Kind;
      end if;
      return Val_Missing;
   end Get_Type;

   -----------------
   -- PDV_Resolve --
   -----------------
   function PDV_Resolve (Name : String) return Natural is
      Cur : constant PDV_Index_Pkg.Cursor := PDV_Index.Find (Name);
   begin
      if PDV_Index_Pkg.Has_Element (Cur) then
         return PDV_Index_Pkg.Element (Cur);
      end if;
      return 0;
   end PDV_Resolve;

   -------------------
   -- Get_PDV_Value --
   -------------------
   function Get_PDV_Value (Idx : Positive) return Value is
   begin
      return PDV_Vec.Element (Idx);
   end Get_PDV_Value;

   function Get_Session_Names return String_List_Access is
      Result : constant String_List_Access := new String_List (1 .. Integer (Temp_Symbols.Length));
      Idx    : Integer := 1;
   begin
      for Pos in Temp_Symbols.Iterate loop
         Result (Idx) := new String'(Symbol_Table_Pkg.Key (Pos));
         Idx := Idx + 1;
      end loop;
      return Result;
   end Get_Session_Names;

   -------------------
   -- Get_PDV_Names --
   -------------------
   function Get_PDV_Names return String_List_Access is
      Count : constant Natural := Natural (PDV_Names.Length);
      List  : constant String_List_Access := new String_List (1 .. Count);
   begin
      for I in 1 .. Count loop
         List (I) := new String'(To_String (PDV_Names.Element (I)));
      end loop;
      return List;
   end Get_PDV_Names;

   ------------------
   -- Define_Array --
   ------------------
   procedure Define_Array (Name : String; Constituents : GNAT.Strings.String_List) is
      Upper_Name : constant String := To_Upper (Name);
      Arr_Def : Array_Definition_Type;
   begin
      Arr_Def.Kind := Virtual_Array;
      Arr_Def.Is_Temporary := False; -- Virtual arrays are always permanent aliases
      Arr_Def.Start_Index := 1;      -- Virtual arrays are always 1-based
      Arr_Def.End_Index := Integer(Constituents'Length);
      for I in Constituents'Range loop
         Arr_Def.Constituents.Append (To_Unbounded_String (To_Upper (Constituents (I).all)));
      end loop;
      if Array_Symbols.Contains (Upper_Name) then
         Array_Symbols.Replace (Upper_Name, Arr_Def);
      else
         Array_Symbols.Insert (Upper_Name, Arr_Def);
      end if;
   end Define_Array;

   ------------------
   -- Define_Array --
   ------------------
   procedure Define_Array (Name : String; Constituents : Name_Vectors.Vector) is
      Upper_Name : constant String := To_Upper (Name);
      Arr_Def : Array_Definition_Type;
   begin
      Arr_Def.Kind := Virtual_Array;
      Arr_Def.Is_Temporary := False;
      Arr_Def.Start_Index := 1;
      Arr_Def.End_Index := Integer(Constituents.Length);
      Arr_Def.Constituents := Constituents; -- Copy the vector
      if Array_Symbols.Contains (Upper_Name) then
         Array_Symbols.Replace (Upper_Name, Arr_Def);
      else
         Array_Symbols.Insert (Upper_Name, Arr_Def);
      end if;
   end Define_Array;

   -------------------------
   -- Define_Array_Access --
   -------------------------
   procedure Define_Array_Access (Name : String; Constituents : GNAT.Strings.String_List_Access) is
   begin
      if Constituents /= null then
         Define_Array (Name, Constituents.all);
      end if;
   end Define_Array_Access;

   ----------------------------
   -- Undefine_Virtual_Array --
   ----------------------------
   procedure Undefine_Virtual_Array (Name : String) is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if Array_Symbols.Contains (Upper_Name)
         and then Array_Symbols.Element (Upper_Name).Kind = Virtual_Array
      then
         Array_Symbols.Delete (Upper_Name);
      end if;
   end Undefine_Virtual_Array;

   -------------------------
   -- List_Virtual_Arrays --
   -------------------------
   procedure List_Virtual_Arrays is
      Cursor : Array_Table_Pkg.Cursor := Array_Symbols.First;
      Found  : Boolean := False;
   begin
      while Array_Table_Pkg.Has_Element (Cursor) loop
         declare
            Arr_Def : constant Array_Definition_Type := Array_Table_Pkg.Element (Cursor);
         begin
            if Arr_Def.Kind = Virtual_Array then
               Found := True;
               declare
                  Line : Unbounded_String :=
                     To_Unbounded_String (Array_Table_Pkg.Key (Cursor) & ":");
               begin
                  for I in 1 .. Natural (Arr_Def.Constituents.Length) loop
                     Append (Line, " " & To_String (Arr_Def.Constituents (I)));
                  end loop;
                  SData_Core.IO.Put_Line (To_String (Line));
               end;
            end if;
         end;
         Array_Table_Pkg.Next (Cursor);
      end loop;
      if not Found then
         SData_Core.IO.Put_Line ("(no virtual arrays defined)");
      end if;
   end List_Virtual_Arrays;
   
   -------------------------
   -- Create_Real_Elements --
   -------------------------
   procedure Create_Real_Elements (Arr_Def : in out Array_Definition_Type) is
      -- This procedure constructs the actual variable names and, if permanent, adds them as columns.
      -- Assumes Arr_Def.Constituents only contains the base array name (e.g., "X")
      Name_Prefix : constant String := To_String (Arr_Def.Constituents.First_Element); -- Base name like "X"
      Old_Constituents : constant Name_Vectors.Vector := Arr_Def.Constituents; -- Temporarily hold base name
   begin
      Arr_Def.Constituents.Clear;
      -- Put base name back in Constituent[0] for easy access by Get_Real_Var_Name
      Arr_Def.Constituents.Append (Old_Constituents.First_Element);

      for I in Arr_Def.Start_Index .. Arr_Def.End_Index loop
         declare
            Var_Name : constant String := Get_Real_Var_Name (Name_Prefix, I);
         begin
            Arr_Def.Constituents.Append (To_Unbounded_String(Var_Name));
            
            -- If not temporary, create as permanent column if it doesn't exist
            if not Arr_Def.Is_Temporary and then not SData_Core.Table.Has_Column (Var_Name) then
               -- Type based on suffix of Name_Prefix if available, else numeric
               declare
                  Typ : SData_Core.Table.Column_Type := SData_Core.Table.Col_Numeric;
               begin
                  if Name_Prefix'Length > 0 then
                     if Name_Prefix (Name_Prefix'Last) = '$' then Typ := SData_Core.Table.Col_String;
                     elsif Name_Prefix (Name_Prefix'Last) = '%' then Typ := SData_Core.Table.Col_Integer; end if;
                  end if;
                  SData_Core.Table.Add_Column (Var_Name, Typ);
               end;
            end if;
            --  Keep PDV aligned with Data_Table. Add_Column just grew the input
            --  table; if this element was never assigned via LET its PDV slot
            --  won't exist, causing Load_PDV_From_Table to walk off PDV_Names.
            if not Arr_Def.Is_Temporary then
               declare
                  Upper : constant String := To_Upper (Var_Name);
               begin
                  if not PDV_Index.Contains (Upper) then
                     PDV_Names.Append (To_Unbounded_String (Upper));
                     PDV_Vec.Append ((Kind => Val_Missing));
                     PDV_Index.Insert (Upper, Positive (PDV_Names.Length));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Create_Real_Elements;

   ------------------
   -- Dim_Array --
   ------------------
   procedure Dim_Array (Name : String; Start_Idx, End_Idx : Integer; Is_Temp : Boolean) is
      Upper_Name : constant String := To_Upper (Name);
      Arr_Def : Array_Definition_Type;
   begin
      -- Validate indices
      if Start_Idx > End_Idx then
         raise Program_Error with "DIM array lower bound " & Integer'Image(Start_Idx) & " cannot be greater than upper bound " & Integer'Image(End_Idx);
      end if;

      Arr_Def.Kind := Real_Array;
      Arr_Def.Is_Temporary := Is_Temp;
      Arr_Def.Start_Index := Start_Idx;
      Arr_Def.End_Index := End_Idx;
      Arr_Def.Constituents.Append (To_Unbounded_String(Upper_Name)); -- Base name at Constituents[0]

      -- Handle Redefinition/Resizing
      if Array_Symbols.Contains (Upper_Name) then
         declare
            Existing_Def : constant Array_Definition_Type := Array_Symbols.Element (Upper_Name);
         begin
            if Existing_Def.Kind = Virtual_Array then
               raise Program_Error with "Cannot redefine virtual array '" & Upper_Name & "' as real array with DIM.";
            elsif Existing_Def.Kind = Real_Array then
               -- Check for temporary status change
               if Existing_Def.Is_Temporary /= Is_Temp then
                  raise Program_Error with "Cannot change temporary status of existing real array '" & Upper_Name & "'.";
               end if;
               
               -- Drop orphaned columns (outside new range); kept columns and their data are preserved.
               for I in Existing_Def.Start_Index .. Existing_Def.End_Index loop
                  -- Delete variable from system if it was part of this real array
                  declare
                     Var_Name : constant String := Get_Real_Var_Name (To_String(Existing_Def.Constituents.First_Element), I);
                  begin
                     if not Existing_Def.Is_Temporary and then SData_Core.Table.Has_Column (Var_Name)
                        and then (I < Start_Idx or else I > End_Idx)
                     then
                        SData_Core.Table.Drop_Column (Var_Name);
                     end if;
                     -- For temporary elements, clear from Temp_Symbols
                     if Existing_Def.Is_Temporary and then Temp_Symbols.Contains (Var_Name) then
                        Symbol_Table_Pkg.Delete (Temp_Symbols, Var_Name);
                     end if;
                  end;
               end loop;
            end if;
         end;
      end if;

      -- Create new elements / Add elements for expansion
      Create_Real_Elements (Arr_Def);

      if Array_Symbols.Contains (Upper_Name) then
         Array_Symbols.Replace (Upper_Name, Arr_Def);
      else
         Array_Symbols.Insert (Upper_Name, Arr_Def);
      end if;
   end Dim_Array;

   -----------------------
   -- Get_Array_Element --
   -----------------------
   function Get_Array_Element (Name : String; Index : Integer) return Value is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if not Array_Symbols.Contains (Upper_Name) then
         return (Kind => Val_Missing);
      end if;
      
      declare
         Arr_Def : constant Array_Definition_Type := Array_Symbols.Element (Upper_Name);
      begin
         if Index < Arr_Def.Start_Index or else Index > Arr_Def.End_Index then
            return (Kind => Val_Missing); -- Index out of bounds
         end if;

         if Arr_Def.Kind = Virtual_Array then
            -- Lookup from constituents list
            declare
               Offset : constant Positive := Index - Arr_Def.Start_Index + 1; -- Virtual arrays are 1-based internally
            begin
               if Offset > Integer(Arr_Def.Constituents.Length) then
                  return (Kind => Val_Missing); -- Should not happen if array correctly defined
               end if;
               return Get (To_String (Arr_Def.Constituents.Element (Offset)));
            end;
         else -- Real_Array
            -- Construct name like ARRAY_NAME(INDEX)
            return Get (Get_Real_Var_Name (To_String(Arr_Def.Constituents.First_Element), Index));
         end if;
      end;
   end Get_Array_Element;

   -----------------------
   -- Set_Array_Element --
   -----------------------
   procedure Set_Array_Element (Name : String; Index : Integer; Val : Value) is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if not Array_Symbols.Contains (Upper_Name) then
         -- Implicit creation if array does not exist and it's a permanent Real_Array
         -- For now, error if not defined. DIM must define it explicitly.
         raise Program_Error with "Array '" & Upper_Name & "' not defined.";
      end if;

      declare
         Arr_Def : constant Array_Definition_Type := Array_Symbols.Element (Upper_Name);
      begin
         if Index < Arr_Def.Start_Index or else Index > Arr_Def.End_Index then
            raise Program_Error with "Array index " & Index'Image & " out of bounds for '" & Upper_Name & "'.";
         end if;

         declare
            Var_Name_Str : Unbounded_String;
         begin
            if Arr_Def.Kind = Virtual_Array then
               -- Lookup from constituents list
               declare
                  Offset : constant Positive := Index - Arr_Def.Start_Index + 1;
               begin
                  if Offset > Integer(Arr_Def.Constituents.Length) then
                     raise Program_Error with "Array index " & Index'Image & " out of bounds for virtual array '" & Upper_Name & "'.";
                  end if;
                  Var_Name_Str := To_Unbounded_String (To_String (Arr_Def.Constituents.Element (Offset)));
               end;
            else -- Real_Array
               -- Construct name like ARRAY_NAME(INDEX)
               Var_Name_Str := To_Unbounded_String (Get_Real_Var_Name (To_String(Arr_Def.Constituents.First_Element), Index));
            end if;

            -- Set the value using appropriate scope (temporary or permanent)
            if Arr_Def.Is_Temporary then
               Set_Temporary (To_String (Var_Name_Str), Val);
            else
               Set_Permanent (To_String (Var_Name_Str), Val);
            end if;
         end;
      end;
   end Set_Array_Element;

   ---------------
   -- Has_Array --
   ---------------
   function Has_Array (Name : String) return Boolean is
   begin
      return Array_Symbols.Contains (To_Upper (Name));
   end Has_Array;

   ------------------------
   -- Is_Temporary_Array --
   ------------------------
   function Is_Temporary_Array (Name : String) return Boolean is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if Array_Symbols.Contains (Upper_Name) then
         return Array_Symbols.Element (Upper_Name).Is_Temporary;
      else
         return False;
      end if;
   end Is_Temporary_Array;

   ----------------------
   -- Get_Array_Bounds --
   ----------------------
   procedure Get_Array_Bounds (Name : String; Start_Idx, End_Idx : out Integer) is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if Array_Symbols.Contains (Upper_Name) then
         declare
            Arr_Def : constant Array_Definition_Type := Array_Symbols.Element (Upper_Name);
         begin
            Start_Idx := Arr_Def.Start_Index;
            End_Idx   := Arr_Def.End_Index;
         end;
      else
         Start_Idx := 0;
         End_Idx   := -1;
      end if;
   end Get_Array_Bounds;

   ----------------------------
   -- Get_Array_Element_Column --
   ----------------------------
   function Get_Array_Element_Column (Name : String; Index : Integer) return String is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if Array_Symbols.Contains (Upper_Name) then
         declare
            Arr_Def : constant Array_Definition_Type :=
               Array_Symbols.Element (Upper_Name);
         begin
            if Arr_Def.Kind = Virtual_Array then
               --  Constituents vector is 1-indexed; virtual arrays always start at 1.
               return To_String (Arr_Def.Constituents.Element (Index));
            else
               return Get_Real_Var_Name (Upper_Name, Index);
            end if;
         end;
      else
         return Get_Real_Var_Name (Upper_Name, Index);
      end if;
   end Get_Array_Element_Column;

   --------------
   -- Set_Hold --
   --------------
   procedure Set_Hold (Name : String; State : Boolean) is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if Upper_Name = "" then return; end if;
      if Hold_Symbols.Contains (Upper_Name) then
         Hold_Symbols.Replace (Upper_Name, State);
      else
         Hold_Symbols.Insert (Upper_Name, State);
      end if;
   end Set_Hold;

   -------------
   -- Is_Held --
   -------------
   function Is_Held (Name : String) return Boolean is
      Upper_Name : constant String := To_Upper (Name);
   begin
      if Hold_Symbols.Contains (Upper_Name) then
         return Hold_Symbols.Element (Upper_Name);
      else
         return False;
      end if;
   end Is_Held;

   --------------------------
   -- Set_Current_Group_Key --
   --------------------------
   procedure Set_Current_Group_Key (Key : String) is
   begin
      Current_Group_ID := To_Unbounded_String (Key);
   end Set_Current_Group_Key;

   --------------------------
   -- Get_Current_Group_Key --
   --------------------------
   function Get_Current_Group_Key return String is
   begin
      return To_String (Current_Group_ID);
   end Get_Current_Group_Key;

   -----------------------------------
   -- Register_Subscripted_Columns  --
   -----------------------------------
   procedure Register_Subscripted_Columns is
      --  Map from upper-cased base name to (Min, Max) subscript pair.
      type Bounds_Record is record
         Min_Idx : Integer;
         Max_Idx : Integer;
      end record;

      package Bounds_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type        => String,
         Element_Type    => Bounds_Record,
         Hash            => Ada.Strings.Hash,
         Equivalent_Keys => "=");

      Map : Bounds_Maps.Map;

   begin
      --  Pass 1: scan column names and record min/max subscript per base name.
      for I in 1 .. Column_Count loop
         declare
            Name : constant String := Column_Name (I);
            LP   : constant Natural :=
               Ada.Strings.Fixed.Index (Name, "(");
            RP   : constant Natural :=
               Ada.Strings.Fixed.Index (Name, ")");
         begin
            if LP > 1 and then RP = Name'Last and then RP > LP + 1 then
               declare
                  Idx : Integer;
               begin
                  Idx := Integer'Value (Name (LP + 1 .. RP - 1));
                  if Idx > 0 then
                     declare
                        Base : constant String := Name (Name'First .. LP - 1);
                        Cur  : constant Bounds_Maps.Cursor :=
                           Map.Find (Base);
                     begin
                        if Bounds_Maps.Has_Element (Cur) then
                           declare
                              B : Bounds_Record := Bounds_Maps.Element (Cur);
                           begin
                              if Idx < B.Min_Idx then B.Min_Idx := Idx; end if;
                              if Idx > B.Max_Idx then B.Max_Idx := Idx; end if;
                              Map.Replace (Base, B);
                           end;
                        else
                           Map.Insert (Base, (Min_Idx => Idx, Max_Idx => Idx));
                        end if;
                     end;
                  end if;
               exception
                  when Constraint_Error => null;  -- non-integer subscript; skip
               end;
            end if;
         end;
      end loop;

      --  Pass 2: register each base name as a DIM array.
      for Pos in Map.Iterate loop
         declare
            Base   : constant String       := Bounds_Maps.Key (Pos);
            Bounds : constant Bounds_Record := Bounds_Maps.Element (Pos);
         begin
            Dim_Array (Base, Bounds.Min_Idx, Bounds.Max_Idx, False);
         end;
      end loop;
   end Register_Subscripted_Columns;

end SData_Core.Variables;