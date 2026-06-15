--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Config;
with SData_Core.Signals;
with SData_Core.Values; use SData_Core.Values;
with SData_Core.Columns; use SData_Core.Columns;
with GNAT.OS_Lib;
with GNAT.Strings;
with Ada_Sqlite3; use Ada_Sqlite3;

package body SData_Core.Backing_Store is

   function Sql_Id (Name : String) return String is
      Buf : String (1 .. Name'Length * 2);
      Len : Natural := 0;
   begin
      for C of Name loop
         Len := Len + 1;
         Buf (Len) := C;
         if C = ']' then
            Len := Len + 1;
            Buf (Len) := ']';
         end if;
      end loop;
      return "[" & Buf (1 .. Len) & "]";
   end Sql_Id;

   function Is_Active (Self : Backing_Store) return Boolean is
   begin
      return Self.Is_Active;
   end Is_Active;

   function Path (Self : Backing_Store) return String is
   begin
      if Self.Is_Active then
         return To_String (Self.Temp_Path);
      else
         return "";
      end if;
   end Path;

   procedure Clear_Cache (Self : in out Backing_Store) is
   begin
      Self.Seg_Cache.Clear;
      Self.Seg_Start := 0;
      Self.Seg_End   := 0;
   end Clear_Cache;

   procedure Execute (Self : in out Backing_Store; SQL : String) is
   begin
      Self.DB.Execute (SQL);
   end Execute;

   procedure Open (Self : in out Backing_Store) is
      FD : GNAT.OS_Lib.File_Descriptor;
      Temp_Name : GNAT.Strings.String_Access;
   begin
      if Self.Is_Active then return; end if;
      GNAT.OS_Lib.Create_Temp_File (FD, Temp_Name);
      GNAT.OS_Lib.Close (FD);
      Self.Temp_Path := To_Unbounded_String (Temp_Name.all);
      Self.DB := new Ada_Sqlite3.Database'(Ada_Sqlite3.Open (Temp_Name.all));
      --  This is a process-private temp file; we need no durability at all.
      --  Disable the journal and fsync entirely, and give SQLite a large page
      --  cache so that external-merge sort runs stay hot across passes.
      --  temp_store=MEMORY keeps SQLite's own sort intermediates in RAM.
      Self.DB.Execute ("PRAGMA journal_mode = OFF");
      Self.DB.Execute ("PRAGMA synchronous = OFF");
      Self.DB.Execute ("PRAGMA cache_size = -65536");  --  64 MB (negative = KiB)
      Self.DB.Execute ("PRAGMA temp_store = MEMORY");
      Self.Is_Active := True;
      SData_Core.Signals.Register_Cleanup_Path (Temp_Name.all);
      GNAT.Strings.Free (Temp_Name);
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not create disk backing store for dataset"
            & " [temp_path=" & To_String (Self.Temp_Path) & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Open;

   procedure Close (Self : in out Backing_Store) is
      Success : Boolean;
   begin
      if not Self.Is_Active then return; end if;
      --  Mark inactive first so a second call (explicit + automatic) is a no-op.
      Self.Is_Active := False;
      SData_Core.Signals.Clear_Cleanup_Path;
      declare
         Path : constant String := To_String (Self.Temp_Path);
      begin
         --  We avoid manually freeing Self.DB here: doing so triggers a
         --  double-finalization crash inside Ada_Sqlite3 (observed with
         --  ada_sqlite3 0.1.1 -- the only published version; upstream
         --  github.com/gtnoble/ada-sqlite3 @ 2edbceb).  No upstream issue
         --  is filed as of 2026-06-02 and no fixed release exists.  The OS
         --  reclaims the memory; we only need to remove the file.  REVISIT
         --  when bumping ada_sqlite3 past 0.1.1 (see alire.toml): re-test
         --  whether freeing Self.DB is safe and, if so, drop this leak.
         GNAT.OS_Lib.Delete_File (Path, Success);
      end;
      Self.Seg_Cache.Clear;
      Self.Seg_Start := 0;
      Self.Seg_End   := 0;
   end Close;

   overriding procedure Finalize (Self : in out Backing_Store) is
   begin
      Close (Self);
   end Finalize;

   procedure Spill (Self  : in out Backing_Store;
                    T     : in out Columns.Column_Maps.Map;
                    Name  : String;
                    Start : Positive) is
      SQL : Unbounded_String;
      Memory_Rows : Natural := 0;
      package Name_Vecs is new Ada.Containers.Vectors (Positive, Unbounded_String);
      package Cursor_Vecs is new Ada.Containers.Vectors
        (Positive, Columns.Column_Maps.Cursor, Columns.Column_Maps."=");
      Col_Names   : Name_Vecs.Vector;
      Col_Cursors : Cursor_Vecs.Vector;
   begin
      if T.Is_Empty then return; end if;

      --  Clear cache because we might be modifying the table being cached.
      Clear_Cache (Self);
      for Pos in T.Iterate loop
         Col_Names.Append
           (To_Unbounded_String (Columns.Image (Columns.Column_Maps.Key (Pos))));
         Col_Cursors.Append (Pos);
         if Memory_Rows = 0 then
            Memory_Rows := Natural
              (Columns.Column_Maps.Constant_Reference (T, Pos).Element.all.Data.Length);
         end if;
      end loop;
      if Memory_Rows = 0 then return; end if;
      Open (Self);

      SQL := To_Unbounded_String
        ("CREATE TABLE IF NOT EXISTS [" & Name & "] (record_id INTEGER PRIMARY KEY");
      for C in 1 .. Natural (Col_Names.Length) loop
         declare
            Ref   : constant Columns.Column_Maps.Constant_Reference_Type :=
               Columns.Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
            SQL_T : constant String := (if Ref.Element.all.Typ = Col_Numeric then "REAL"
                                        elsif Ref.Element.all.Typ = Col_Integer then "INTEGER"
                                        else "TEXT");
         begin
            Append (SQL, ", " & Sql_Id (To_String (Col_Names.Element (C))) & " " & SQL_T);
         end;
      end loop;
      Append (SQL, ")");
      Self.DB.Execute (To_String (SQL));

      SQL := To_Unbounded_String
        ("INSERT OR REPLACE INTO [" & Name & "] (record_id");
      for N of Col_Names loop Append (SQL, ", " & Sql_Id (To_String (N))); end loop;
      Append (SQL, ") VALUES (?");
      for I in 1 .. Natural (Col_Names.Length) loop Append (SQL, ", ?"); end loop;
      Append (SQL, ")");

      declare
         Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare (To_String (SQL));
      begin
         --  Batch all inserts in one transaction; without this, SQLite
         --  auto-commits each row individually, causing O(N) lock cycles.
         Self.DB.Execute ("BEGIN");
         for R in 1 .. Memory_Rows loop
            Stmt.Reset;
            Stmt.Clear_Bindings;
            Stmt.Bind_Int (1, Start + R - 1);
            for C in 1 .. Natural (Col_Names.Length) loop
               declare
                  Ref : constant Columns.Column_Maps.Constant_Reference_Type :=
                     Columns.Column_Maps.Constant_Reference (T, Col_Cursors.Element (C));
                  Val : constant Value := Ref.Element.all.Data.Element (R);
               begin
                  case Val.Kind is
                     when Val_Numeric => Stmt.Bind_Double (C + 1, Val.Num_Val);
                     when Val_Integer => Stmt.Bind_Int (C + 1, Val.Int_Val);
                     when Val_String  => Stmt.Bind_Text (C + 1, To_String (Val.Str_Val));
                     when Val_Missing => Stmt.Bind_Null (C + 1);
                  end case;
               end;
            end loop;
            Stmt.Step;
         end loop;
         Self.DB.Execute ("COMMIT");
      end;

      for Pos in T.Iterate loop T.Reference (Pos).Element.all.Data.Clear; end loop;
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not write dataset to disk (disk full?)"
            & " [table=" & Name
            & ", rows=" & Columns.Img (Memory_Rows)
            & ", segment_start=" & Columns.Img (Start) & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Spill;

   function Fetch (Self      : in out Backing_Store;
                   Row       : Positive;
                   Col       : String;
                   T         : Columns.Column_Maps.Map;
                   Row_Count : Natural) return SData_Core.Values.Value is
      U_Col : constant String := Ada.Characters.Handling.To_Upper (Col);
   begin
      --  Load a new segment when Row falls outside the cached range.
      if Self.Seg_Start = 0 or else Row < Self.Seg_Start or else Row > Self.Seg_End then
         declare
            Col_Count : constant Positive := Positive'Max (1, Natural (T.Length));
            Limit   : constant Positive :=
               (if SData_Core.Config.Max_Table_Cells > 0
                then Positive'Max (1, SData_Core.Config.Max_Table_Cells / Col_Count)
                else 1);
            S_Idx   : constant Natural  := (Row - 1) / Limit;
            S_Start : constant Positive := S_Idx * Limit + 1;
            S_End   : constant Positive :=
               Positive'Min (S_Start + Limit - 1, Row_Count);
            Num_Rows : constant Natural := S_End - S_Start + 1;
            Stmt : Ada_Sqlite3.Statement := Self.DB.Prepare
               ("SELECT * FROM [data] WHERE record_id >= ? AND record_id <= ?" &
                " ORDER BY record_id");
            Num_Cols : Integer;
         begin
            Stmt.Bind_Int (1, S_Start);
            Stmt.Bind_Int (2, S_End);
            Self.Seg_Cache.Clear;

            --  Column count is known from the prepared statement before stepping.
            Num_Cols := Stmt.Column_Count - 1;  --  exclude record_id at index 0

            --  Pre-insert an empty vector for each data column and reserve
            --  capacity so that subsequent Appends do not reallocate.
            for I in 1 .. Num_Cols loop
               declare
                  CName : constant String := Stmt.Column_Name (I);
                  Empty : constant Columns.Value_Vectors.Vector :=
                     Columns.Value_Vectors.Empty_Vector;
               begin
                  Self.Seg_Cache.Include (CName, Empty);
                  Self.Seg_Cache.Reference (CName).Reserve_Capacity
                     (Ada.Containers.Count_Type (Num_Rows));
               end;
            end loop;

            --  Fetch all rows in one sequential scan.
            while Stmt.Step = Ada_Sqlite3.ROW loop
               for I in 1 .. Num_Cols loop
                  declare
                     CName : constant String := Stmt.Column_Name (I);
                     Typ   : constant Ada_Sqlite3.Column_Type := Stmt.Get_Column_Type (I);
                     Val   : Value;
                  begin
                     if Stmt.Column_Is_Null (I) then
                        Val := (Kind => Val_Missing);
                     elsif Typ = Ada_Sqlite3.Float_Type then
                        Val := (Kind => Val_Numeric, Num_Val => Stmt.Column_Double (I));
                     elsif Typ = Ada_Sqlite3.Integer_Type then
                        Val := (Kind => Val_Integer, Int_Val => Stmt.Column_Int (I));
                     else
                        Val := (Kind    => Val_String,
                                Str_Val => To_Unbounded_String (Stmt.Column_Text (I)));
                     end if;
                     Self.Seg_Cache.Reference (CName).Append (Val);
                  end;
               end loop;
            end loop;

            Self.Seg_Start := S_Start;
            Self.Seg_End   := S_End;
         end;
      end if;

      --  Return the cached value.
      if Self.Seg_Cache.Contains (U_Col) then
         declare
            Idx : constant Positive := Row - Self.Seg_Start + 1;
            Ref : constant Seg_Data_Maps.Constant_Reference_Type :=
               Self.Seg_Cache.Constant_Reference (U_Col);
         begin
            if Idx <= Natural (Ref.Length) then
               return Ref.Element (Idx);
            end if;
         end;
      end if;
      return (Kind => Val_Missing);
   exception
      when E : SQLite_Error =>
         raise Script_Error with
            "could not read dataset from disk "
            & "(backing store corrupted or missing?)"
            & " [row=" & Columns.Img (Row)
            & ", column=" & U_Col & "]: "
            & Ada.Exceptions.Exception_Message (E);
   end Fetch;

end SData_Core.Backing_Store;
