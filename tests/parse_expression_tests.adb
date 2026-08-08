--  Exercises SData_Core.Evaluator.Parse_Expression: round-trip
--  parse -> Free_Expression for one example of each Expression_Kind
--  plus a few composites, plus malformed strings that must raise
--  SData_Core.Script_Error.
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;          use Ada.Text_IO;
with Ada.Exceptions;
with SData_Core;
with SData_Core.Evaluator; use SData_Core.Evaluator;
with SData_Core.Values;    use SData_Core.Values;
with Test_Support;         use Test_Support;

procedure Parse_Expression_Tests is

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
         Assert (False, Name & " raised "
                 & Ada.Exceptions.Exception_Name (E));
   end Parses_To;

   --  Parses Text, evaluates it, and checks the result against Check
   --  (issue #71: .i/.n must not just parse to Expr_Numeric_Literal but
   --  actually construct the right IEEE 754 special value).
   procedure Evaluates_To (Text  : String;
                           Check : not null access function (V : Value)
                                                              return Boolean;
                           Name  : String) is
      Expr   : Expression_Access;
      Result : Value;
   begin
      Expr   := Parse_Expression (Text);
      Result := Evaluate (Expr);
      Assert (Check (Result), Name);
      Free_Expression (Expr);
   exception
      when E : others =>
         Assert (False, Name & " raised "
                 & Ada.Exceptions.Exception_Name (E));
   end Evaluates_To;

   function Is_Pos_Inf (V : Value) return Boolean is
     (V.Kind = Val_Numeric and then Is_Inf (V.Num_Val) and then V.Num_Val > 0.0);
   function Is_Neg_Inf (V : Value) return Boolean is
     (V.Kind = Val_Numeric and then Is_Inf (V.Num_Val) and then V.Num_Val < 0.0);
   function Is_A_NaN (V : Value) return Boolean is
     (V.Kind = Val_Numeric and then Is_NaN (V.Num_Val));

   procedure Rejects (Text : String; Name : String) is
      Expr : Expression_Access;
   begin
      Expr := Parse_Expression (Text);
      --  No exception: the parse should have rejected the input.
      Assert (False, Name & " (expected Script_Error)");
      Free_Expression (Expr);
   exception
      when SData_Core.Script_Error =>
         Assert (True, Name);
   end Rejects;

   --  Like Rejects, but the error is expected at evaluation time, not
   --  parse time (e.g. NaN's Numeric_Result_Checked domain-error guard,
   --  which a syntactically valid expression only trips when Evaluated).
   procedure Rejects_On_Evaluate (Text : String; Name : String) is
      Expr   : Expression_Access;
      Result : Value;
      pragma Unreferenced (Result);
   begin
      Expr   := Parse_Expression (Text);
      Result := Evaluate (Expr);
      Assert (False, Name & " (expected Script_Error on Evaluate)");
      Free_Expression (Expr);
   exception
      when SData_Core.Script_Error =>
         Assert (True, Name);
   end Rejects_On_Evaluate;

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

   --  Typed IEEE 754 Infinity/NaN literals (issue #71): .i / -.i / .n,
   --  either case, disambiguated from bare "." and from leading-dot
   --  decimals like ".5".
   Parses_To (".i",  Expr_Numeric_Literal, "Infinity literal .i");
   Parses_To (".I",  Expr_Numeric_Literal, "Infinity literal .I (uppercase)");
   Parses_To (".n",  Expr_Numeric_Literal, "NaN literal .n");
   Parses_To (".N",  Expr_Numeric_Literal, "NaN literal .N (uppercase)");
   Parses_To ("-.i", Expr_Unary_Op,        "Negative infinity literal -.i");
   Parses_To (".5",  Expr_Numeric_Literal, "Leading-dot decimal .5 unaffected");

   Evaluates_To (".i",  Is_Pos_Inf'Access, "Evaluates .i to +Infinity");
   Evaluates_To ("-.i", Is_Neg_Inf'Access, "Evaluates -.i to -Infinity");
   Evaluates_To (".n",  Is_A_NaN'Access,   "Evaluates .n to NaN");
   Evaluates_To ("-.n", Is_A_NaN'Access,   "Evaluates -.n to (still) NaN");

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
   Parses_To ("A ** 2",     Expr_Binary_Op,       "Exponentiation (**)");
   Parses_To ("A ^ 2",      Expr_Binary_Op,       "Exponentiation (^)");
   Parses_To ("SQRT(A*A + B*B)", Expr_Function_Call, "Nested function call");

   --  Malformed input must raise Script_Error
   Rejects ("(",            "Unclosed paren");
   Rejects ("A +",          "Trailing operator");
   Rejects ("A + (",        "Open paren after operator");
   Rejects ("",             "Empty input");

   --  .n constructs NaN, but ADR-057 keeps NaN from surviving arithmetic:
   --  the existing Numeric_Result_Checked guard (already tripped by 0/0)
   --  must still trip here, proving the .n literal doesn't weaken it.
   Rejects_On_Evaluate (".n + 1", "Arithmetic on .n still raises the NaN guard");
   Rejects_On_Evaluate (".n * 2", ".n * 2 still raises the NaN guard");

   --  .info must still lex/parse exactly as it did before issue #71: a
   --  bare Missing ('.') immediately followed by a separate "info"
   --  identifier token, which is a syntax error (two adjacent primaries,
   --  same as it always was) -- not an Infinity/NaN literal.
   Rejects (".info",        ".info is unchanged (Missing, then stray ident)");

   Report_And_Exit;
end Parse_Expression_Tests;
