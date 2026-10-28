--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with SData_Core.Variables; use SData_Core.Variables;
with SData_Core.Config;
with SData_Core.Config.Runtime;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with SData_Core.Real_Functions; use SData_Core.Real_Functions;
with SData_Core.IO;        use SData_Core.IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces;
with Ada.Numerics;
with Ada.Exceptions;
with Ada.Strings.Fixed;
use type Interfaces.Integer_64;
--  The six child packages below are withed solely for their elaboration side
--  effects: each body's "begin Register;" block calls Dispatch_Table.Insert to
--  self-register its handlers.  No exported entity is referenced by name here,
--  so pragma Warnings (Off, ...) suppresses the "package not referenced" diagnostic.
--
--  Why this pattern rather than explicit Register calls in this body?
--  Dispatch_Table lives in the parent spec's private part, which is visible to
--  private child bodies but not to the parent body itself via child-package names.
--  Calling child-package procedures from the parent body would require the parent
--  to depend on the children at compile time, creating a circular unit dependency
--  (children already depend on the parent spec).  The elaboration-side-effect
--  approach breaks the cycle: the parent body causes the children to elaborate,
--  each child writes directly into the shared private-part table, and the parent
--  body never names a child entity.
with SData_Core.Evaluator.Numeric_Fns;    pragma Warnings (Off, SData_Core.Evaluator.Numeric_Fns);
with SData_Core.Evaluator.Aggregate_Fns;  pragma Warnings (Off, SData_Core.Evaluator.Aggregate_Fns);
with SData_Core.Evaluator.String_Fns;     pragma Warnings (Off, SData_Core.Evaluator.String_Fns);
with SData_Core.Evaluator.Nav_Fns;        pragma Warnings (Off, SData_Core.Evaluator.Nav_Fns);
with SData_Core.Evaluator.Distrib_Fns;    pragma Warnings (Off, SData_Core.Evaluator.Distrib_Fns);
with SData_Core.Evaluator.Misc_Fns;       pragma Warnings (Off, SData_Core.Evaluator.Misc_Fns);

--  SData_Core.Evaluator — expression evaluator and built-in function dispatcher.
--
--  Entry points:
--    Evaluate           evaluates an Expression node to a Value
--    Evaluate_Function  dispatches a named function call
--    Is_True            coerces a Value to a Boolean (non-zero / non-empty)
--
--  Design notes:
--    * Missing value propagation: most functions return Val_Missing when any
--      required argument is missing.  Has_Args(Vals, N) encapsulates this check.
--    * LAG, NEXT, OBS and their string variants receive their first argument
--      as a variable *name* (a string) rather than the variable's current
--      value.  Is_Identifier_Ref_Function gates this special treatment.
--    * RECNO, BOF, and EOF operate in logical (filtered-view) space when a
--      SELECT filter is active; they query Logical_Record_Index rather than
--      Current_Record_Index.
--    * LAG and NEXT likewise navigate by logical offset and then map each
--      logical position to a physical row via Logical_To_Physical, so that
--      filtered-out rows are invisible to both functions.
--    * IF(cond, true_expr, false_expr) is intercepted before argument
--      flattening so that only the selected branch is evaluated (lazy eval).
--    * All other built-in functions are dispatched through Dispatch_Table,
--      a hashed map from function name to handler subprogram.  Dispatch_Table
--      is declared in the parent spec's private part.  Each function family is
--      implemented in a private child package whose body self-registers during
--      elaboration via Dispatch_Table.Insert — no parent body call required.

