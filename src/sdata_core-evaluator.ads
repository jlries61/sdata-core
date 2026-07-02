--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Evaluator implements the Expression Evaluation Engine.
--  It takes AST expression nodes and returns computed 'Value' records,
--  interacting with SData_Core.Variables for symbol lookups.
--
--  This package also owns all expression-type definitions (Expression_Kind,
--  Expression, Expression_Access, Expression_List, and Free_Expression) that
--  were previously part of SData.AST.  Placing them here removes the
--  circular dependency between the evaluator and the AST package: the AST
--  package (SData.AST) now withs this package to obtain Expression_Access
--  for statement fields, while this package no longer needs to with SData.AST.

with SData_Core.Values; use SData_Core.Values;
with Ada.Strings.Unbounded;
private with Ada.Containers.Vectors;
private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Strings.Hash;

package SData_Core.Evaluator is

   ---------------------------------------------------------------------------
   --  Expression types (moved from SData.AST)
   ---------------------------------------------------------------------------

   --  Kinds of expressions supported in the language.
   type Expression_Kind is (
      Expr_Numeric_Literal, -- e.g., 123.45
      Expr_String_Literal,  -- e.g., "Hello"
      Expr_Variable,        -- e.g., SALARY
      Expr_Binary_Op,       -- e.g., A + B
      Expr_Unary_Op,        -- e.g., -A
      Expr_Function_Call,   -- e.g., SQRT(X)
      Expr_Array_Access,    -- e.g., ARR{1}
      Expr_Missing          -- '.' literal: evaluates to Val_Missing
   );

   --  Arithmetic and logical binary operators.
   type Binary_Op is (Op_Add, Op_Sub, Op_Mul, Op_Div, Op_Pow, Op_Eq, Op_Ne, Op_Lt, Op_Le, Op_Gt, Op_Ge, Op_And, Op_Or, Op_Xor);

   --  Unary operators.
   type Unary_Op is (Op_Neg, Op_Not);

   type Expression;
   type Expression_Access is access Expression;

   --  Linked list structure for function arguments.
   type Expression_List_Node;
   type Expression_List is access Expression_List_Node;
   type Expression_List_Node is record
      Expr     : Expression_Access;
      Is_Range : Boolean := False;    -- True for colon range lo:hi
      Expr_End : Expression_Access := null; -- hi part of the range
      Next     : Expression_List := null;
   end record;

   --  Variant record for all expression types.
   type Expression (Kind : Expression_Kind) is record
      case Kind is
         when Expr_Numeric_Literal =>
            Value      : Float;
            Is_Integer : Boolean := False;
            Int_Value  : Integer := 0;
         when Expr_String_Literal =>
            Str_Value : Ada.Strings.Unbounded.Unbounded_String;
         when Expr_Variable =>
            Var_Name  : String (1 .. Max_Name_Len);
            Var_Len   : Natural;
            Var_Index : Natural := 0;  -- 0 = unresolved; positive = 1-based PDV_Vec slot
         when Expr_Binary_Op =>
            Left  : Expression_Access;
            Right : Expression_Access;
            Op    : Binary_Op;
         when Expr_Unary_Op =>
            Operand : Expression_Access;
            UOp     : Unary_Op;
         when Expr_Function_Call =>
            Func_Name : String (1 .. Max_Name_Len);
            Func_Len  : Natural;
            Arguments : Expression_List;
         when Expr_Array_Access =>
            Arr_Name : String (1 .. Max_Name_Len);
            Arr_Len  : Natural;
            Arr_Idx  : Expression_List; -- Supports multiple subscripts: X(1, 3, 5)
         when Expr_Missing =>
            null;
      end case;
   end record;

   --  Frees a single expression tree.
   procedure Free_Expression (Expr : in out Expression_Access);

   ---------------------------------------------------------------------------
   --  Evaluator public interface
   ---------------------------------------------------------------------------

   --  Computes the value of an AST expression.
   function Evaluate (Expr : Expression_Access) return Value;

   --  Converts any numeric value kind to Float for calculation.
   function Convert_To_Float (V : Value) return Float;

   --  Returns the expected kind of value based on name suffix
   function Get_Expected_Kind (Name : String) return Value_Kind;

   --  Statically infer the result kind of an expression WITHOUT evaluating it.
   --  Uses name suffixes (via Get_Expected_Kind), literal kinds, and operator
   --  propagation only.  Returns Val_Missing when the kind cannot be determined
   --  statically (mixed-kind operands, '.' literal, dynamic constructs) -- the
   --  caller must treat Val_Missing as "defer, do not reject".
   function Static_Result_Kind (Expr : Expression_Access) return Value_Kind;

   --  Returns True for functions whose first argument is passed as a variable
   --  *name* rather than the variable's evaluated value (LAG, NEXT, OBS and
   --  their character variants).  Used by the parser, evaluator, and any code
   --  that walks the expression AST.
   function Is_Identifier_Ref_Function (N : String) return Boolean;

   --  Set_Group_Boundary — update the BOG/EOG indicators before each record.
   --
   --  Caller: SData.Interpreter.Process_One_Record, called exactly once per
   --  record at the start of the deferred program body, after Group_Flags
   --  determines the boundary values from the physical row sequence and the
   --  active BY-variable list.
   --
   --  Both flags are set atomically; the evaluator makes no assertion about
   --  their values.  The BOG() and EOG() expression functions read these flags
   --  during Evaluate; behaviour is undefined if they are read before the first
   --  call in a data step.
   procedure Set_Group_Boundary (BOG, EOG : Boolean);

   --  Thin shim for unit tests: call a registered function by name with
   --  pre-evaluated arguments.  Raises SData_Core.Script_Error if Name is not in
   --  the dispatch table.
   type Value_Array is array (Positive range <>) of Value;
   function Call_Function (Name : String; Args : Value_Array) return Value;

   --  Aggregate-function metadata.  AGGREGATE (SData_Core.Commands) consults
   --  this side-table to (a) recognise a name as a registered aggregate and
   --  (b) type-check its input column before computing.  The actual per-group
   --  computation is done via Call_Function above, so this record deliberately
   --  carries only the accepted input-type flags — no handler access — and
   --  leaks none of the private dispatch types.  See ADR-046.
   type Aggregate_Metadata is record
      Accepts_Numeric   : Boolean;
      Accepts_Character : Boolean;
   end record;

   --  True iff Name (case-insensitive) is a registered evaluator function.
   --  Used by consumers' static analyzers to reject unknown function calls.
   function Is_Known_Function (Name : String) return Boolean;

   --  Per-function argument-count metadata.  A call with fewer than Min_Args
   --  or more than Max_Args arguments is out of range.  Max_Args = Natural'Last
   --  means "no upper bound" (variadic).  These bounds are deliberately SOUND,
   --  not COMPLETE: where a handler accepts an open-ended or ambiguous count
   --  the upper bound is left at Natural'Last so a valid call is never rejected.
   type Arity_Spec is record
      Min_Args : Natural := 0;
      Max_Args : Natural := Natural'Last;
   end record;

   --  Returns the arity of a known function.  Raises SData_Core.Script_Error
   --  when Name is not a registered function -- call Is_Known_Function first.
   function Function_Arity (Name : String) return Arity_Spec;

   --  Register a function's arity.  Called by each handler family's private
   --  Register procedure alongside the Dispatch_Table insert.  Name is stored
   --  case-insensitively (upper-cased), matching Dispatch_Table's keys.
   procedure Register_Arity (Name : String; Min_Args, Max_Args : Natural);

   --  True iff Name (case-insensitive) is a registered aggregate function.
   --  This is the aggregate allow-list AGGREGATE uses to reject non-aggregate
   --  functions (SQRT, LEN$, …) at parse time.
   function Is_Aggregate (Name : String) return Boolean;

   --  Returns the metadata for a registered aggregate.  Raises
   --  SData_Core.Script_Error with
   --    "AGGREGATE: '<name>' is not a registered aggregate function"
   --  when Name is not a registered aggregate.
   function Lookup (Name : String) return Aggregate_Metadata;

   --  Parse an expression from a plain string.  Used by application parsers
   --  (data-vandal) that do not embed sdata's full lexer.  Raises
   --  SData_Core.Script_Error with a descriptive message on syntax error.
   function Parse_Expression (Text : String) return Expression_Access;

