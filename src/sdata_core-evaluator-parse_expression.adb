--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

separate (SData_Core.Evaluator)
---------------------------------------------------------------------------
--  Parse_Expression — string-based expression parser (internal mini-lexer)
--
--  Mirrors the Pratt (precedence-climbing) algorithm used in sdata-parser.adb.
--  Produces identical Expression trees for the same expression text.
--  Raises SData_Core.Script_Error on any syntax error.
---------------------------------------------------------------------------

function Parse_Expression (Text : String) return Expression_Access is

   --  Internal token kinds.
   --  Note: MOD is a function (MOD(x,y)) in SData, not an infix keyword.
   --  It is lexed as TK_Identifier and handled as a function call.
   type Mini_Token_Kind is (
      TK_Identifier,
      TK_Integer,
      TK_Float,
      TK_String,
      TK_Plus, TK_Minus, TK_Star, TK_Slash, TK_Power,
      TK_Lt, TK_Gt, TK_Eq, TK_Le, TK_Ge, TK_Ne,
      TK_LParen, TK_RParen, TK_Comma,
      TK_And, TK_Or, TK_Not, TK_Xor,
      TK_True, TK_False, TK_Dot,
      TK_Infinity, TK_NaN,
      TK_EOF);

   Max_Tok : constant := 512;

   type Mini_Token is record
      Kind     : Mini_Token_Kind := TK_EOF;
      Text     : String (1 .. Max_Tok) := (others => ' ');
      Text_Len : Natural := 0;
      Int_Val  : Int         := 0;
      Flt_Val  : Long_Float  := 0.0;
   end record;

   Pos     : Natural  := Text'First;
   Current : Mini_Token;

   --  Forward declarations for mutual recursion.
   --  Parse_Or is the top-level entry point; Parse_Primary calls it for
   --  parenthesised sub-expressions and function arguments.
   function Parse_Or          return Expression_Access;
   function Parse_Primary     return Expression_Access;

   --  Advance: scan the next token from Text starting at Pos, store in Current.
   procedure Advance is
      C       : Character;
      Tok_Len : Natural;
   begin
      --  Skip whitespace.
      while Pos <= Text'Last and then
            (Text (Pos) = ' ' or else Text (Pos) = ASCII.HT) loop
         Pos := Pos + 1;
      end loop;

      if Pos > Text'Last then
         Current := (Kind => TK_EOF, others => <>);
         return;
      end if;

      C := Text (Pos);

      --  Identifiers / keywords.
      if Is_Letter (C) or else C = '_' then
         Tok_Len := 0;
         while Pos <= Text'Last and then
               (Is_Alphanumeric (Text (Pos)) or else Text (Pos) = '_') loop
            Tok_Len := Tok_Len + 1;
            if Tok_Len <= Max_Tok then
               Current.Text (Tok_Len) := Text (Pos);
            end if;
            Pos := Pos + 1;
         end loop;
         --  A trailing '$' (character) or '%' (integer) type suffix is
         --  part of the identifier itself -- SData column names carry it
         --  (e.g. REGION$) and Get_Expected_Kind / Variables.Get both key
         --  off the suffixed name.  Consuming it here (rather than
         --  erroring, as before #73's real fix) lets SELECT/condition
         --  filters reference typed columns.  Keywords never carry a
         --  suffix, so this can't misclassify AND/OR/etc. below.
         if Pos <= Text'Last
           and then (Text (Pos) = '$' or else Text (Pos) = '%')
         then
            Tok_Len := Tok_Len + 1;
            if Tok_Len <= Max_Tok then
               Current.Text (Tok_Len) := Text (Pos);
            end if;
            Pos := Pos + 1;
         end if;
         Current.Text_Len := Tok_Len;
         declare
            UC : constant String := To_Upper (Current.Text (1 .. Tok_Len));
         begin
            if    UC = "AND"   then Current.Kind := TK_And;
            elsif UC = "OR"    then Current.Kind := TK_Or;
            elsif UC = "NOT"   then Current.Kind := TK_Not;
            elsif UC = "XOR"   then Current.Kind := TK_Xor;
            elsif UC = "TRUE"  then Current.Kind := TK_True;
            elsif UC = "FALSE" then Current.Kind := TK_False;
            else  Current.Kind := TK_Identifier;
            end if;
         end;
         return;
      end if;

      --  String literals: Ada-style "..." with "" as escaped quote.
      if C = '"' then
         Tok_Len := 0;
         Pos := Pos + 1; -- consume opening quote
         while Pos <= Text'Last loop
            if Text (Pos) = '"' then
               if Pos + 1 <= Text'Last and then Text (Pos + 1) = '"' then
                  --  Escaped double-quote.
                  Tok_Len := Tok_Len + 1;
                  if Tok_Len <= Max_Tok then
                     Current.Text (Tok_Len) := '"';
                  end if;
                  Pos := Pos + 2;
               else
                  --  Closing quote.
                  Pos := Pos + 1;
                  exit;
               end if;
            else
               Tok_Len := Tok_Len + 1;
               if Tok_Len <= Max_Tok then
                  Current.Text (Tok_Len) := Text (Pos);
               end if;
               Pos := Pos + 1;
            end if;
         end loop;
         Current.Kind     := TK_String;
         Current.Text_Len := Tok_Len;
         return;
      end if;

      --  Numeric literals (integer or float, including leading-dot .05).
      if Is_Digit (C) or else (C = '.' and then Pos + 1 <= Text'Last and then Is_Digit (Text (Pos + 1))) then
         Tok_Len := 0;
         declare
            Has_Dot : Boolean := False;
            Has_Exp : Boolean := False;
         begin
            while Pos <= Text'Last loop
               declare D : constant Character := Text (Pos); begin
                  if Is_Digit (D) then
                     Tok_Len := Tok_Len + 1;
                     if Tok_Len <= Max_Tok then Current.Text (Tok_Len) := D; end if;
                     Pos := Pos + 1;
                  elsif D = '.' and then not Has_Dot and then not Has_Exp then
                     Has_Dot := True;
                     Tok_Len := Tok_Len + 1;
                     if Tok_Len <= Max_Tok then Current.Text (Tok_Len) := D; end if;
                     Pos := Pos + 1;
                  elsif (D = 'E' or else D = 'e') and then not Has_Exp then
                     Has_Exp := True;
                     Has_Dot := True; -- treat as float
                     Tok_Len := Tok_Len + 1;
                     if Tok_Len <= Max_Tok then Current.Text (Tok_Len) := D; end if;
                     Pos := Pos + 1;
                     --  Optional sign after E.
                     if Pos <= Text'Last and then
                        (Text (Pos) = '+' or else Text (Pos) = '-')
                     then
                        Tok_Len := Tok_Len + 1;
                        if Tok_Len <= Max_Tok then Current.Text (Tok_Len) := Text (Pos); end if;
                        Pos := Pos + 1;
                     end if;
                  else
                     exit;
                  end if;
               end;
            end loop;
            Current.Text_Len := Tok_Len;
            declare
               Raw : constant String := Current.Text (1 .. Tok_Len);
            begin
               if Has_Dot then
                  Current.Kind    := TK_Float;
                  Current.Flt_Val := Long_Float'Value (Raw);
               else
                  Current.Kind    := TK_Integer;
                  begin
                     Current.Int_Val := Int'Value (Raw);
                  exception
                     when Constraint_Error =>
                        --  Too large for Integer; demote to float.
                        Current.Kind    := TK_Float;
                        Current.Flt_Val := Long_Float'Value (Raw);
                  end;
               end if;
            end;
         end;
         return;
      end if;

      --  Typed literals for IEEE 754 Infinity/NaN: .i / .n (either case),
      --  disambiguated from the leading-dot decimal literal above (which
      --  already claimed '.' followed by a digit) and from the bare '.'
      --  (Val_Missing, TK_Dot below) by requiring a word boundary right
      --  after the single 'i'/'n' letter -- so .info still lexes as
      --  [TK_Dot]["info" identifier], unchanged (issue #71).
      if C = '.' and then Pos + 1 <= Text'Last
        and then (Text (Pos + 1) = 'i' or else Text (Pos + 1) = 'I'
                  or else Text (Pos + 1) = 'n' or else Text (Pos + 1) = 'N')
        and then (Pos + 2 > Text'Last
                  or else not (Is_Alphanumeric (Text (Pos + 2))
                               or else Text (Pos + 2) = '_'
                               or else Text (Pos + 2) = '$'
                               or else Text (Pos + 2) = '%'))
      then
         Current.Kind :=
           (if Text (Pos + 1) = 'i' or else Text (Pos + 1) = 'I'
            then TK_Infinity else TK_NaN);
         Pos := Pos + 2;
         return;
      end if;

      --  Single/double-character operators.
      case C is
         when '+' => Current.Kind := TK_Plus;  Pos := Pos + 1;
         when '-' => Current.Kind := TK_Minus; Pos := Pos + 1;
         when ',' => Current.Kind := TK_Comma; Pos := Pos + 1;
         when '(' => Current.Kind := TK_LParen; Pos := Pos + 1;
         when ')' => Current.Kind := TK_RParen; Pos := Pos + 1;
         when '.' => Current.Kind := TK_Dot;   Pos := Pos + 1;
         when '*' =>
            if Pos + 1 <= Text'Last and then Text (Pos + 1) = '*' then
               Current.Kind := TK_Power; Pos := Pos + 2;
            else
               Current.Kind := TK_Star; Pos := Pos + 1;
            end if;
         when '^' => Current.Kind := TK_Power; Pos := Pos + 1;
         when '/' => Current.Kind := TK_Slash; Pos := Pos + 1;
         when '=' => Current.Kind := TK_Eq;    Pos := Pos + 1;
         when '<' =>
            if Pos + 1 <= Text'Last and then Text (Pos + 1) = '=' then
               Current.Kind := TK_Le; Pos := Pos + 2;
            elsif Pos + 1 <= Text'Last and then Text (Pos + 1) = '>' then
               Current.Kind := TK_Ne; Pos := Pos + 2;
            else
               Current.Kind := TK_Lt; Pos := Pos + 1;
            end if;
         when '>' =>
            if Pos + 1 <= Text'Last and then Text (Pos + 1) = '=' then
               Current.Kind := TK_Ge; Pos := Pos + 2;
            else
               Current.Kind := TK_Gt; Pos := Pos + 1;
            end if;
         when others =>
            raise SData_Core.Script_Error
              with "Parse_Expression: unexpected character '" & C & "'";
      end case;
      --  Clear text for non-identifier tokens.
      Current.Text_Len := 0;
   end Advance;

   procedure Expect (K : Mini_Token_Kind) is
   begin
      if Current.Kind /= K then
         raise SData_Core.Script_Error
           with "Parse_Expression: expected " & K'Image &
                " but got " & Current.Kind'Image;
      end if;
      Advance;
   end Expect;

   --  Precedence table mirrors Get_Precedence in sdata-parser.adb.
   function Get_Prec (K : Mini_Token_Kind) return Integer is
   begin
      case K is
         when TK_Or  | TK_Xor        => return 5;
         when TK_And                  => return 6;
         when TK_Eq | TK_Ne | TK_Lt |
              TK_Le | TK_Gt | TK_Ge  => return 10;
         when TK_Plus  | TK_Minus     => return 20;
         when TK_Star  | TK_Slash     => return 30;
         when TK_Power                => return 40;
         when others                  => return 0;
      end case;
   end Get_Prec;

   function To_Bin_Op (K : Mini_Token_Kind) return Binary_Op is
   begin
      case K is
         when TK_Plus  => return Op_Add;
         when TK_Minus => return Op_Sub;
         when TK_Star  => return Op_Mul;
         when TK_Slash => return Op_Div;
         when TK_Power => return Op_Pow;
         when TK_Eq    => return Op_Eq;
         when TK_Ne    => return Op_Ne;
         when TK_Lt    => return Op_Lt;
         when TK_Le    => return Op_Le;
         when TK_Gt    => return Op_Gt;
         when TK_Ge    => return Op_Ge;
         when TK_And   => return Op_And;
         when TK_Or    => return Op_Or;
         when TK_Xor   => return Op_Xor;
         when others   => raise Program_Error with "To_Bin_Op: not an operator";
      end case;
   end To_Bin_Op;

   --  Parse_Expr_1: Pratt precedence-climbing, identical to sdata-parser's
   --  Parse_Expression_1.
   function Parse_Expr_1 (Min_Prec : Integer) return Expression_Access is
      Left : Expression_Access := Parse_Primary;
   begin
      if Left = null then return null; end if;
      loop
         declare
            Prec : constant Integer := Get_Prec (Current.Kind);
         begin
            exit when Prec < Min_Prec;
            declare
               Op_Kind  : constant Mini_Token_Kind := Current.Kind;
               New_Node : Expression_Access;
               Right    : Expression_Access;
            begin
               Advance; -- consume operator
               Right := Parse_Expr_1 (Prec + 1);
               if Right = null then
                  raise SData_Core.Script_Error
                    with "Parse_Expression: expected operand after operator";
               end if;
               New_Node := new Expression (Expr_Binary_Op);
               New_Node.Left  := Left;
               New_Node.Right := Right;
               New_Node.Op    := To_Bin_Op (Op_Kind);
               Left := New_Node;
            end;
         end;
      end loop;
      return Left;
   end Parse_Expr_1;

   function Parse_Primary return Expression_Access is
      Node : Expression_Access;
   begin
      case Current.Kind is
         when TK_Integer =>
            Node := new Expression (Expr_Numeric_Literal);
            Node.Value      := Real (Current.Int_Val);
            Node.Is_Integer := True;
            Node.Int_Value  := Current.Int_Val;
            Advance;
            return Node;

         when TK_Float =>
            Node := new Expression (Expr_Numeric_Literal);
            Node.Value      := Real (Current.Flt_Val);
            Node.Is_Integer := False;
            Advance;
            return Node;

         when TK_String =>
            Node := new Expression (Expr_String_Literal);
            Node.Str_Value :=
               Ada.Strings.Unbounded.To_Unbounded_String
                  (Current.Text (1 .. Current.Text_Len));
            Advance;
            return Node;

         when TK_Dot =>
            Advance;
            return new Expression (Expr_Missing);

         when TK_Infinity =>
            Advance;
            Node := new Expression (Expr_Numeric_Literal);
            Node.Value      := Pos_Inf;
            Node.Is_Integer := False;
            return Node;

         when TK_NaN =>
            Advance;
            Node := new Expression (Expr_Numeric_Literal);
            Node.Value      := NaN_Val;
            Node.Is_Integer := False;
            return Node;

         when TK_True | TK_False =>
            --  TRUE/FALSE are zero-arg functions.  Represent as Expr_Variable
            --  so Evaluate falls through to Evaluate_Function(VName, null).
            Node := new Expression (Expr_Variable);
            declare
               UC : constant String :=
                  (if Current.Kind = TK_True then "TRUE" else "FALSE");
            begin
               Node.Var_Len                := UC'Length;
               Node.Var_Name (1 .. UC'Length) := UC;
            end;
            Advance;
            return Node;

         when TK_Minus =>
            Advance;
            Node := new Expression (Expr_Unary_Op);
            Node.UOp     := Op_Neg;
            Node.Operand := Parse_Primary;
            return Node;

         when TK_Not =>
            Advance;
            Node := new Expression (Expr_Unary_Op);
            Node.UOp     := Op_Not;
            Node.Operand := Parse_Primary;
            return Node;

         when TK_LParen =>
            Advance; -- consume '('
            Node := Parse_Or;
            Expect (TK_RParen);
            return Node;

         when TK_Identifier =>
            declare
               Name_Len : constant Natural := Current.Text_Len;
               Name_Buf : constant String  := Current.Text (1 .. Name_Len);
               UC_Name  : constant String  := To_Upper (Name_Buf);
            begin
               Advance;
               if Current.Kind = TK_LParen then
                  --  Function call (or subscript — we always use Expr_Function_Call
                  --  here since we have no runtime array table available).
                  Advance; -- consume '('
                  --  Collect argument list.
                  declare
                     Head : Expression_List := null;
                     Last : Expression_List := null;
                  begin
                     if Current.Kind /= TK_RParen then
                        loop
                           declare
                              Arg  : constant Expression_Access := Parse_Or;
                              Node_L : constant Expression_List :=
                                 new Expression_List_Node'
                                    (Expr     => Arg,
                                     Is_Range => False,
                                     Expr_End => null,
                                     Next     => null);
                           begin
                              if Head = null then
                                 Head := Node_L;
                              else
                                 Last.Next := Node_L;
                              end if;
                              Last := Node_L;
                           end;
                           exit when Current.Kind /= TK_Comma;
                           Advance; -- consume ','
                        end loop;
                     end if;
                     Expect (TK_RParen);
                     Node := new Expression (Expr_Function_Call);
                     Node.Func_Len := Natural'Min (Name_Len, Max_Name_Len);
                     Node.Func_Name (1 .. Node.Func_Len) :=
                        UC_Name (UC_Name'First .. UC_Name'First + Node.Func_Len - 1);
                     Node.Arguments := Head;
                     return Node;
                  end;
               else
                  Node := new Expression (Expr_Variable);
                  Node.Var_Len := Natural'Min (Name_Len, Max_Name_Len);
                  Node.Var_Name (1 .. Node.Var_Len) :=
                     UC_Name (UC_Name'First .. UC_Name'First + Node.Var_Len - 1);
                  return Node;
               end if;
            end;

         when TK_EOF =>
            raise SData_Core.Script_Error
              with "Parse_Expression: unexpected end of expression";

         when others =>
            raise SData_Core.Script_Error
              with "Parse_Expression: unexpected token " & Current.Kind'Image;
      end case;
   end Parse_Primary;

   --  Parse_Or is the top-level entry that kicks off precedence-climbing at
   --  the lowest level (min_prec = 1, capturing OR/XOR and everything above).
   function Parse_Or return Expression_Access is
   begin
      return Parse_Expr_1 (1);
   end Parse_Or;

begin
   Advance; -- prime Current
   declare
      Result : constant Expression_Access := Parse_Or;
   begin
      if Current.Kind /= TK_EOF then
         raise SData_Core.Script_Error
           with "Parse_Expression: unexpected token after expression: " &
                Current.Kind'Image &
                (if Current.Text_Len > 0
                 then " '" & Current.Text (1 .. Current.Text_Len) & "'"
                 else "");
      end if;
      return Result;
   end;
end Parse_Expression;
