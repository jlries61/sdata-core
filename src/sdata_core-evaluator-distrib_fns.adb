--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with SData_Core.Statistics;
with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;
with SData_Core.Values; use SData_Core.Values;

package body SData_Core.Evaluator.Distrib_Fns is

   ---------------------------------------------------------------------------
   --  PDF family
   ---------------------------------------------------------------------------

   function Handle_ZDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      N : constant Natural := Natural (Vals.Length);
   begin
      if N = 2 then raise SData_Core.Script_Error with "ZDF requires 1 or 3 arguments, not 2."; end if;
      if N >= 3 then
         if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Normal_PDF (Convert_To_Float (Vals.Element (1)),
                                                         Convert_To_Float (Vals.Element (2)),
                                                         Convert_To_Float (Vals.Element (3))));
      else
         if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Normal_PDF (Convert_To_Float (Vals.Element (1)), 0.0, 1.0));
      end if;
   end Handle_ZDF;

   function Handle_NDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Binomial_PMF (Convert_To_Float (Vals.Element (1)),
                                                        Convert_To_Float (Vals.Element (2)),
                                                        Convert_To_Float (Vals.Element (3))));
   end Handle_NDF;

   function Handle_UDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Uniform_PDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2)),
                                                       Convert_To_Float (Vals.Element (3))));
   end Handle_UDF;

   function Handle_EDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Exponential_PDF (Convert_To_Float (Vals.Element (1)),
                                                           Convert_To_Float (Vals.Element (2))));
   end Handle_EDF;

   function Handle_BDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Beta_PDF (Convert_To_Float (Vals.Element (1)),
                                                    Convert_To_Float (Vals.Element (2)),
                                                    Convert_To_Float (Vals.Element (3))));
   end Handle_BDF;

   function Handle_PDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Poisson_PMF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2))));
   end Handle_PDF;

   function Handle_GDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Gamma_PDF (Convert_To_Float (Vals.Element (1)),
                                                     Convert_To_Float (Vals.Element (2)),
                                                     Convert_To_Float (Vals.Element (3))));
   end Handle_GDF;

   function Handle_XDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Chi_Square_PDF (Convert_To_Float (Vals.Element (1)),
                                                          Convert_To_Float (Vals.Element (2))));
   end Handle_XDF;

   function Handle_TDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Student_T_PDF (Convert_To_Float (Vals.Element (1)),
                                                         Convert_To_Float (Vals.Element (2))));
   end Handle_TDF;

   function Handle_FDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.F_PDF (Convert_To_Float (Vals.Element (1)),
                                                 Convert_To_Float (Vals.Element (2)),
                                                 Convert_To_Float (Vals.Element (3))));
   end Handle_FDF;

   function Handle_MDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Binomial_PMF (Convert_To_Float (Vals.Element (1)),
                                                        Convert_To_Float (Vals.Element (2)),
                                                        Convert_To_Float (Vals.Element (3))));
   end Handle_MDF;

   function Handle_WDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Weibull_PDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2)),
                                                       Convert_To_Float (Vals.Element (3))));
   end Handle_WDF;

   --  Logistic PDF: f(x) = e^-x / (1 + e^-x)^2
   function Handle_LDF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare
         X : constant Float := Convert_To_Float (Vals.Element (1));
         E : constant Float := Exp (-X);
         S : constant Float := 1.0 + E;
      begin
         return Num_Result (E / (S * S));
      end;
   end Handle_LDF;

   ---------------------------------------------------------------------------
   --  CDF family
   ---------------------------------------------------------------------------

   function Handle_ZCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      N : constant Natural := Natural (Vals.Length);
   begin
      if N = 2 then raise SData_Core.Script_Error with "ZCF requires 1 or 3 arguments, not 2."; end if;
      if N >= 3 then
         if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Normal_CDF (Convert_To_Float (Vals.Element (1)),
                                                         Convert_To_Float (Vals.Element (2)),
                                                         Convert_To_Float (Vals.Element (3))));
      else
         if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Normal_CDF (Convert_To_Float (Vals.Element (1)), 0.0, 1.0));
      end if;
   end Handle_ZCF;

   function Handle_NCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Binomial_CDF (Convert_To_Float (Vals.Element (1)),
                                                        Convert_To_Float (Vals.Element (2)),
                                                        Convert_To_Float (Vals.Element (3))));
   end Handle_NCF;

   function Handle_UCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Uniform_CDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2)),
                                                       Convert_To_Float (Vals.Element (3))));
   end Handle_UCF;

   function Handle_ECF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Exponential_CDF (Convert_To_Float (Vals.Element (1)),
                                                           Convert_To_Float (Vals.Element (2))));
   end Handle_ECF;

   function Handle_BCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Beta_CDF (Convert_To_Float (Vals.Element (1)),
                                                    Convert_To_Float (Vals.Element (2)),
                                                    Convert_To_Float (Vals.Element (3))));
   end Handle_BCF;

   function Handle_PCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Poisson_CDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2))));
   end Handle_PCF;

   function Handle_GCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Gamma_CDF (Convert_To_Float (Vals.Element (1)),
                                                     Convert_To_Float (Vals.Element (2)),
                                                     Convert_To_Float (Vals.Element (3))));
   end Handle_GCF;

   function Handle_XCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Chi_Square_CDF (Convert_To_Float (Vals.Element (1)),
                                                          Convert_To_Float (Vals.Element (2))));
   end Handle_XCF;

   function Handle_TCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Student_T_CDF (Convert_To_Float (Vals.Element (1)),
                                                         Convert_To_Float (Vals.Element (2))));
   end Handle_TCF;

   function Handle_FCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.F_CDF (Convert_To_Float (Vals.Element (1)),
                                                 Convert_To_Float (Vals.Element (2)),
                                                 Convert_To_Float (Vals.Element (3))));
   end Handle_FCF;

   function Handle_MCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Binomial_CDF (Convert_To_Float (Vals.Element (1)),
                                                        Convert_To_Float (Vals.Element (2)),
                                                        Convert_To_Float (Vals.Element (3))));
   end Handle_MCF;

   function Handle_WCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Weibull_CDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2)),
                                                       Convert_To_Float (Vals.Element (3))));
   end Handle_WCF;

   --  Logistic CDF: F(x) = 1 / (1 + e^-x)  (sigmoid)
   function Handle_LCF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (1.0 / (1.0 + Exp (-Convert_To_Float (Vals.Element (1)))));
   end Handle_LCF;

   ---------------------------------------------------------------------------
   --  IDF family
   ---------------------------------------------------------------------------

   function Handle_ZIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      N : constant Natural := Natural (Vals.Length);
   begin
      if N = 2 then raise SData_Core.Script_Error with "ZIF requires 1 or 3 arguments, not 2."; end if;
      if N >= 3 then
         if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Normal_IDF (Convert_To_Float (Vals.Element (1)),
                                                         Convert_To_Float (Vals.Element (2)),
                                                         Convert_To_Float (Vals.Element (3))));
      else
         if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Normal_IDF (Convert_To_Float (Vals.Element (1)), 0.0, 1.0));
      end if;
   end Handle_ZIF;

   function Handle_NIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Binomial_IDF (Convert_To_Float (Vals.Element (1)),
                                                        Convert_To_Float (Vals.Element (2)),
                                                        Convert_To_Float (Vals.Element (3))));
   end Handle_NIF;

   function Handle_UIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Uniform_IDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2)),
                                                       Convert_To_Float (Vals.Element (3))));
   end Handle_UIF;

   function Handle_EIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Exponential_IDF (Convert_To_Float (Vals.Element (1)),
                                                           Convert_To_Float (Vals.Element (2))));
   end Handle_EIF;

   function Handle_BIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Beta_IDF (Convert_To_Float (Vals.Element (1)),
                                                    Convert_To_Float (Vals.Element (2)),
                                                    Convert_To_Float (Vals.Element (3))));
   end Handle_BIF;

   --  Logistic IDF: Q(p) = ln(p / (1-p))  (logit); p must be in (0, 1).
   function Handle_LIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      declare P : constant Float := Convert_To_Float (Vals.Element (1));
      begin
         if P <= 0.0 or else P >= 1.0 then
            return Handle_Domain_Error ("LIF argument must be in (0, 1).");
         end if;
         return Num_Result (Log (P / (1.0 - P)));
      end;
   end Handle_LIF;

   function Handle_PIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Poisson_IDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2))));
   end Handle_PIF;

   function Handle_GIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Gamma_IDF (Convert_To_Float (Vals.Element (1)),
                                                     Convert_To_Float (Vals.Element (2)),
                                                     Convert_To_Float (Vals.Element (3))));
   end Handle_GIF;

   function Handle_XIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Chi_Square_IDF (Convert_To_Float (Vals.Element (1)),
                                                          Convert_To_Float (Vals.Element (2))));
   end Handle_XIF;

   function Handle_TIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Student_T_IDF (Convert_To_Float (Vals.Element (1)),
                                                         Convert_To_Float (Vals.Element (2))));
   end Handle_TIF;

   function Handle_FIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.F_IDF (Convert_To_Float (Vals.Element (1)),
                                                 Convert_To_Float (Vals.Element (2)),
                                                 Convert_To_Float (Vals.Element (3))));
   end Handle_FIF;

   function Handle_WIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Weibull_IDF (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2)),
                                                       Convert_To_Float (Vals.Element (3))));
   end Handle_WIF;

   function Handle_MIF (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 3) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Binomial_IDF (Convert_To_Float (Vals.Element (1)),
                                                        Convert_To_Float (Vals.Element (2)),
                                                        Convert_To_Float (Vals.Element (3))));
   end Handle_MIF;

   ---------------------------------------------------------------------------
   --  RN (random number) family
   ---------------------------------------------------------------------------

   function Handle_ZRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      N : constant Natural := Natural (Vals.Length);
   begin
      if N = 0 then
         return Num_Result (SData_Core.Statistics.Normal_RN (0.0, 1.0));
      elsif N = 1 then
         if Vals.Element (1).Kind = Val_Missing then return (Kind => Val_Missing); end if;
         raise SData_Core.Script_Error with "ZRN requires 0 or 2 arguments, not 1.";
      else
         if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Normal_RN (Convert_To_Float (Vals.Element (1)),
                                                        Convert_To_Float (Vals.Element (2))));
      end if;
   end Handle_ZRN;

   function Handle_NRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Normal_RN (Convert_To_Float (Vals.Element (1)),
                                                      Convert_To_Float (Vals.Element (2))));
   end Handle_NRN;

   function Handle_URN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
      N : constant Natural := Natural (Vals.Length);
   begin
      if N = 0 then
         return Num_Result (SData_Core.Statistics.Uniform_RN (0.0, 1.0));
      elsif N = 1 then
         if Vals.Element (1).Kind = Val_Missing then return (Kind => Val_Missing); end if;
         raise SData_Core.Script_Error with "URN requires 0 or 2 arguments, not 1.";
      else
         if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
         return Num_Result (SData_Core.Statistics.Uniform_RN (Convert_To_Float (Vals.Element (1)),
                                                         Convert_To_Float (Vals.Element (2))));
      end if;
   end Handle_URN;

   function Handle_ERN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Exponential_RN (Convert_To_Float (Vals.Element (1))));
   end Handle_ERN;

   function Handle_PRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Poisson_RN (Convert_To_Float (Vals.Element (1))));
   end Handle_PRN;

   function Handle_GRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Gamma_RN (Convert_To_Float (Vals.Element (1)),
                                                    Convert_To_Float (Vals.Element (2))));
   end Handle_GRN;

   function Handle_MRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Binomial_RN (Convert_To_Float (Vals.Element (1)),
                                                       Convert_To_Float (Vals.Element (2))));
   end Handle_MRN;

   function Handle_WRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Weibull_RN (Convert_To_Float (Vals.Element (1)),
                                                      Convert_To_Float (Vals.Element (2))));
   end Handle_WRN;

   function Handle_BRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Beta_RN (Convert_To_Float (Vals.Element (1)),
                                                   Convert_To_Float (Vals.Element (2))));
   end Handle_BRN;

   --  Logistic RN: sample via inversion — U(0,1) → logit(U)
   function Handle_LRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
      U : constant Float := SData_Core.Statistics.Uniform_RN (0.0, 1.0);
   begin
      return Num_Result (Log (U / (1.0 - U)));
   end Handle_LRN;

   function Handle_XRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Chi_Square_RN (Convert_To_Float (Vals.Element (1))));
   end Handle_XRN;

   function Handle_TRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 1) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.Student_T_RN (Convert_To_Float (Vals.Element (1))));
   end Handle_TRN;

   function Handle_FRN (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name);
   begin
      if not Has_Args (Vals, 2) then return (Kind => Val_Missing); end if;
      return Num_Result (SData_Core.Statistics.F_RN (Convert_To_Float (Vals.Element (1)),
                                                Convert_To_Float (Vals.Element (2))));
   end Handle_FRN;

   function Handle_Ran (Name : String; Vals : Value_Vectors.Vector) return Value is
      pragma Unreferenced (Name, Vals);
   begin
      return Num_Result (SData_Core.Statistics.Uniform_Random);
   end Handle_Ran;

   ---------------------------------------------------------------------------

   procedure Register is
   begin
      --  PDF family
      Dispatch_Table.Insert ("ZDF",    Handle_ZDF'Access);
      Dispatch_Table.Insert ("NDF",    Handle_NDF'Access);
      Dispatch_Table.Insert ("UDF",    Handle_UDF'Access);
      Dispatch_Table.Insert ("EDF",    Handle_EDF'Access);
      Dispatch_Table.Insert ("BDF",    Handle_BDF'Access);
      Dispatch_Table.Insert ("PDF",    Handle_PDF'Access);
      Dispatch_Table.Insert ("GDF",    Handle_GDF'Access);
      Dispatch_Table.Insert ("XDF",    Handle_XDF'Access);
      Dispatch_Table.Insert ("TDF",    Handle_TDF'Access);
      Dispatch_Table.Insert ("FDF",    Handle_FDF'Access);
      Dispatch_Table.Insert ("MDF",    Handle_MDF'Access);
      Dispatch_Table.Insert ("WDF",    Handle_WDF'Access);
      Dispatch_Table.Insert ("LDF",    Handle_LDF'Access);
      --  CDF family
      Dispatch_Table.Insert ("ZCF",    Handle_ZCF'Access);
      Dispatch_Table.Insert ("NCF",    Handle_NCF'Access);
      Dispatch_Table.Insert ("UCF",    Handle_UCF'Access);
      Dispatch_Table.Insert ("ECF",    Handle_ECF'Access);
      Dispatch_Table.Insert ("BCF",    Handle_BCF'Access);
      Dispatch_Table.Insert ("PCF",    Handle_PCF'Access);
      Dispatch_Table.Insert ("GCF",    Handle_GCF'Access);
      Dispatch_Table.Insert ("XCF",    Handle_XCF'Access);
      Dispatch_Table.Insert ("TCF",    Handle_TCF'Access);
      Dispatch_Table.Insert ("FCF",    Handle_FCF'Access);
      Dispatch_Table.Insert ("MCF",    Handle_MCF'Access);
      Dispatch_Table.Insert ("WCF",    Handle_WCF'Access);
      Dispatch_Table.Insert ("LCF",    Handle_LCF'Access);
      --  IDF family
      Dispatch_Table.Insert ("ZIF",    Handle_ZIF'Access);
      Dispatch_Table.Insert ("NIF",    Handle_NIF'Access);
      Dispatch_Table.Insert ("UIF",    Handle_UIF'Access);
      Dispatch_Table.Insert ("EIF",    Handle_EIF'Access);
      Dispatch_Table.Insert ("BIF",    Handle_BIF'Access);
      Dispatch_Table.Insert ("LIF",    Handle_LIF'Access);
      Dispatch_Table.Insert ("PIF",    Handle_PIF'Access);
      Dispatch_Table.Insert ("MIF",    Handle_MIF'Access);
      Dispatch_Table.Insert ("GIF",    Handle_GIF'Access);
      Dispatch_Table.Insert ("XIF",    Handle_XIF'Access);
      Dispatch_Table.Insert ("TIF",    Handle_TIF'Access);
      Dispatch_Table.Insert ("FIF",    Handle_FIF'Access);
      Dispatch_Table.Insert ("WIF",    Handle_WIF'Access);
      --  RN family
      Dispatch_Table.Insert ("ZRN",    Handle_ZRN'Access);
      Dispatch_Table.Insert ("NRN",    Handle_NRN'Access);
      Dispatch_Table.Insert ("URN",    Handle_URN'Access);
      Dispatch_Table.Insert ("ERN",    Handle_ERN'Access);
      Dispatch_Table.Insert ("PRN",    Handle_PRN'Access);
      Dispatch_Table.Insert ("GRN",    Handle_GRN'Access);
      Dispatch_Table.Insert ("MRN",    Handle_MRN'Access);
      Dispatch_Table.Insert ("WRN",    Handle_WRN'Access);
      Dispatch_Table.Insert ("BRN",    Handle_BRN'Access);
      Dispatch_Table.Insert ("LRN",    Handle_LRN'Access);
      Dispatch_Table.Insert ("XRN",    Handle_XRN'Access);
      Dispatch_Table.Insert ("TRN",    Handle_TRN'Access);
      Dispatch_Table.Insert ("FRN",    Handle_FRN'Access);
      Dispatch_Table.Insert ("RAN",    Handle_Ran'Access);
      Dispatch_Table.Insert ("RANDOM", Handle_Ran'Access);
      Dispatch_Table.Insert ("RND",    Handle_Ran'Access);

      --  Arity metadata (one entry per Dispatch_Table insert above).
      --  DF/CF/IF variants take x (or k) followed by the distribution
      --  parameters; RN variants take only the parameters.  The Z/U families
      --  accept an optional (mu,sigma)/(lo,hi) pair, hence a widened range.
      --  PDF family
      Register_Arity ("ZDF", 1, 3);   -- ZDF(x) or ZDF(x,mu,sigma); 2 rejected at runtime
      Register_Arity ("NDF", 3, 3);
      Register_Arity ("UDF", 3, 3);
      Register_Arity ("EDF", 2, 2);
      Register_Arity ("BDF", 3, 3);
      Register_Arity ("PDF", 2, 2);
      Register_Arity ("GDF", 3, 3);
      Register_Arity ("XDF", 2, 2);
      Register_Arity ("TDF", 2, 2);
      Register_Arity ("FDF", 3, 3);
      Register_Arity ("MDF", 3, 3);
      Register_Arity ("WDF", 3, 3);
      Register_Arity ("LDF", 1, 1);
      --  CDF family
      Register_Arity ("ZCF", 1, 3);   -- ZCF(x) or ZCF(x,mu,sigma); 2 rejected at runtime
      Register_Arity ("NCF", 3, 3);
      Register_Arity ("UCF", 3, 3);
      Register_Arity ("ECF", 2, 2);
      Register_Arity ("BCF", 3, 3);
      Register_Arity ("PCF", 2, 2);
      Register_Arity ("GCF", 3, 3);
      Register_Arity ("XCF", 2, 2);
      Register_Arity ("TCF", 2, 2);
      Register_Arity ("FCF", 3, 3);
      Register_Arity ("MCF", 3, 3);
      Register_Arity ("WCF", 3, 3);
      Register_Arity ("LCF", 1, 1);
      --  IDF family
      Register_Arity ("ZIF", 1, 3);   -- ZIF(p) or ZIF(p,mu,sigma); 2 rejected at runtime
      Register_Arity ("NIF", 3, 3);
      Register_Arity ("UIF", 3, 3);
      Register_Arity ("EIF", 2, 2);
      Register_Arity ("BIF", 3, 3);
      Register_Arity ("LIF", 1, 1);
      Register_Arity ("PIF", 2, 2);
      Register_Arity ("MIF", 3, 3);
      Register_Arity ("GIF", 3, 3);
      Register_Arity ("XIF", 2, 2);
      Register_Arity ("TIF", 2, 2);
      Register_Arity ("FIF", 3, 3);
      Register_Arity ("WIF", 3, 3);
      --  RN family (parameters only)
      Register_Arity ("ZRN", 0, 2);   -- ZRN() or ZRN(mu,sigma); 1 rejected at runtime
      Register_Arity ("NRN", 2, 2);
      Register_Arity ("URN", 0, 2);   -- URN() or URN(lo,hi); 1 rejected at runtime
      Register_Arity ("ERN", 1, 1);
      Register_Arity ("PRN", 1, 1);
      Register_Arity ("GRN", 2, 2);
      Register_Arity ("MRN", 2, 2);
      Register_Arity ("WRN", 2, 2);
      Register_Arity ("BRN", 2, 2);
      Register_Arity ("LRN", 0, 0);   -- standard logistic: no parameters
      Register_Arity ("XRN", 1, 1);
      Register_Arity ("TRN", 1, 1);
      Register_Arity ("FRN", 2, 2);
      Register_Arity ("RAN",    0, 0);
      Register_Arity ("RANDOM", 0, 0);
      Register_Arity ("RND",    0, 0);
   end Register;

begin
   Register;
end SData_Core.Evaluator.Distrib_Fns;