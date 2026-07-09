--  Exercises the pure-functional surface of SData_Core.Values:
--  Is_Inf, To_String, Is_True, "=", "<" across every Value Kind.
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;          use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with SData_Core.Values;    use SData_Core.Values;

procedure Values_Tests is

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

   function N (X : Float)   return Value is ((Kind => Val_Numeric, Num_Val => X));
   function I (X : Integer) return Value is ((Kind => Val_Integer, Int_Val => X));
   function S (T : String)  return Value is
      ((Kind => Val_String, Str_Val => To_Unbounded_String (T)));
   M : constant Value := (Kind => Val_Missing);

begin
   Put_Line ("=== Values_Tests ===");

   --  Is_Inf
   Assert (Is_Inf (Pos_Inf),    "Is_Inf(Pos_Inf)");
   Assert (Is_Inf (Neg_Inf),    "Is_Inf(Neg_Inf)");
   Assert (not Is_Inf (0.0),    "not Is_Inf(0.0)");
   Assert (not Is_Inf (1.0e30), "not Is_Inf(1.0e30)");
   Assert (not Is_Inf (-1.0e30), "not Is_Inf(-1.0e30)");

   --  To_String
   Assert (To_String (N (1.5))'Length > 0, "To_String(Numeric finite) non-empty");
   Assert (To_String (I (42))  = "42",     "To_String(Integer 42)");
   Assert (To_String (I (-7))  = "-7",     "To_String(Integer -7)");
   Assert (To_String (S ("abc"))    = "abc", "To_String(String 'abc')");
   Assert (To_String (S (""))       = "",    "To_String(String empty)");
   Assert (To_String (M)            = ".",   "To_String(Missing)");
   Assert (To_String (N (Pos_Inf))  = "Inf", "To_String(Pos_Inf)");
   Assert (To_String (N (Neg_Inf))  = "-Inf", "To_String(Neg_Inf)");

   --  Is_True per Kind
   Assert (Is_True (N (1.0)),     "Is_True(Numeric 1.0)");
   Assert (Is_True (N (-1.0)),    "Is_True(Numeric -1.0)");
   Assert (not Is_True (N (0.0)), "not Is_True(Numeric 0.0)");
   Assert (Is_True (I (42)),      "Is_True(Integer 42)");
   Assert (Is_True (I (-1)),      "Is_True(Integer -1)");
   Assert (not Is_True (I (0)),   "not Is_True(Integer 0)");
   Assert (Is_True (S ("x")),     "Is_True(String 'x')");
   Assert (not Is_True (S ("")),  "not Is_True(String empty)");
   Assert (not Is_True (M),       "not Is_True(Missing)");

   --  "=" per Kind combination
   Assert (I (5) = I (5),           "Integer = Integer same");
   Assert (N (5.0) = N (5.0),       "Numeric = Numeric same");
   Assert (I (5) = N (5.0),         "Integer = Numeric cross-promotion");
   Assert (N (5.0) = I (5),         "Numeric = Integer cross-promotion");
   Assert (S ("ab") = S ("ab"),     "String = String same");
   Assert (M = M,                   "Missing = Missing");
   Assert (not (I (5) = I (6)),     "Integer /= Integer different");
   Assert (not (S ("a") = S ("b")), "String /= String different");
   Assert (not (I (5) = S ("5")),   "Integer /= String (no cross-type)");
   Assert (not (I (5) = M),         "Integer /= Missing");

   --  "<" semantics
   Assert (M < I (0),                  "Missing < anything non-missing");
   Assert (M < S ("a"),                "Missing < String");
   Assert (M < N (-1.0e30),            "Missing < negative numeric");
   Assert (not (I (0) < M),            "not (Integer < Missing)");
   Assert (not (M < M),                "not (Missing < Missing)");
   Assert (I (1) < I (2),              "Integer < Integer");
   Assert (N (1.0) < N (2.0),          "Numeric < Numeric");
   Assert (I (1) < N (2.0),            "Integer < Numeric cross");
   Assert (N (1.0) < I (2),            "Numeric < Integer cross");
   Assert (S ("a") < S ("b"),          "String < String");
   Assert (not (I (2) < I (1)),        "not (Integer < smaller Integer)");
   Assert (I (1) < S ("a"),            "Numeric < String (arbitrary)");
   Assert (not (S ("a") < I (1)),      "String not < Numeric (arbitrary)");

   --  Image_Round_Trip: clean cases are exact; others must round-trip.
   Assert (Image_Round_Trip (0.0)    = "0",    "RT 0.0");
   Assert (Image_Round_Trip (150.0)  = "150",  "RT 150.0");
   Assert (Image_Round_Trip (0.5)    = "0.5",  "RT 0.5");
   Assert (Image_Round_Trip (-2.5)   = "-2.5", "RT -2.5");
   Assert (Image_Round_Trip (100.0)  = "100",  "RT 100.0");
   Assert (Float'Value (Image_Round_Trip (0.1))        = 0.1,        "RT 0.1 round-trips");
   Assert (Float'Value (Image_Round_Trip (1.0 / 3.0))  = 1.0 / 3.0,  "RT 1/3 round-trips");
   Assert (Float'Value (Image_Round_Trip (123456.789)) = Float'(123456.789),
           "RT 123456.789 round-trips");
   Assert (Image_Round_Trip (Pos_Inf) = "Inf",  "RT Pos_Inf");
   Assert (Image_Round_Trip (Neg_Inf) = "-Inf", "RT Neg_Inf");

   --  Image_Fixed_Decimals: round + trim trailing zeros; N=0 -> integer.
   Assert (Image_Fixed_Decimals (3.14159, 2) = "3.14", "FD 3.14159 @2");
   Assert (Image_Fixed_Decimals (0.5,     2) = "0.5",  "FD 0.5 @2 trims");
   Assert (Image_Fixed_Decimals (100.0,   2) = "100",  "FD 100 @2 trims to int");
   Assert (Image_Fixed_Decimals (3.14159, 0) = "3",    "FD 3.14159 @0");
   Assert (Image_Fixed_Decimals (3.99,    0) = "4",    "FD 3.99 @0 rounds up");

   --  Summary
   New_Line;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Values_Tests;