package body SData_Core.Evaluator is

   ---------------------------------------------------------------------------
   --  Free_Expression — deep-free an expression tree
   ---------------------------------------------------------------------------

   procedure Free_Expr_Node is new Ada.Unchecked_Deallocation (Expression,          Expression_Access);
   procedure Free_List_Node is new Ada.Unchecked_Deallocation (Expression_List_Node, Expression_List);

   procedure Free_Expr_List (List : in out Expression_List) is
      Next : Expression_List;
   begin
      while List /= null loop
         Next := List.Next;
         Free_Expression (List.Expr);
         if List.Is_Range then
            Free_Expression (List.Expr_End);
         end if;
         Free_List_Node (List);
         List := Next;
      end loop;
   end Free_Expr_List;

   procedure Free_Expression (Expr : in out Expression_Access) is
   begin
      if Expr = null then return; end if;
      case Expr.Kind is
         when Expr_Binary_Op     => Free_Expression (Expr.Left);   Free_Expression (Expr.Right);
         when Expr_Unary_Op      => Free_Expression (Expr.Operand);
         when Expr_Function_Call => Free_Expr_List (Expr.Arguments);
         when Expr_Array_Access  => Free_Expr_List (Expr.Arr_Idx);
         when others             => null;
      end case;
      Free_Expr_Node (Expr);
   end Free_Expression;

   ---------------------------------------------------------------------------

   function Is_True (V : Value) return Boolean is
   begin
      case V.Kind is
         when Val_Integer => return V.Int_Val /= 0;
         when Val_Numeric => return V.Num_Val /= 0.0;
         when Val_String  => return Length (V.Str_Val) > 0;
         when Val_Missing => return False;
      end case;
   end Is_True;

   ---------------------------------------------------------------------------
   --  Bodies for private-spec declarations
   ---------------------------------------------------------------------------

   procedure Set_Group_Boundary (BOG, EOG : Boolean) is
   begin
      Nav_Fns.Set_Boundary (BOG, EOG);
   end Set_Group_Boundary;

   --  Invoke_Handler -- run a built-in function's handler.  A runtime check
   --  failing inside it (overflow, range, Argument_Error from the math
   --  library) is the argument being outside the function's domain; report
   --  that as a domain error naming the function, not as Ada runtime text
   --  such as "string_fns.adb:55 overflow check failed" (F04, F52).
   function Invoke_Handler
     (Cursor : Fn_Maps.Cursor;
      Name   : String;
      Vals   : Value_Vectors.Vector) return Value is
   begin
      return Fn_Maps.Element (Cursor).all (Name, Vals);
   exception
      when E : Constraint_Error | Ada.Numerics.Argument_Error | Program_Error =>
         --  A message the function wrote itself is kept; the compiler's own
         --  text is replaced.
         declare
            Msg : constant String := Ada.Exceptions.Exception_Message (E);
         begin
            if Msg'Length > 0
               and then Ada.Strings.Fixed.Index (Msg, ".adb:") = 0
               and then Ada.Strings.Fixed.Index (Msg, "bad input for") = 0
               and then Ada.Strings.Fixed.Index (Msg, "explicit raise") = 0
            then
               raise SData_Core.Script_Error with Name & ": " & Msg;
            end if;
         end;
         raise SData_Core.Script_Error with
            Name & ": argument out of range";
   end Invoke_Handler;

   function Call_Function (Name : String; Args : Value_Array) return Value is
      UC     : constant String := To_Upper (Name);
      Vals   : Value_Vectors.Vector;
      Cursor : constant Fn_Maps.Cursor := Dispatch_Table.Find (UC);
   begin
      for A of Args loop
         Vals.Append (A);
      end loop;
      if not Fn_Maps.Has_Element (Cursor) then
         raise SData_Core.Script_Error with "Call_Function: unknown function '" & Name & "'";
      end if;
      return Invoke_Handler (Cursor, UC, Vals);
   end Call_Function;

   function Is_Known_Function (Name : String) return Boolean is
   begin
      return Dispatch_Table.Contains (To_Upper (Name));
   end Is_Known_Function;

   function Is_Zero_Arg_Fallback (Name : String) return Boolean is
   begin
      return To_Upper (Name) in
        "BOF" | "EOF" | "BOG" | "EOG" | "RECNO" | "ORD" |
        "DATE$" | "TIME$" | "RAN" | "RANDOM" | "RND" | "LRN" |
        "ZRN" | "URN" | "PI" | "TIMER" |
        "ERR" | "ERL" |
        "MAXLEN" | "MAXLVL" | "MAXINT" | "MAXNUM" |
        "MININT" | "MINNUM" |
        "FALSE" | "TRUE";
   end Is_Zero_Arg_Fallback;

   procedure Register_Arity (Name : String; Min_Args, Max_Args : Natural) is
   begin
      Arity_Table.Include (To_Upper (Name), (Min_Args, Max_Args));
   end Register_Arity;

   function Function_Arity (Name : String) return Arity_Spec is
      C : constant Arity_Maps.Cursor := Arity_Table.Find (To_Upper (Name));
   begin
      if Arity_Maps.Has_Element (C) then
         return Arity_Maps.Element (C);
      else
         raise SData_Core.Script_Error
           with "no arity registered for function '" & Name & "'";
      end if;
   end Function_Arity;

   function Is_Aggregate (Name : String) return Boolean is
   begin
      return Aggregate_Meta_Table.Contains (To_Upper (Name));
   end Is_Aggregate;

   function Lookup (Name : String) return Aggregate_Metadata is
      UC : constant String := To_Upper (Name);
   begin
      if not Aggregate_Meta_Table.Contains (UC) then
         raise SData_Core.Script_Error with
           "AGGREGATE: '" & Name & "' is not a registered aggregate function";
      end if;
      return Aggregate_Meta_Table.Element (UC);
   end Lookup;

   function Convert_To_Real (V : Value) return Real is
   begin
      case V.Kind is
         when Val_Numeric => return V.Num_Val;
         when Val_Integer => return Real (V.Int_Val);
         when others      => raise Constraint_Error with "Cannot convert " & V.Kind'Image & " to Real";
      end case;
   end Convert_To_Real;

   --  Has_Args(Vals, N): returns True iff at least N arguments were supplied
   --  and none of the first N is missing.  Missing propagation is automatic
   --  for all functions that guard on Has_Args rather than inspecting each
   --  argument individually.
   function Has_Args (Vals : Value_Vectors.Vector; N : Positive) return Boolean is
   begin
      if Vals.Length < Ada.Containers.Count_Type (N) then return False; end if;
      for I in 1 .. N loop
         if Vals.Element (I).Kind = Val_Missing then return False; end if;
      end loop;
      return True;
   end Has_Args;

   function Num_Result (V : Real) return Value is
   begin
      return (Kind => Val_Numeric, Num_Val => V);
   end Num_Result;

   function Handle_Domain_Error (Msg : String) return Value is
   begin
      if SData_Core.Config.Ignore_Math_Errors then
         Put_Line_Error ("Warning: " & Msg);
         return (Kind => Val_Missing);
      else
         raise SData_Core.Script_Error with Msg;
      end if;
   end Handle_Domain_Error;

   function Is_NaN (F : Real) return Boolean is
   begin
      return F /= F;
   end Is_NaN;

   function Numeric_Result_Checked (V : Real) return Value is
   begin
      if Is_NaN (V) then
         return Handle_Domain_Error ("Result is not a number (NaN).");
      end if;
      return (Kind => Val_Numeric, Num_Val => V);
   end Numeric_Result_Checked;

   --  "**" on Real resolves to Ada.Numerics.Generic_Elementary_Functions."**"
   --  (instantiated in Real_Functions), which computes Exp (Exponent * Log
   --  (Base)) unconditionally -- undefined, and a raw Argument_Error, for a
   --  negative Base regardless of whether Exponent happens to be a whole
   --  number.  Ada's predefined "**" (Real, Integer) operator has no such
   --  restriction (it is pure repeated multiplication/division), so route
   --  whole-number exponents through it.  A genuinely fractional exponent
   --  with a negative Base has no real result -- that case is checked
   --  explicitly and reported via Handle_Domain_Error, the same
   --  friendly-message path every other domain error in this evaluator
   --  uses (see e.g. SQRT/ARCSIN/ARCCOS above), rather than letting the
   --  library's internal exception (and its GNAT source-file-and-line
   --  text) leak straight to the user.
   function Real_Pow (Base, Exponent : Real) return Value is
   begin
      if Real'Truncation (Exponent) = Exponent
        and then abs Exponent <= Real (Integer'Last)
      then
         return Numeric_Result_Checked (Base ** Integer (Exponent));
      elsif Base < 0.0 then
         return Handle_Domain_Error
           ("Fractional exponentiation of a negative base is undefined.");
      else
         return Numeric_Result_Checked (Base ** Exponent);
      end if;
   end Real_Pow;

   ---------------------------------------------------------------------------

   function Is_Identifier_Ref_Function (N : String) return Boolean is
      U : constant String := To_Upper (N);
   begin
      return U in "LAG" | "LAGC$" | "NEXT" | "NEXTC$" | "OBS" | "OBSC$"
                | "LBOUND" | "UBOUND" | "HBOUND";
   end Is_Identifier_Ref_Function;

   ---------------------------------------------------------------------------
   --  Evaluate_Function — public entry point
   --
   --  1. IF is intercepted early for lazy evaluation.
   --  2. All other arguments are flattened (with array expansion) into Vals.
   --  3. Dispatch_Table maps the function name to a handler subprogram.
   ---------------------------------------------------------------------------
   --  Evaluate_Function and Evaluate are mutually recursive: Evaluate calls
   --  Evaluate_Function for named-function AST nodes; Evaluate_Function calls
   --  Evaluate to resolve each argument.  An explicit stack would add complexity
   --  without safety benefit given the bounded expression depth in practice.
   pragma Annotate (GNATcheck, Exempt_On, "Recursive_Subprograms",
                    "Mutual recursion is necessary for AST traversal; "
                    & "expression depth is bounded by the parser");
   function Evaluate_Function (Name : String; Args : Expression_List) return Value is
      All_Vals  : Value_Vectors.Vector;
      Current   : Expression_List := Args;
      Arg_Index : Natural         := 0;
   begin
      --  IF(cond, true_expr, false_expr) requires lazy evaluation: only the
      --  selected branch is evaluated so that domain errors in the non-taken
      --  branch are never raised.  Handle it here, before the argument-
      --  flattening loop, and return immediately.
      if Name = "IF" then
         declare
            Cond_Node  : constant Expression_List := Args;
            True_Node  : constant Expression_List :=
               (if Cond_Node /= null then Cond_Node.Next else null);
            False_Node : constant Expression_List :=
               (if True_Node /= null then True_Node.Next else null);
            Cond_Val   : Value;
         begin
            if Cond_Node = null or else True_Node = null or else False_Node = null then
               return (Kind => Val_Missing);
            end if;
            Cond_Val := Evaluate (Cond_Node.Expr);
            if Cond_Val.Kind = Val_Missing then
               return (Kind => Val_Missing);
            end if;
            if Is_True (Cond_Val) then
               return Evaluate (True_Node.Expr);
            else
               return Evaluate (False_Node.Expr);
            end if;
         end;
      end if;

      --  Flatten arguments, expanding arrays where needed.
      while Current /= null loop
         Arg_Index := Arg_Index + 1;
         if Is_Identifier_Ref_Function (Name) and then Arg_Index = 1
            and then Current.Expr.Kind = Expr_Variable
         then
            --  For LAG/NEXT/OBS the first argument is the variable name, not
            --  its value.
            declare
               VName : constant String :=
                  To_Upper (Current.Expr.Var_Name (1 .. Current.Expr.Var_Len));
            begin
               All_Vals.Append ((Kind => Val_String, Str_Val => To_Unbounded_String (VName)));
            end;
         elsif Current.Is_Range
            and then Current.Expr.Kind = Expr_Variable
            and then Current.Expr_End /= null
            and then Current.Expr_End.Kind = Expr_Variable
         then
            --  SUM(X1:X3), MEAN(X1:X3), ...: a colon range of numbered
            --  variables contributes every variable X1..X3 (design.md 3.6).
            declare
               Lo_Name : constant String :=
                  To_Upper (Current.Expr.Var_Name (1 .. Current.Expr.Var_Len));
               Hi_Name : constant String :=
                  To_Upper (Current.Expr_End.Var_Name (1 .. Current.Expr_End.Var_Len));

               --  Split NAME into its prefix and trailing number.
               function Split (Name : String; Prefix_Last : out Natural;
                               Num : out Natural) return Boolean is
                  I : Natural := Name'Last;
               begin
                  while I >= Name'First and then Name (I) in '0' .. '9' loop
                     I := I - 1;
                  end loop;
                  Prefix_Last := I;
                  if I = Name'Last then
                     Num := 0;
                     return False;
                  end if;
                  Num := Natural'Value (Name (I + 1 .. Name'Last));
                  return True;
               exception
                  when Constraint_Error =>
                     Num := 0;
                     return False;
               end Split;

               Lo_P, Hi_P : Natural;
               Lo_N, Hi_N : Natural;
            begin
               if not Split (Lo_Name, Lo_P, Lo_N)
                  or else not Split (Hi_Name, Hi_P, Hi_N)
                  or else Lo_Name (Lo_Name'First .. Lo_P)
                          /= Hi_Name (Hi_Name'First .. Hi_P)
               then
                  raise SData_Core.Script_Error with
                     "invalid range " & Lo_Name & ":" & Hi_Name
                     & " (names must share a prefix and end in a number)";
               end if;
               for N in Natural'Min (Lo_N, Hi_N) .. Natural'Max (Lo_N, Hi_N) loop
                  declare
                     Img : constant String := Natural'Image (N);
                     E   : Expression_Access :=
                        Parse_Expression
                          (Lo_Name (Lo_Name'First .. Lo_P)
                           & Img (Img'First + 1 .. Img'Last));
                  begin
                     All_Vals.Append (Evaluate (E));
                     Free_Expression (E);
                  exception
                     when others =>
                        Free_Expression (E);
                        raise;
                  end;
               end loop;
            end;
         elsif Current.Expr.Kind = Expr_Variable then
            declare
               VName : constant String :=
                  To_Upper (Current.Expr.Var_Name (1 .. Current.Expr.Var_Len));
            begin
               if Has_Array (VName) then
                  declare
                     Start_Idx, End_Idx : Integer;
                  begin
                     Get_Array_Bounds (VName, Start_Idx, End_Idx);
                     for I in Start_Idx .. End_Idx loop
                        --  Array elements are appended raw, not through the
                        --  Evaluate wrapper.  Safe under the #55 invariant: a
                        --  zero-length Val_String never reaches storage (every
                        --  assignment RHS is Evaluate-normalized and every write
                        --  passes Coerce_Value), so a stored element is already
                        --  normalized (an empty character value is Val_Missing).
                        All_Vals.Append (Get_Array_Element (VName, I));
                     end loop;
                  end;
               else
                  All_Vals.Append (Evaluate (Current.Expr));
               end if;
            end;
         elsif Current.Expr.Kind = Expr_Array_Access
            or else Current.Expr.Kind = Expr_Function_Call
         then
            declare
               AName    : constant String :=
                  To_Upper ((if Current.Expr.Kind = Expr_Array_Access
                             then Current.Expr.Arr_Name (1 .. Current.Expr.Arr_Len)
                             else Current.Expr.Func_Name (1 .. Current.Expr.Func_Len)));
               Sub_List : Expression_List :=
                  (if Current.Expr.Kind = Expr_Array_Access
                   then Current.Expr.Arr_Idx
                   else Current.Expr.Arguments);
            begin
               if Has_Array (AName) then
                  while Sub_List /= null loop
                     if Sub_List.Is_Range then
                        declare
                           Lo_Val : constant Value := Evaluate (Sub_List.Expr);
                           Hi_Val : constant Value := Evaluate (Sub_List.Expr_End);
                           Lo, Hi : Integer;
                        begin
                           if Lo_Val.Kind = Val_Integer then Lo := Integer (Lo_Val.Int_Val);
                           elsif Lo_Val.Kind = Val_Numeric then Lo := Integer (Real'Floor (Lo_Val.Num_Val));
                           else raise SData_Core.Script_Error with "Array range lower bound must be numeric";
                           end if;

                           if Hi_Val.Kind = Val_Integer then Hi := Integer (Hi_Val.Int_Val);
                           elsif Hi_Val.Kind = Val_Numeric then Hi := Integer (Real'Floor (Hi_Val.Num_Val));
                           else raise SData_Core.Script_Error with "Array range upper bound must be numeric";
                           end if;

                           for I in Lo .. Hi loop
                              All_Vals.Append (Get_Array_Element (AName, I));
                           end loop;
                        exception
                           when Constraint_Error => All_Vals.Append ((Kind => Val_Missing));
                        end;
                     else
                        declare
                           Idx_Val : constant Value := Evaluate (Sub_List.Expr);
                           Idx     : Integer;
                        begin
                           if Idx_Val.Kind = Val_Integer then Idx := Integer (Idx_Val.Int_Val);
                           else Idx := Integer (Real'Floor (Convert_To_Real (Idx_Val))); end if;
                           All_Vals.Append (Get_Array_Element (AName, Idx));
                        exception
                           when Constraint_Error => All_Vals.Append ((Kind => Val_Missing));
                        end;
                     end if;
                     Sub_List := Sub_List.Next;
                  end loop;
               else
                  All_Vals.Append (Evaluate (Current.Expr));
               end if;
            end;
         else
            All_Vals.Append (Evaluate (Current.Expr));
         end if;
         Current := Current.Next;
      end loop;

      --  Dispatch via table.
      declare
         Cursor : constant Fn_Maps.Cursor := Dispatch_Table.Find (Name);
      begin
         if Fn_Maps.Has_Element (Cursor) then
            return Invoke_Handler (Cursor, Name, All_Vals);
         end if;
      end;

      --  ADR-062/sdata#76: defense-in-depth backstop, matching the sibling
      --  Call_Function's existing behavior. The primary fix for known
      --  Declarative/Immediate-tier callers (RSEED/NOTE/DIM/SAVE's IF=) is
      --  sdata's own Check_Statement/Check_Expr reuse, which raises this
      --  same class of error earlier and with arity detail this layer
      --  can't easily reconstruct -- this raise exists so a *future*
      --  command that evaluates a user expression without calling
      --  Check_Statement/Check_Expr first fails loudly instead of
      --  silently, not as the primary UX for today's four call sites.
      --  Confirmed safe: only 2 call sites of Evaluate_Function exist in
      --  the whole ecosystem (both inside this file), neither depends on
      --  a silent Val_Missing return for a legitimate purpose.
      raise SData_Core.Script_Error with "unknown function '" & Name & "'";
   end Evaluate_Function;

   --------------------
   -- Get_Expected_Kind --
   --------------------
   function Get_Expected_Kind (Name : String) return Value_Kind is
   begin
      if Name'Length = 0 then return Val_Numeric; end if;
      if Name (Name'Last) = '$' then return Val_String;
      elsif Name (Name'Last) = '%' then return Val_Integer;
      else return Val_Numeric; end if;
   end Get_Expected_Kind;

   -----------------------
   -- Static_Result_Kind --
   -----------------------
   function Static_Result_Kind (Expr : Expression_Access) return Value_Kind is
   begin
      if Expr = null then
         return Val_Missing;
      end if;
      case Expr.Kind is
         when Expr_String_Literal =>
            return Val_String;
         when Expr_Numeric_Literal =>
            return (if Expr.Is_Integer then Val_Integer else Val_Numeric);
         when Expr_Missing =>
            return Val_Missing;
         when Expr_Variable =>
            return Get_Expected_Kind (Expr.Var_Name (1 .. Expr.Var_Len));
         when Expr_Array_Access =>
            return Get_Expected_Kind (Expr.Arr_Name (1 .. Expr.Arr_Len));
         when Expr_Function_Call =>
            --  String-returning functions end in '$' by convention; suffix
            --  drives the kind exactly as it does for variables.
            return Get_Expected_Kind (Expr.Func_Name (1 .. Expr.Func_Len));
         when Expr_Unary_Op =>
            --  Neg and Not both yield numeric.
            return Val_Numeric;
         when Expr_Binary_Op =>
            declare
               L : constant Value_Kind := Static_Result_Kind (Expr.Left);
               R : constant Value_Kind := Static_Result_Kind (Expr.Right);
            begin
               case Expr.Op is
                  when Op_Eq | Op_Ne | Op_Lt | Op_Le | Op_Gt | Op_Ge
                     | Op_And | Op_Or | Op_Xor =>
                     return Val_Numeric;              -- boolean result (0/1)
                  when Op_Sub | Op_Mul | Op_Div | Op_Pow =>
                     return Val_Numeric;              -- numeric-only operators
                  when Op_Add =>
                     --  '+' concatenates two strings, else numeric.  Any
                     --  Val_Missing operand or a string/numeric mix is
                     --  indeterminate -> defer.
                     if L = Val_String and then R = Val_String then
                        return Val_String;
                     elsif (L in Val_Numeric | Val_Integer)
                        and then (R in Val_Numeric | Val_Integer)
                     then
                        return Val_Numeric;
                     else
                        return Val_Missing;
                     end if;
               end case;
            end;
      end case;
   end Static_Result_Kind;

   --------------
   -- Eval_Raw --
   --------------
   --  Raw expression evaluation.  Every recursive sub-evaluation below calls
   --  the public Evaluate wrapper, so intermediate results are normalized too.
   function Eval_Raw (Expr : Expression_Access) return Value is
   begin
      if Expr = null then return (Kind => Val_Missing); end if;

      case Expr.Kind is
         when Expr_Numeric_Literal =>
            if Expr.Is_Integer then
               return (Kind => Val_Integer, Int_Val => Expr.Int_Value);
            else
               return (Kind => Val_Numeric, Num_Val => Expr.Value);
            end if;

         when Expr_String_Literal =>
            declare V : Value (Val_String);
            begin
               V.Str_Val := Expr.Str_Value;
               return V;
            end;

         when Expr_Variable =>
            declare
               VName : constant String := To_Upper (Expr.Var_Name (1 .. Expr.Var_Len));
               VVal  : constant Value  :=
                  (if Expr.Var_Index > 0
                   then Get_PDV_Value (Expr.Var_Index)
                   else Get (VName));
            begin
               if VVal.Kind = Val_Missing then
                  --  Fall back to zero-arg functions (optional parentheses).
                  --  Is_Zero_Arg_Fallback is the single source of truth for this set.
                  if Is_Zero_Arg_Fallback (VName) then
                     return Evaluate_Function (VName, null);
                  end if;
               end if;
               return VVal;
            end;

         when Expr_Array_Access =>
            if Expr.Arr_Idx /= null and then (Expr.Arr_Idx.Next /= null or else Expr.Arr_Idx.Is_Range) then
               raise SData_Core.Script_Error with "Array range or list not permitted in scalar expression context";
            end if;
            declare
               Index_Val : constant Value :=
                  (if Expr.Arr_Idx /= null
                   then Evaluate (Expr.Arr_Idx.Expr)
                   else (Kind => Val_Missing));
               Idx : Integer;
            begin
               if Index_Val.Kind = Val_Integer then
                  Idx := Integer (Index_Val.Int_Val);
               elsif Index_Val.Kind = Val_Numeric then
                  Idx := Integer (Real'Floor (Index_Val.Num_Val));
               else
                  return (Kind => Val_Missing);
               end if;
               return Get_Array_Element (Expr.Arr_Name (1 .. Expr.Arr_Len), Idx);
            end;

         when Expr_Unary_Op =>
            declare Operand_Val : constant Value := Evaluate (Expr.Operand);
            begin
               if Expr.UOp = Op_Not then
                  if Operand_Val.Kind = Val_Missing then return (Kind => Val_Missing); end if;
                  declare V : constant Real := Convert_To_Real (Operand_Val);
                  begin
                     return (Kind => Val_Integer, Int_Val => (if V = 0.0 then 1 else 0));
                  end;
               elsif Operand_Val.Kind = Val_Numeric then
                  case Expr.UOp is
                     when Op_Neg => return (Kind => Val_Numeric, Num_Val => -Operand_Val.Num_Val);
                     when others => return (Kind => Val_Missing);
                  end case;
               elsif Operand_Val.Kind = Val_Integer then
                  case Expr.UOp is
                     when Op_Neg =>
                        if Operand_Val.Int_Val = Int'First then
                           raise Constraint_Error with "Integer overflow in unary negation";
                        end if;
                        return (Kind => Val_Integer, Int_Val => -Operand_Val.Int_Val);
                     when others => return (Kind => Val_Missing);
                  end case;
               else return (Kind => Val_Missing); end if;
            end;

         when Expr_Binary_Op =>
            declare
               L : constant Value := Evaluate (Expr.Left);
               R : constant Value := Evaluate (Expr.Right);
            begin
               if L.Kind = Val_Missing or else R.Kind = Val_Missing then
                  return (Kind => Val_Missing);
               end if;

               if (L.Kind = Val_Numeric or else L.Kind = Val_Integer) and then
                  (R.Kind = Val_Numeric or else R.Kind = Val_Integer)
               then
                  if L.Kind = Val_Integer and then R.Kind = Val_Integer then
                     declare
                        L64   : constant Interfaces.Integer_64 := Interfaces.Integer_64 (L.Int_Val);
                        R64   : constant Interfaces.Integer_64 := Interfaces.Integer_64 (R.Int_Val);
                        Res64 : Interfaces.Integer_64;
                     begin
                        case Expr.Op is
                           when Op_Add => Res64 := L64 + R64;
                           when Op_Sub => Res64 := L64 - R64;
                           when Op_Mul => Res64 := L64 * R64;
                           when Op_Div =>
                              if R.Int_Val = 0 then
                                 raise SData_Core.Script_Error with "Division by zero.";
                              end if;
                              return (Kind    => Val_Numeric,
                                      Num_Val => Real (L.Int_Val) / Real (R.Int_Val));
                           when Op_Pow =>
                              return Real_Pow (Real (L.Int_Val), Real (R.Int_Val));
                           when Op_Eq  => return (Kind => Val_Integer, Int_Val => (if L.Int_Val = R.Int_Val  then 1 else 0));
                           when Op_Ne  => return (Kind => Val_Integer, Int_Val => (if L.Int_Val /= R.Int_Val then 1 else 0));
                           when Op_Lt  => return (Kind => Val_Integer, Int_Val => (if L.Int_Val < R.Int_Val  then 1 else 0));
                           when Op_Le  => return (Kind => Val_Integer, Int_Val => (if L.Int_Val <= R.Int_Val then 1 else 0));
                           when Op_Gt  => return (Kind => Val_Integer, Int_Val => (if L.Int_Val > R.Int_Val  then 1 else 0));
                           when Op_Ge  => return (Kind => Val_Integer, Int_Val => (if L.Int_Val >= R.Int_Val then 1 else 0));
                           when Op_And => return (Kind => Val_Integer, Int_Val => (if L.Int_Val /= 0 and then R.Int_Val /= 0 then 1 else 0));
                           when Op_Or  => return (Kind => Val_Integer, Int_Val => (if L.Int_Val /= 0 or else R.Int_Val /= 0 then 1 else 0));
                           when Op_Xor => return (Kind => Val_Integer, Int_Val => (if (L.Int_Val /= 0) /= (R.Int_Val /= 0) then 1 else 0));
                        end case;
                        if Expr.Op in Op_Add .. Op_Mul then
                           return (Kind => Val_Integer, Int_Val => Int (Res64));
                        end if;
                        return (Kind => Val_Missing);
                     exception
                        --  Int and Interfaces.Integer_64 share the -2**63 ..
                        --  2**63-1 range, so a true 64-bit overflow surfaces as
                        --  Constraint_Error from the Add/Sub/Mul above; re-raise
                        --  it with the documented message.
                        when Constraint_Error =>
                           raise Constraint_Error
                             with "Integer overflow in " & Expr.Op'Image;
                     end;
                  else
                     declare
                        FL : constant Real := Convert_To_Real (L);
                        FR : constant Real := Convert_To_Real (R);
                     begin
                        case Expr.Op is
                           when Op_Add => return Numeric_Result_Checked (FL + FR);
                           when Op_Sub => return Numeric_Result_Checked (FL - FR);
                           when Op_Mul => return Numeric_Result_Checked (FL * FR);
                           when Op_Div =>
                              if FR = 0.0 and then
                                 not SData_Core.Config.Runtime.IEEE_Divide
                              then
                                 raise SData_Core.Script_Error with "Division by zero.";
                              end if;
                              return Numeric_Result_Checked (FL / FR);
                           when Op_Pow => return Real_Pow (FL, FR);
                           when Op_Eq  => return (Kind => Val_Integer, Int_Val => (if FL = FR  then 1 else 0));
                           when Op_Ne  => return (Kind => Val_Integer, Int_Val => (if FL /= FR then 1 else 0));
                           when Op_Lt  => return (Kind => Val_Integer, Int_Val => (if FL < FR  then 1 else 0));
                           when Op_Le  => return (Kind => Val_Integer, Int_Val => (if FL <= FR then 1 else 0));
                           when Op_Gt  => return (Kind => Val_Integer, Int_Val => (if FL > FR  then 1 else 0));
                           when Op_Ge  => return (Kind => Val_Integer, Int_Val => (if FL >= FR then 1 else 0));
                           when Op_And => return (Kind => Val_Integer, Int_Val => (if FL /= 0.0 and then FR /= 0.0 then 1 else 0));
                           when Op_Or  => return (Kind => Val_Integer, Int_Val => (if FL /= 0.0 or else FR /= 0.0 then 1 else 0));
                           when Op_Xor => return (Kind => Val_Integer, Int_Val => (if (FL /= 0.0) /= (FR /= 0.0) then 1 else 0));
                        end case;
                     end;
                  end if;

               elsif L.Kind = Val_String and then R.Kind = Val_String then
                  case Expr.Op is
                     when Op_Add =>
                        declare
                           V     : Value (Val_String);
                           Limit : Natural := 1024;
                        begin
                           if SData_Core.Config.Max_String_Len > 0 then
                              Limit := SData_Core.Config.Max_String_Len;
                           end if;
                           declare
                              LL : constant Natural := Length (L.Str_Val);
                              RL : constant Natural := Length (R.Str_Val);
                           begin
                              if LL + RL > Limit then
                                 Put_Line_Error ("Warning: String truncated to " &
                                                Natural'Image (Limit) & " characters.");
                                 --  UTF8_Prefix_Length: never cut a
                                 --  multi-byte character in half.
                                 if LL >= Limit then
                                    declare
                                       LS : constant String := To_String (L.Str_Val);
                                    begin
                                       V.Str_Val := To_Unbounded_String
                                          (LS (1 .. SData_Core.Values.UTF8_Prefix_Length (LS, Limit)));
                                    end;
                                 else
                                    declare
                                       RS : constant String := To_String (R.Str_Val);
                                    begin
                                       V.Str_Val := L.Str_Val
                                          & RS (1 .. SData_Core.Values.UTF8_Prefix_Length (RS, Limit - LL));
                                    end;
                                 end if;
                              else
                                 V.Str_Val := L.Str_Val & R.Str_Val;
                              end if;
                           end;
                           return V;
                        end;
                     when Op_Eq  => return (Kind => Val_Integer, Int_Val => (if L.Str_Val = R.Str_Val then 1 else 0));
                     when Op_Ne  => return (Kind => Val_Integer, Int_Val => (if L.Str_Val /= R.Str_Val then 1 else 0));
                     when Op_Lt  => return (Kind => Val_Integer, Int_Val => (if L.Str_Val < R.Str_Val then 1 else 0));
                     when Op_Le  => return (Kind => Val_Integer, Int_Val => (if L.Str_Val <= R.Str_Val then 1 else 0));
                     when Op_Gt  => return (Kind => Val_Integer, Int_Val => (if L.Str_Val > R.Str_Val then 1 else 0));
                     when Op_Ge  => return (Kind => Val_Integer, Int_Val => (if L.Str_Val >= R.Str_Val then 1 else 0));
                     when others => raise SData_Core.Script_Error with "Operator not supported for character values.";
                  end case;
               else
                  raise SData_Core.Script_Error with "Type mismatch in expression (e.g., combining numeric and character values).";
               end if;
            end;

         when Expr_Missing =>
            return (Kind => Val_Missing);

         when Expr_Function_Call =>
            declare
               FName : constant String :=
                  To_Upper (Expr.Func_Name (1 .. Expr.Func_Len));
            begin
               if Has_Array (FName) then
                  if Expr.Arguments /= null and then (Expr.Arguments.Next /= null or else Expr.Arguments.Is_Range) then
                     raise SData_Core.Script_Error with "Array range or list not permitted in scalar expression context";
                  end if;
                  declare
                     Index_Val : constant Value :=
                        (if Expr.Arguments /= null
                         then Evaluate (Expr.Arguments.Expr)
                         else (Kind => Val_Missing));
                     Idx : Integer;
                  begin
                     if Index_Val.Kind = Val_Integer then
                        Idx := Integer (Index_Val.Int_Val);
                     elsif Index_Val.Kind = Val_Numeric then
                        Idx := Integer (Real'Floor (Index_Val.Num_Val));
                     else
                        return (Kind => Val_Missing);
                     end if;
                     return Get_Array_Element (FName, Idx);
                  end;
               else
                  return Evaluate_Function (FName, Expr.Arguments);
               end if;
            end;
      end case;
   end Eval_Raw;

   --------------
   -- Evaluate --
   --------------
   function Evaluate (Expr : Expression_Access) return Value is
      Result : constant Value := Eval_Raw (Expr);
   begin
      --  Issue #55: a zero-length character value IS the missing value.
      --  Normalizing here (and, via the recursion above, at every level)
      --  makes LEN("")/empty-concat/TRIM$("") propagate missing while the
      --  MISSING/N/NMISS family stays correct.
      if Result.Kind = Val_String and then Length (Result.Str_Val) = 0 then
         return (Kind => Val_Missing);
      end if;
      return Result;
   end Evaluate;
   pragma Annotate (GNATcheck, Exempt_Off, "Recursive_Subprograms");

   ---------------------------------------------------------------------------
   --  Parse_Expression — string-based expression parser (internal mini-lexer)
   --
   --  Mirrors the Pratt (precedence-climbing) algorithm used in sdata-parser.adb.
   --  Produces identical Expression trees for the same expression text.
   --  Raises SData_Core.Script_Error on any syntax error.
   ---------------------------------------------------------------------------

   function Parse_Expression (Text : String) return Expression_Access is separate;

begin
   null;
end SData_Core.Evaluator;