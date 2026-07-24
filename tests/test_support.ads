--  Shared boilerplate for the in-crate test drivers (tests/*.adb): a
--  pass/fail counter, the summary trailer every driver ended with, and the
--  SData_Core.Values constructor/comparison helpers most drivers need.
--  Assert/Report_And_Exit were byte-identical in all nine drivers before
--  this package existed (PR #90 review); Num/I/Str/Near were the same
--  function under two or three different local names across five drivers
--  (found while checking for further duplication after that review).
with Ada.Strings.Unbounded;
with SData_Core.Values; use SData_Core.Values;

package Test_Support is

   procedure Assert (Condition : Boolean; Name : String);
   --  Records a pass or a failure (printing "  FAIL: <Name>" immediately on
   --  failure) against this driver's running Passed/Failed counters.

   procedure Report_And_Exit;
   --  Prints "<Passed> passed, <Failed> failed." and sets a non-zero process
   --  exit status if any assertion failed. Call once, as the last statement
   --  in a driver's main procedure.

   function Num (X : Real) return Value is
     ((Kind => Val_Numeric, Num_Val => X));

   function I (X : Int) return Value is
     ((Kind => Val_Integer, Int_Val => X));

   function Str (S : String) return Value is
     ((Kind => Val_String,
       Str_Val => Ada.Strings.Unbounded.To_Unbounded_String (S)));

   function Near
     (R : Value; Expected : Real; Eps : Real := 1.0e-6) return Boolean is
     (if    R.Kind = Val_Numeric then abs (R.Num_Val - Expected) <= Eps
      elsif R.Kind = Val_Integer then abs (Real (R.Int_Val) - Expected) <= Eps
      else False);

end Test_Support;
