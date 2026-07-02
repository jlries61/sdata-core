--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with SData_Core.Variables; use SData_Core.Variables;
with SData_Core.Config;
with SData_Core.Config.Runtime;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;
with SData_Core.IO;        use SData_Core.IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Interfaces;
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
      return Fn_Maps.Element (Cursor).all (UC, Vals);
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

   function Convert_To_Float (V : Value) return Float is
   begin
      case V.Kind is
         when Val_Numeric => return V.Num_Val;
         when Val_Integer => return Float (V.Int_Val);
         when others      => raise Constraint_Error with "Cannot convert " & V.Kind'Image & " to Float";
      end case;
   end Convert_To_Float;

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

   function Num_Result (V : Float) return Value is
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

   function Is_NaN (F : Float) return Boolean is
   begin
      return F /= F;
   end Is_NaN;

   function Numeric_Result_Checked (V : Float) return Value is
   begin
      if Is_NaN (V) then
         return Handle_Domain_Error ("Result is not a number (NaN).");
      end if;
      return (Kind => Val_Numeric, Num_Val => V);
   end Numeric_Result_Checked;

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
                           if Lo_Val.Kind = Val_Integer then Lo := Lo_Val.Int_Val;
                           elsif Lo_Val.Kind = Val_Numeric then Lo := Integer (Float'Floor (Lo_Val.Num_Val));
                           else raise SData_Core.Script_Error with "Array range lower bound must be numeric";
                           end if;

                           if Hi_Val.Kind = Val_Integer then Hi := Hi_Val.Int_Val;
                           elsif Hi_Val.Kind = Val_Numeric then Hi := Integer (Float'Floor (Hi_Val.Num_Val));
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
                           if Idx_Val.Kind = Val_Integer then Idx := Idx_Val.Int_Val;
                           else Idx := Integer (Float'Floor (Convert_To_Float (Idx_Val))); end if;
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
            return Fn_Maps.Element (Cursor).all (Name, All_Vals);
         end if;
      end;

      return (Kind => Val_Missing);
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
   -- Evaluate --
   --------------
   function Evaluate (Expr : Expression_Access) return Value is
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
                  Idx := Index_Val.Int_Val;
               elsif Index_Val.Kind = Val_Numeric then
                  Idx := Integer (Float'Floor (Index_Val.Num_Val));
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
                  declare V : constant Float := Convert_To_Float (Operand_Val);
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
                        if Operand_Val.Int_Val = Integer'First then
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
                                      Num_Val => Float (L.Int_Val) / Float (R.Int_Val));
                           when Op_Pow =>
                              return Numeric_Result_Checked
                                (Float (L.Int_Val) ** Float (R.Int_Val));
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
                           if Res64 < Interfaces.Integer_64 (Integer'First)
                              or else Res64 > Interfaces.Integer_64 (Integer'Last)
                           then
                              raise Constraint_Error with "Integer overflow in " & Expr.Op'Image;
                           end if;
                           return (Kind => Val_Integer, Int_Val => Integer (Res64));
                        end if;
                        return (Kind => Val_Missing);
                     end;
                  else
                     declare
                        FL : constant Float := Convert_To_Float (L);
                        FR : constant Float := Convert_To_Float (R);
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
                           when Op_Pow => return Numeric_Result_Checked (FL ** FR);
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
                                 if LL >= Limit then
                                    V.Str_Val := To_Unbounded_String (Slice (L.Str_Val, 1, Limit));
                                 else
                                    V.Str_Val := L.Str_Val & Slice (R.Str_Val, 1, Limit - LL);
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
                        Idx := Index_Val.Int_Val;
                     elsif Index_Val.Kind = Val_Numeric then
                        Idx := Integer (Float'Floor (Index_Val.Num_Val));
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
   end Evaluate;
   pragma Annotate (GNATcheck, Exempt_Off, "Recursive_Subprograms");

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
         TK_EOF);

      Max_Tok : constant := 512;

      type Mini_Token is record
         Kind     : Mini_Token_Kind := TK_EOF;
         Text     : String (1 .. Max_Tok) := (others => ' ');
         Text_Len : Natural := 0;
         Int_Val  : Integer     := 0;
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
                        Current.Int_Val := Integer'Value (Raw);
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
               Node.Value      := Float (Current.Int_Val);
               Node.Is_Integer := True;
               Node.Int_Value  := Current.Int_Val;
               Advance;
               return Node;

            when TK_Float =>
               Node := new Expression (Expr_Numeric_Literal);
               Node.Value      := Float (Current.Flt_Val);
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

begin
   null;
end SData_Core.Evaluator;