private

   --  Type infrastructure shared by the parent body and all private child
   --  packages that implement handler families.

   package Value_Vectors is new Ada.Containers.Vectors
      (Index_Type   => Positive,
       Element_Type => Value,
       "="          => SData_Core.Values."=");

   use type Ada.Containers.Count_Type;

   type Fn_Handler is access function
      (Name : String; Vals : Value_Vectors.Vector) return Value;

   package Fn_Maps is new Ada.Containers.Indefinite_Hashed_Maps
      (Key_Type        => String,
       Element_Type    => Fn_Handler,
       Hash            => Ada.Strings.Hash,
       Equivalent_Keys => "=");

   --  Global dispatch table — populated during elaboration by each handler
   --  family's private child package.
   Dispatch_Table : Fn_Maps.Map;

   --  Aggregate-only metadata side-table — populated during elaboration by
   --  SData_Core.Evaluator.Aggregate_Fns.Register alongside the aggregate
   --  entries it adds to Dispatch_Table.  Keyed by upper-cased function name.
   package Aggregate_Meta_Maps is new Ada.Containers.Indefinite_Hashed_Maps
      (Key_Type        => String,
       Element_Type    => Aggregate_Metadata,
       Hash            => Ada.Strings.Hash,
       Equivalent_Keys => "=");
   Aggregate_Meta_Table : Aggregate_Meta_Maps.Map;

   --  Per-function arity side-table -- populated during elaboration by each
   --  handler family's Register procedure alongside its Dispatch_Table inserts.
   --  Keyed by upper-cased function name.  Read by Function_Arity.
   package Arity_Maps is new Ada.Containers.Indefinite_Hashed_Maps
      (Key_Type        => String,
       Element_Type    => Arity_Spec,
       Hash            => Ada.Strings.Hash,
       Equivalent_Keys => "=");
   Arity_Table : Arity_Maps.Map;

   --  Helpers used by every handler family.
   function Has_Args (Vals : Value_Vectors.Vector; N : Positive) return Boolean;
   function Num_Result (V : Float) return Value;
   function Handle_Domain_Error (Msg : String) return Value;
   function Numeric_Result_Checked (V : Float) return Value;

end SData_Core.Evaluator;
