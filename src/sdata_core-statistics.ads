--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  Package SData_Core.Statistics provides probability-distribution and
--  random-variate functions for the distributions the interpreter exposes.
--  All values are Float; the bodies compute in Long_Float for precision.
--
--  Naming convention.  Each distribution offers some of these, by suffix:
--    _PDF  probability *density* (continuous distributions)
--    _PMF  probability *mass*    (discrete distributions: Poisson, Binomial)
--    _CDF  cumulative distribution, P(X <= x)
--    _IDF  inverse CDF / quantile: the x for which CDF(x) = p
--    _RN   one pseudo-random variate drawn from the distribution
--
--  Conventions shared across the package:
--    * Random functions draw from a single shared generator.  Call Set_Seed
--      for a reproducible sequence; otherwise the generator seeds itself on
--      first use.  Uniform_Random exposes that generator directly.
--    * Out-of-domain *parameters* raise Constraint_Error (e.g. a non-positive
--      scale/shape, or a probability outside the function's valid range).
--      A density evaluated *outside its support* instead returns 0.0.
--    * Discrete distributions (Poisson, Binomial) floor their count
--      arguments (K, N) to integers.
--    * Parameterisation gotchas worth noting up front: Gamma uses a *rate*
--      (not scale) second shape argument; Weibull_IDF takes its parameters
--      in the opposite order to the other Weibull functions; Binomial_IDF's
--      first argument is a cumulative probability, not the success
--      probability.  Each is flagged again at the declaration below.

with Ada.Numerics;
with Ada.Numerics.Float_Random;

package SData_Core.Statistics is

   --  =======================================================================
   --  Probability Distribution Functions
   --  =======================================================================

   --  Standard Normal (Z) -- mean 0, standard deviation 1.
   function Z_PDF (Z : Float) return Float;            --  Density phi(z).
   function Z_CDF (Z : Float) return Float;            --  CDF Phi(z).
   --  Quantile (probit) Phi^-1(p).  P must lie in the open interval (0,1).
   function Z_IDF (P : Float) return Float;

   --  General Normal(Mean, Std_Dev).  Std_Dev must be positive.
   function Normal_PDF (X, Mean, Std_Dev : Float) return Float;  --  Density.
   function Normal_CDF (X, Mean, Std_Dev : Float) return Float;  --  CDF.
   function Normal_IDF (P, Mean, Std_Dev : Float) return Float;  --  Quantile.
   function Normal_RN  (Mean, Std_Dev : Float) return Float;     --  One variate.

   --  Continuous Uniform on the interval [Lower, Upper].  Requires
   --  Lower < Upper.
   function Uniform_PDF (X, Lower, Upper : Float) return Float;  --  Density.
   function Uniform_CDF (X, Lower, Upper : Float) return Float;  --  CDF.
   function Uniform_IDF (P, Lower, Upper : Float) return Float;  --  Quantile.
   function Uniform_RN  (Lower, Upper : Float) return Float;     --  One variate.

   --  Exponential with rate parameter Rate (= lambda), which must be
   --  positive.  The mean is 1/Rate.
   function Exponential_PDF (X, Rate : Float) return Float;  --  Density.
   function Exponential_CDF (X, Rate : Float) return Float;  --  CDF.
   function Exponential_IDF (P, Rate : Float) return Float;  --  Quantile.
   function Exponential_RN  (Rate : Float) return Float;     --  One variate.

   --  Beta(Alpha, Beta) on [0,1].  Alpha and Beta are shape parameters and
   --  must both be positive.
   function Beta_PDF (X, Alpha, Beta : Float) return Float;  --  Density.
   function Beta_CDF (X, Alpha, Beta : Float) return Float;  --  CDF.
   function Beta_IDF (P, Alpha, Beta : Float) return Float;  --  Quantile.
   function Beta_RN  (Alpha, Beta : Float) return Float;     --  One variate.

   --  Poisson (discrete) with mean Mean (= lambda), which must be positive.
   --  K is floored to an integer count.
   function Poisson_PMF (K, Mean : Float) return Float;  --  Mass P(X = K).
   function Poisson_CDF (K, Mean : Float) return Float;  --  CDF.
   function Poisson_RN  (Mean : Float) return Float;     --  One variate.

   --  Gamma(Alpha, Beta) where Alpha is the shape and Beta is the *rate*
   --  (NOT the scale).  Both must be positive; the mean is Alpha/Beta.
   function Gamma_PDF (X, Alpha, Beta : Float) return Float;  --  Density.
   function Gamma_CDF (X, Alpha, Beta : Float) return Float;  --  CDF.
   function Gamma_RN  (Alpha, Beta : Float) return Float;     --  One variate.

   --  Chi-square with DF degrees of freedom (equivalently Gamma(DF/2, 1/2)).
   function Chi_Square_PDF (X, DF : Float) return Float;  --  Density.
   function Chi_Square_CDF (X, DF : Float) return Float;  --  CDF.

   --  Student's t with DF degrees of freedom.
   function Student_T_PDF (T, DF : Float) return Float;  --  Density.
   function Student_T_CDF (T, DF : Float) return Float;  --  CDF.

   --  Snedecor's F with DF1 (numerator) and DF2 (denominator) degrees of
   --  freedom.
   function F_PDF (X, DF1, DF2 : Float) return Float;  --  Density.
   function F_CDF (X, DF1, DF2 : Float) return Float;  --  CDF.

   --  Binomial (discrete): N trials (floored) each succeeding with
   --  probability P in [0,1]; K is the floored success count.
   function Binomial_PMF (K, N, P : Float) return Float;  --  Mass P(X = K).
   function Binomial_CDF (K, N, P : Float) return Float;  --  CDF.
   --  Quantile.  NOTE the argument roles: P is the cumulative probability
   --  (quantile input) and Prob is the per-trial success probability.
   function Binomial_IDF (P, N, Prob : Float) return Float;
   function Binomial_RN  (N, P : Float) return Float;     --  One variate.

   --  Weibull(Scale, Shape) where Scale = lambda and Shape = k; both must be
   --  positive.  (Weibull_IDF below takes the two in the opposite order.)
   function Weibull_PDF (X, Scale, Shape : Float) return Float;  --  Density.
   function Weibull_CDF (X, Scale, Shape : Float) return Float;  --  CDF.
   function Weibull_RN  (Scale, Shape : Float) return Float;     --  One variate.

   --  Laplace(Location, Scale) where Location is the mean (mu) and Scale is
   --  the positive diversity parameter (b).
   function Laplace_PDF (X, Location, Scale : Float) return Float;  --  Density.
   function Laplace_CDF (X, Location, Scale : Float) return Float;  --  CDF.
   function Laplace_IDF (P, Location, Scale : Float) return Float;  --  Quantile.
   function Laplace_RN  (Location, Scale : Float) return Float;     --  One variate.

   --  Quantiles and random variates added after the blocks above; each
   --  belongs to the distribution named in its identifier.
   function Poisson_IDF    (P, Lambda      : Float) return Float;  --  Poisson quantile.
   function Chi_Square_IDF (P, DF          : Float) return Float;  --  Chi-square quantile.
   function Student_T_IDF  (P, DF          : Float) return Float;  --  Student's t quantile.
   function F_IDF          (P, DF1, DF2    : Float) return Float;  --  F quantile.
   --  Gamma quantile.  Like Gamma_*, the second shape argument is a rate.
   function Gamma_IDF      (P, Shape, Rate : Float) return Float;
   --  Weibull quantile.  CAUTION: Shape and Scale are in the *reverse* order
   --  to Weibull_PDF/CDF/RN, which take (Scale, Shape).
   function Weibull_IDF    (P, Shape, Scale : Float) return Float;
   function Chi_Square_RN (DF : Float) return Float;   --  Chi-square variate.
   function Student_T_RN (DF : Float) return Float;    --  Student's t variate.
   function F_RN (DF1, DF2 : Float) return Float;      --  F variate.

   --  Reseed the shared random generator so the subsequent *_RN / Uniform_Random
   --  sequence is reproducible.  Without this the generator self-seeds on first use.
   procedure Set_Seed (Seed : Integer);
   function  Uniform_Random return Float;  --  Returns uniform [0,1) using the shared generator.

   ------------------------------------------------------------------
   --  Contingency-table tests (SAS PROC FREQ /CHISQ analogue).      --
   --  Pure: take a matrix / vector of counts, return the statistics. --
   ------------------------------------------------------------------
   type Count_Matrix is array (Positive range <>, Positive range <>) of Natural;
   type Count_Vector is array (Positive range <>) of Natural;

   type Chi_Square_Result is record
      Valid             : Boolean := False;
      R, C              : Natural := 0;
      N                 : Natural := 0;
      DF                : Natural := 0;
      Pearson_Stat      : Float := 0.0;   Pearson_P    : Float := 1.0;
      LR_Stat           : Float := 0.0;   LR_P         : Float := 1.0;
      MH_Stat           : Float := 0.0;   MH_P         : Float := 1.0;
      Has_Yates         : Boolean := False;
      Yates_Stat        : Float := 0.0;   Yates_P      : Float := 1.0;
      Phi               : Float := 0.0;
      Contingency       : Float := 0.0;
      Cramers_V         : Float := 0.0;
      Min_Expected      : Float := 0.0;
      Pct_Expected_Lt_5 : Float := 0.0;
   end record;

   type GOF_Result is record
      Valid  : Boolean := False;
      K      : Natural := 0;    --  number of categories
      N      : Natural := 0;
      DF     : Natural := 0;
      Stat   : Float := 0.0;
      P      : Float := 1.0;
   end record;

   --  Chi-square family for an R x C table of observed counts.
   function Chi_Square_Tests (Counts : Count_Matrix) return Chi_Square_Result;

   --  Equal-proportions goodness-of-fit for a one-way count vector.
   function Goodness_Of_Fit (Counts : Count_Vector) return GOF_Result;

private
   --  Use Long_Float internally for better precision
   type Internal_Float is new Long_Float;

   Generator : Ada.Numerics.Float_Random.Generator;
   Initialized : Boolean := False;

   procedure Ensure_Random_Init;

end SData_Core.Statistics;
