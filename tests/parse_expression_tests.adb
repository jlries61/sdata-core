--  Exercises SData_Core.Evaluator.Parse_Expression: round-trip
--  parse -> Free_Expression for one example of each Expression_Kind
--  plus a few composites, plus malformed strings that must raise
--  SData_Core.Script_Error.
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;          use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Exceptions;
with SData_Core;
with SData_Core.Evaluator; use SData_Core.Evaluator;

procedure Parse_Expression_Tests is

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

   procedure Parses_To (Text     : String;
                        Expected : Expression_Kind;
                        Name     : String) is
      Expr : Expression_Access;
   begin
      Expr := Parse_Expression (Text);
      Assert (Expr /= null and then Expr.Kind = Expected, Name);
      Free_Expression (Expr);
   exception
      when E : others =>
         Failed := Failed + 1;
         Put_Line ("  FAIL: " & Name & " raised "
                   & Ada.Exceptions.Exception_Name (E));
   end Parses_To;

   procedure Rejects (Text : String; Name : String) is
      Expr : Expression_Access;
   begin
      Expr := Parse_Expression (Text);
      --  No exception: the parse should have rejected the input.
      Failed := Failed + 1;
      Put_Line ("  FAIL: " & Name & " (expected Script_Error)");
      Free_Expression (Expr);
   exception
      when SData_Core.Script_Error =>
         Passed := Passed + 1;
   end Rejects;

begin
   Put_Line ("=== Parse_Expression_Tests ===");

   --  One example per Expression_Kind
   Parses_To ("123",        Expr_Numeric_Literal, "Integer literal 123");
   Parses_To ("12.5",       Expr_Numeric_Literal, "Float literal 12.5");
   Parses_To ("""hello""",  Expr_String_Literal,  "String literal");
   Parses_To ("X",          Expr_Variable,        "Variable X");
   Parses_To ("A + B",      Expr_Binary_Op,       "Binary op A + B");
   Parses_To ("-X",         Expr_Unary_Op,        "Unary -X");
   Parses_To ("SQRT(4)",    Expr_Function_Call,   "Function call SQRT(4)");
   Parses_To ("SUM(1, 2, 3)", Expr_Function_Call, "Function call SUM with 3 args");
   Parses_To (".",          Expr_Missing,         "Missing literal");

   --  Composites and operator coverage (top-level should still parse to
   --  Binary_Op / Unary_Op as appropriate)
   Parses_To ("(A)",        Expr_Variable,        "Parenthesised variable");
   Parses_To ("(A + B)",    Expr_Binary_Op,       "Parenthesised binary op");
   Parses_To ("A * B + C",  Expr_Binary_Op,       "Precedence: A*B+C");
   Parses_To ("A AND B",    Expr_Binary_Op,       "Logical AND");
   Parses_To ("A OR B",     Expr_Binary_Op,       "Logical OR");
   Parses_To ("A < B",      Expr_Binary_Op,       "Comparison <");
   Parses_To ("A = B",      Expr_Binary_Op,       "Equality =");
   Parses_To ("A >= B",     Expr_Binary_Op,       "Comparison >=");
   Parses_To ("NOT A",      Expr_Unary_Op,        "Unary NOT");
   Parses_To ("A ** 2",     Expr_Binary_Op,       "Exponentiation");
   Parses_To ("SQRT(A*A + B*B)", Expr_Function_Call, "Nested function call");

   --  Malformed input must raise Script_Error
   Rejects ("(",            "Unclosed paren");
   Rejects ("A +",          "Trailing operator");
   Rejects ("A + (",        "Open paren after operator");
   Rejects ("",             "Empty input");

   --  Summary
   New_Line;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Parse_Expression_Tests;
