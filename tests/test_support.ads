--  Shared boilerplate for the in-crate test drivers (tests/*.adb): a
--  pass/fail counter and the summary trailer every driver ended with,
--  byte-identical in all nine before this package existed (PR #90 review).
package Test_Support is

   procedure Assert (Condition : Boolean; Name : String);
   --  Records a pass or a failure (printing "  FAIL: <Name>" immediately on
   --  failure) against this driver's running Passed/Failed counters.

   procedure Report_And_Exit;
   --  Prints "<Passed> passed, <Failed> failed." and sets a non-zero process
   --  exit status if any assertion failed. Call once, as the last statement
   --  in a driver's main procedure.

end Test_Support;
