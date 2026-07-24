with Ada.Text_IO;      use Ada.Text_IO;
with Ada.Command_Line;

package body Test_Support is

   Passed, Failed : Natural := 0;

   procedure Assert (Condition : Boolean; Name : String) is
   begin
      if Condition then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("  FAIL: " & Name);
      end if;
   end Assert;

   procedure Report_And_Exit is
   begin
      New_Line;
      Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
      if Failed > 0 then
         Ada.Command_Line.Set_Exit_Status (1);
      end if;
   end Report_And_Exit;

end Test_Support;
