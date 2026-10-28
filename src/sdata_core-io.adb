--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Text_IO;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps.Constants;
with Ada.Strings.UTF_Encoding;
with Ada.Strings.UTF_Encoding.Conversions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with GNAT.OS_Lib; use GNAT.OS_Lib;
with SData_Core.Config;

package body SData_Core.IO is

   --  OUTPUT redirection (design.md section 6.1): the target is written as a
   --  byte stream so that the line ending (OPTIONS TXTFMT / OUTPUT /FMT=) and
   --  the character set (OPTIONS CHARSET / OUTPUT /CHARSET=) chosen when the
   --  file was opened apply to everything written to it.
   type Redirect_Charset is (Charset_Raw, Charset_ASCII, Charset_UTF16LE, Charset_UTF16BE);

   Redirect_File    : Ada.Streams.Stream_IO.File_Type;
   Redirect_EOL     : Unbounded_String := To_Unbounded_String ("" & ASCII.LF);
   Redirect_Mode    : Redirect_Charset := Charset_Raw;
   Redirected       : Boolean := False;
   Local_Echo       : Boolean := True;
   Interactive_Mode : Boolean := False;

   --  Internal pager state (used when no external pager is configured).
   Lines_On_Page  : constant := 24;
   Max_Shell_Args : constant := 16; -- max words in a shell or pager command string
   Lines_Printed : Natural  := 0;

   --  External pager state.
   Has_External_Pager  : Boolean          := False;
   External_Pager_Cmd  : Unbounded_String := Null_Unbounded_String;
   Pager_Buffer        : Unbounded_String := Null_Unbounded_String;

   ---------------------------------------------------------------------------
   --  Internal helpers
   ---------------------------------------------------------------------------

   --  Write_Redirect -- S (UTF-8, LF line ends) to the OUTPUT file with its
   --  line ending and character set applied.  Strict => False is for the
   --  error-message path, which must not itself raise: an unrepresentable
   --  byte becomes '?' under CHARSET=ASCII instead of failing.
   procedure Write_Redirect (S : String; Strict : Boolean := True) is
      EOL   : constant String := To_String (Redirect_EOL);
      Buf   : Unbounded_String;
      Strm  : constant Ada.Streams.Stream_IO.Stream_Access :=
         Ada.Streams.Stream_IO.Stream (Redirect_File);
   begin
      for C of S loop
         if C = ASCII.LF then
            Append (Buf, EOL);
         elsif Redirect_Mode = Charset_ASCII and then Character'Pos (C) > 127 then
            if Strict then
               raise SData_Core.Script_Error with
                  "OUTPUT: non-ASCII byte (value" & Integer'Image (Character'Pos (C))
                  & ") in output -- rejected (CHARSET=ASCII)";
            end if;
            Append (Buf, '?');
         else
            Append (Buf, C);
         end if;
      end loop;
      case Redirect_Mode is
         when Charset_UTF16LE =>
            String'Write (Strm,
               Ada.Strings.UTF_Encoding.Conversions.Convert
                  (To_String (Buf), Ada.Strings.UTF_Encoding.UTF_8,
                   Ada.Strings.UTF_Encoding.UTF_16LE));
         when Charset_UTF16BE =>
            String'Write (Strm,
               Ada.Strings.UTF_Encoding.Conversions.Convert
                  (To_String (Buf), Ada.Strings.UTF_Encoding.UTF_8,
                   Ada.Strings.UTF_Encoding.UTF_16BE));
         when Charset_Raw | Charset_ASCII =>
            String'Write (Strm, To_String (Buf));
      end case;
      Ada.Streams.Stream_IO.Flush (Redirect_File);
   end Write_Redirect;

   procedure Check_Internal_Pager is
      Dummy : String (1 .. 10);
      Last  : Natural;
   begin
      if Interactive_Mode and then Local_Echo
         and then Lines_Printed >= Lines_On_Page
      then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put ("-- More -- (Press Enter)");
         begin
            Ada.Text_IO.Get_Line (Dummy, Last);
         exception
            --  End_Error is the one expected condition here: the operator
            --  sends EOF (Ctrl-D) at the prompt instead of pressing Enter.
            --  Treated the same as Enter -- continue paging -- matching the
            --  prior behavior for this specific case. Anything else
            --  (Storage_Error, Program_Error, Device_Error, ...) propagates
            --  rather than being silently swallowed; a bare `others => null`
            --  here previously masked those too (audit finding, 2026-09-26).
            when Ada.Text_IO.End_Error => null;
         end;
         Lines_Printed := 0;
      end if;
   end Check_Internal_Pager;

   --  Split a command string into whitespace-delimited words.
   --  Populates Words (1 .. Count); caller must free each non-null entry.
   --  Maximum 16 words; excess words are silently dropped.
   procedure Split_Words
     (S     :     String;
      Words : out GNAT.OS_Lib.Argument_List;
      Count : out Natural)
   is
      I       : Natural := S'First;
      W_Start : Natural;
   begin
      Count := 0;
      Words := (others => null);
      while I <= S'Last and then Count < Words'Last loop
         while I <= S'Last and then S (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > S'Last;
         W_Start := I;
         while I <= S'Last and then S (I) /= ' ' loop
            I := I + 1;
         end loop;
         Count := Count + 1;
         Words (Count) := new String'(S (W_Start .. I - 1));
      end loop;
   end Split_Words;

   ---------------------------------------------------------------------------
   --  Public procedures
   ---------------------------------------------------------------------------

   procedure Set_Interactive (Val : Boolean) is
   begin
      Interactive_Mode := Val;
   end Set_Interactive;

   function Is_Interactive return Boolean is (Interactive_Mode);

   procedure Set_Local_Echo (Val : Boolean) is
   begin
      Local_Echo := Val;
   end Set_Local_Echo;

   function Is_Local_Echo return Boolean is (Local_Echo);

   procedure Set_Pager (Cmd : String) is
      Words    : GNAT.OS_Lib.Argument_List (1 .. Max_Shell_Args);
      Count    : Natural;
      Exe_Path : GNAT.OS_Lib.String_Access;
   begin
      Split_Words (Cmd, Words, Count);
      if Count = 0 then
         return;
      end if;
      Exe_Path := GNAT.OS_Lib.Locate_Exec_On_Path (Words (1).all);
      for I in 1 .. Count loop
         GNAT.OS_Lib.Free (Words (I));
      end loop;
      if Exe_Path = null then
         raise Pager_Not_Found with
           "pager executable not found on PATH: " & Cmd;
      end if;
      GNAT.OS_Lib.Free (Exe_Path);
      External_Pager_Cmd := To_Unbounded_String (Cmd);
      Has_External_Pager := True;
   end Set_Pager;

   procedure Flush_Pager_Buffer is
      Words    : GNAT.OS_Lib.Argument_List (1 .. Max_Shell_Args);
      N_Words  : Natural;
      FD       : GNAT.OS_Lib.File_Descriptor;
      TN_Acc   : GNAT.OS_Lib.String_Access;
      TF       : Ada.Text_IO.File_Type;
      Exe_Path : GNAT.OS_Lib.String_Access;
      Success  : Boolean;
   begin
      Lines_Printed := 0;

      if not Has_External_Pager or else Length (Pager_Buffer) = 0 then
         Pager_Buffer := Null_Unbounded_String;
         return;
      end if;

      --  Write accumulated output to a temp file.
      GNAT.OS_Lib.Create_Temp_File (FD, TN_Acc);
      declare
         Close_OK : Boolean;
      begin
         GNAT.OS_Lib.Close (FD, Close_OK);
         pragma Unreferenced (Close_OK);
      end;

      declare
         Temp_Name : constant String := TN_Acc.all;
      begin
         GNAT.OS_Lib.Free (TN_Acc);

         Ada.Text_IO.Open (TF, Ada.Text_IO.Out_File, Temp_Name);
         Ada.Text_IO.Put (TF, To_String (Pager_Buffer));
         Ada.Text_IO.Close (TF);

         --  Split pager command into executable + extra args.
         Split_Words (To_String (External_Pager_Cmd), Words, N_Words);

         if N_Words > 0 then
            Exe_Path :=
               GNAT.OS_Lib.Locate_Exec_On_Path (Words (1).all);

            if Exe_Path /= null then
               declare
                  --  Args: extra pager options (words 2..N) + temp file name.
                  N_Args : constant Natural := N_Words - 1 + 1;
                  Args   : GNAT.OS_Lib.Argument_List (1 .. N_Args);
               begin
                  --  Transfer ownership of words 2..N_Words to Args.
                  for I in 2 .. N_Words loop
                     Args (I - 1) := Words (I);
                     Words (I)    := null;
                  end loop;
                  Args (N_Args) := new String'(Temp_Name);

                  GNAT.OS_Lib.Spawn (Exe_Path.all, Args, Success);

                  for I in 1 .. N_Args loop
                     GNAT.OS_Lib.Free (Args (I));
                  end loop;
               end;
               GNAT.OS_Lib.Free (Exe_Path);
            end if;
         end if;

         --  Free any word strings not transferred to Args.
         for I in 1 .. N_Words loop
            if Words (I) /= null then
               GNAT.OS_Lib.Free (Words (I));
            end if;
         end loop;

         GNAT.OS_Lib.Delete_File (Temp_Name, Success);
      end;

      Pager_Buffer := Null_Unbounded_String;
   end Flush_Pager_Buffer;

   procedure Put (Item : String) is
   begin
      if Redirected then
         Write_Redirect (Item);
      end if;

      if Local_Echo then
         if Has_External_Pager and then Interactive_Mode then
            Append (Pager_Buffer, Item);
         else
            Ada.Text_IO.Put (Ada.Text_IO.Standard_Output, Item);
            Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);
            --  Count newlines in the item to maintain pager state.
            for C of Item loop
               if C = ASCII.LF then
                  Lines_Printed := Lines_Printed + 1;
               end if;
            end loop;
            if Lines_Printed >= Lines_On_Page then
               Check_Internal_Pager;
            end if;
         end if;
      end if;
   end Put;

   procedure Put_Line (Item : String) is
   begin
      if Redirected then
         Write_Redirect (Item & ASCII.LF);
      end if;

      if Local_Echo then
         if Has_External_Pager and then Interactive_Mode then
            Append (Pager_Buffer, Item & ASCII.LF);
         else
            Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Output, Item);
            Lines_Printed := Lines_Printed + 1;
            Check_Internal_Pager;
         end if;
      end if;
   end Put_Line;

   procedure New_Line is
   begin
      if Redirected then
         Write_Redirect ("" & ASCII.LF);
      end if;

      if Local_Echo then
         if Has_External_Pager and then Interactive_Mode then
            Append (Pager_Buffer, "" & ASCII.LF);
         else
            Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Output);
            Lines_Printed := Lines_Printed + 1;
            Check_Internal_Pager;
         end if;
      end if;
   end New_Line;

   procedure Put_Error (Item : String) is
   begin
      if Redirected then
         Write_Redirect (Item, Strict => False);
      end if;
      Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Item);
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
   end Put_Error;

   procedure Put_Line_Error (Item : String) is
   begin
      if Redirected then
         Write_Redirect (Item & ASCII.LF, Strict => False);
      end if;
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Item);
   end Put_Line_Error;

   procedure Show_Progress
     (Phase : String; Count : Natural; Final : Boolean := False)
   is
      Interval : constant := 10_000;
      Img      : constant String := Count'Image;  --  leading space when >= 0
      Num      : constant String := Img (Img'First + 1 .. Img'Last);
   begin
      if not SData_Core.Config.Progress then
         return;
      end if;
      --  Progress goes only to stderr (never the redirected output stream), so
      --  it cannot corrupt piped/saved data.
      if Final or else Count mod Interval = 0 then
         Ada.Text_IO.Put
           (Ada.Text_IO.Standard_Error,
            ASCII.CR & Phase & ": " & Num & " records");
         if Final then
            Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
         end if;
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      end if;
   end Show_Progress;

   procedure Open_Output (Filename : String;
                          TXTFMT   : String := "";
                          Charset  : String := "") is
      UF : constant String :=
         Ada.Strings.Fixed.Translate
           (Ada.Strings.Fixed.Trim (TXTFMT, Ada.Strings.Both),
            Ada.Strings.Maps.Constants.Upper_Case_Map);
      UC : constant String :=
         Ada.Strings.Fixed.Translate
           (Ada.Strings.Fixed.Trim (Charset, Ada.Strings.Both),
            Ada.Strings.Maps.Constants.Upper_Case_Map);
   begin
      if Redirected then
         Close_Output;
      end if;
      begin
         Ada.Streams.Stream_IO.Create
           (Redirect_File, Ada.Streams.Stream_IO.Out_File, Filename);
      exception
         when Ada.Streams.Stream_IO.Name_Error =>
            raise SData_Core.Script_Error with "OUTPUT: invalid file name """ & Filename & """";
         when Ada.Streams.Stream_IO.Use_Error =>
            raise SData_Core.Script_Error with "OUTPUT: cannot create """ & Filename & """: permission denied";
      end;
      Redirect_EOL :=
        To_Unbounded_String
          (if    UF = "CRLF" then "" & ASCII.CR & ASCII.LF
           elsif UF = "CR"   then "" & ASCII.CR
           else                   "" & ASCII.LF);
      Redirect_Mode :=
        (if    UC = "ASCII"                        then Charset_ASCII
         elsif UC = "UTF-16" or else UC = "UTF-16LE" then Charset_UTF16LE
         elsif UC = "UTF-16BE"                     then Charset_UTF16BE
         else                                           Charset_Raw);
      Redirected := True;
      --  UTF-16 output starts with a byte-order mark, as SAVE's does.
      case Redirect_Mode is
         when Charset_UTF16LE =>
            String'Write (Ada.Streams.Stream_IO.Stream (Redirect_File),
                          "" & Character'Val (16#FF#) & Character'Val (16#FE#));
         when Charset_UTF16BE =>
            String'Write (Ada.Streams.Stream_IO.Stream (Redirect_File),
                          "" & Character'Val (16#FE#) & Character'Val (16#FF#));
         when others => null;
      end case;
   end Open_Output;

   procedure Close_Output is
   begin
      if Redirected then
         Ada.Streams.Stream_IO.Close (Redirect_File);
         Redirected := False;
      end if;
   end Close_Output;

   function Is_Redirected return Boolean is
   begin
      return Redirected;
   end Is_Redirected;

end SData_Core.IO;