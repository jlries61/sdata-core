--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Numerics;
with Ada.Numerics.Float_Random;

package SData_Core.Statistics is

   --  =======================================================================
   --  Probability Distribution Functions
   --  =======================================================================

   --  Standard Normal (Z)
   function Z_PDF (Z : Float) return Float;
   function Z_CDF (Z : Float) return Float;
   function Z_IDF (P : Float) return Float;

   --  General Normal
   function Normal_PDF (X, Mean, Std_Dev : Float) return Float;
   function Normal_CDF (X, Mean, Std_Dev : Float) return Float;
   function Normal_IDF (P, Mean, Std_Dev : Float) return Float;
   function Normal_RN  (Mean, Std_Dev : Float) return Float;

   --  Uniform
   function Uniform_PDF (X, Lower, Upper : Float) return Float;
   function Uniform_CDF (X, Lower, Upper : Float) return Float;
   function Uniform_IDF (P, Lower, Upper : Float) return Float;
   function Uniform_RN  (Lower, Upper : Float) return Float;

   --  Exponential
   function Exponential_PDF (X, Rate : Float) return Float;
   function Exponential_CDF (X, Rate : Float) return Float;
   function Exponential_IDF (P, Rate : Float) return Float;
   function Exponential_RN  (Rate : Float) return Float;

   --  Beta
   function Beta_PDF (X, Alpha, Beta : Float) return Float;
   function Beta_CDF (X, Alpha, Beta : Float) return Float;
   function Beta_IDF (P, Alpha, Beta : Float) return Float;

   --  Poisson (Discrete)
   function Poisson_PMF (K, Mean : Float) return Float;
   function Poisson_CDF (K, Mean : Float) return Float;
   function Poisson_RN  (Mean : Float) return Float;

   --  Gamma
   function Gamma_PDF (X, Alpha, Beta : Float) return Float;
   function Gamma_CDF (X, Alpha, Beta : Float) return Float;
   function Gamma_RN  (Alpha, Beta : Float) return Float;

   --  Chi-square
   function Chi_Square_PDF (X, DF : Float) return Float;
   function Chi_Square_CDF (X, DF : Float) return Float;

   --  Student's T
   function Student_T_PDF (T, DF : Float) return Float;
   function Student_T_CDF (T, DF : Float) return Float;

   --  Snedecor's F
   function F_PDF (X, DF1, DF2 : Float) return Float;
   function F_CDF (X, DF1, DF2 : Float) return Float;

   --  Binomial
   function Beta_RN  (Alpha, Beta : Float) return Float;
   function Binomial_PMF (K, N, P : Float) return Float;
   function Binomial_CDF (K, N, P : Float) return Float;
   function Binomial_IDF (P, N, Prob : Float) return Float;
   function Binomial_RN  (N, P : Float) return Float;

   --  Weibull
   function Weibull_PDF (X, Scale, Shape : Float) return Float;
   function Weibull_CDF (X, Scale, Shape : Float) return Float;
   function Weibull_RN  (Scale, Shape : Float) return Float;

   -- Laplace (L prefix)
   function Laplace_PDF (X, Location, Scale : Float) return Float;
   function Laplace_CDF (X, Location, Scale : Float) return Float;
   function Laplace_IDF (P, Location, Scale : Float) return Float;
   function Laplace_RN  (Location, Scale : Float) return Float;

   -- Extra Quantiles/RNGs
   function Poisson_IDF   (P, Lambda     : Float) return Float;
   function Chi_Square_IDF (P, DF        : Float) return Float;
   function Student_T_IDF  (P, DF        : Float) return Float;
   function F_IDF          (P, DF1, DF2  : Float) return Float;
   function Gamma_IDF      (P, Shape, Rate : Float) return Float;
   function Weibull_IDF    (P, Shape, Scale : Float) return Float;
   function Chi_Square_RN (DF : Float) return Float;
   function Student_T_RN (DF : Float) return Float;
   function F_RN (DF1, DF2 : Float) return Float;

   procedure Set_Seed (Seed : Integer);
   function  Uniform_Random return Float;  -- Returns uniform [0,1) using the shared generator.

private
   --  Use Long_Float internally for better precision
   type Internal_Float is new Long_Float;

   Generator : Ada.Numerics.Float_Random.Generator;
   Initialized : Boolean := False;

   procedure Ensure_Random_Init;

end SData_Core.Statistics;