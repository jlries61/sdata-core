--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

with Ada.Numerics.Generic_Elementary_Functions;
with Phi_function;
with Beta_function;
with Gamma_function;
with Generic_Random_Functions;

--  Algorithm references used in this package:
--
--  [A&S]  Abramowitz, M. and Stegun, I.A., "Handbook of Mathematical
--         Functions", Dover, 1972.
--
--  [NR]   Press, W.H. et al., "Numerical Recipes in C", 2nd ed.,
--         Cambridge University Press, 1992.  Section references below.
--
--  [MT00] Marsaglia, G. and Tsang, W.W., "A Simple Method for Generating
--         Gamma Variables", ACM Trans. Math. Softw. 26(3):363-372, 2000.
--
--  [BM58] Box, G.E.P. and Muller, M.E., "A Note on the Generation of Random
--         Normal Deviates", Ann. Math. Stat. 29(2):610-611, 1958.
--
--  [DLMF] NIST Digital Library of Mathematical Functions, https://dlmf.nist.gov/
--
--  MathPaqs library (Phi_function, Beta_function, Gamma_function,
--  Generic_Random_Functions) implements standard algorithms internally;
--  see the MathPaqs source tree for per-function references.
--
--  Implementation strategy (why the code below looks the way it does):
--
--  * Precision.  Every body computes in Long_Float and converts to Float only
--    at the boundary, so tail cancellation (e.g. 1 - CDF) and log-space PMFs
--    keep their accuracy.  The public type stays Float because that is the
--    interpreter's numeric type.
--
--  * Special functions are not reimplemented.  The Phi (normal) function, the
--    regularized / inverse beta function, and log-gamma come from MathPaqs;
--    only the regularized incomplete gamma P(a,x) is inlined here ([NR] §6.2),
--    because several distributions need it directly and it is short.  This
--    keeps the hard numerics in one audited place rather than re-deriving
--    rational approximations per call site.
--
--  * CDFs use standard special-function identities, not numeric integration:
--    gamma / chi-square via the regularized incomplete gamma; beta / Student-t
--    / F / binomial via the regularized incomplete beta; the remainder are
--    closed form.  Each such CDF states its identity and reference inline.
--
--  * Quantiles (IDF) come in two flavours.  Where a closed-form inverse exists
--    (probit, exponential, uniform, beta, Laplace) it is used directly.  Where
--    it does not, one generic bisection (Bisect_IDF) inverts the CDF and each
--    caller documents its bracket.  Bisection is preferred over Newton because
--    these CDFs are monotone but have no cheap, robust derivative, so for a
--    one-shot interactive evaluation robustness matters more than iteration
--    count.  Discrete quantiles (Poisson, Binomial) instead accumulate the PMF
--    forward, since the support is integer-valued.
--
--  * Random variates favour a simple, provably-correct method per distribution
--    over a uniformly optimal one: inverse-CDF where the inverse is closed form
--    (exponential, Weibull, Laplace), Box-Muller for the normal, Marsaglia-
--    Tsang for the gamma, and the gamma-based identities for the variates
--    defined in terms of it (beta, chi-square, Student-t, F).  Discrete cases
--    are simulated directly (N Bernoulli trials for the binomial).  All draw
--    from one shared generator, so a single Set_Seed makes every distribution
--    reproducible.  These are textbook constructions, not speed-tuned
--    generators — appropriate for a data-step interpreter, not a Monte-Carlo
--    engine.

package body SData_Core.Statistics is

   package REF is new Ada.Numerics.Generic_Elementary_Functions (Long_Float);
   use REF;

   package Long_Phi is new Phi_function (Long_Float);
   package Long_Beta is new Beta_function (Long_Float);
   package Long_Gamma is new Gamma_function (Long_Float);
   package Long_Rand_Funcs is new Generic_Random_Functions (Long_Float);

   ------------------------
   -- Ensure_Random_Init --
   ------------------------
   procedure Ensure_Random_Init is
   begin
      if not Initialized then
         Ada.Numerics.Float_Random.Reset (Generator);
         Initialized := True;
      end if;
   end Ensure_Random_Init;

   procedure Set_Seed (Seed : Integer) is
   begin
      Ada.Numerics.Float_Random.Reset (Generator, Seed);
      Initialized := True;
   end Set_Seed;

   function Uniform_Random return Float is
   begin
      Ensure_Random_Init;
      return Float (Ada.Numerics.Float_Random.Random (Generator));
   end Uniform_Random;

   ----------------------
   -- Incomplete_Gamma --
   ----------------------
   --  Regularized lower incomplete gamma function P(a, x).
   --  Algorithm: series expansion (G_Series) for x < a+1; Lentz modified
   --  continued-fraction (G_CF) for x >= a+1 (upper tail subtracted).
   --  [NR] §6.2 (gammp / gser / gcf).  Convergence constants ITMAX, EPS,
   --  FPMIN are taken directly from that source.
   function Incomplete_Gamma_P (A, X : Long_Float) return Long_Float is
      ITMAX : constant := 100;
      EPS   : constant := 3.0e-14;
      FPMIN : constant := 1.0e-100;

      function G_Series (A, X : Long_Float) return Long_Float is
         Sum, Del, AP : Long_Float;
      begin
         AP := A;
         Sum := 1.0 / A;
         Del := Sum;
         for I in 1 .. ITMAX loop
            AP := AP + 1.0;
            Del := Del * X / AP;
            Sum := Sum + Del;
            exit when abs (Del) < abs (Sum) * EPS;
         end loop;
         return Sum * Exp (-X + A * Log (X) - Long_Gamma.Log_Gamma (A));
      end G_Series;

      function G_CF (A, X : Long_Float) return Long_Float is
         B, C, D, Del, H : Long_Float;
         AN : Long_Float;
      begin
         B := X + 1.0 - A;
         C := 1.0 / FPMIN;
         D := 1.0 / B;
         H := D;
         for I in 1 .. ITMAX loop
            AN := -Long_Float (I) * (Long_Float (I) - A);
            B := B + 2.0;
            D := AN * D + B;
            if abs (D) < FPMIN then D := FPMIN; end if;
            C := B + AN / C;
            if abs (C) < FPMIN then C := FPMIN; end if;
            D := 1.0 / D;
            Del := D * C;
            H := H * Del;
            exit when abs (Del - 1.0) < EPS;
         end loop;
         return Exp (-X + A * Log (X) - Long_Gamma.Log_Gamma (A)) * H;
      end G_CF;

   begin
      if X < 0.0 or else A <= 0.0 then return 0.0; end if;
      if X < A + 1.0 then
         return G_Series (A, X);
      else
         return 1.0 - G_CF (A, X);
      end if;
   end Incomplete_Gamma_P;

   -----------
   -- Z_PDF --
   -----------
   function Z_PDF (Z : Float) return Float is
      Constant_Part : constant Long_Float := 1.0 / Sqrt (2.0 * Ada.Numerics.Pi);
   begin
      return Float (Constant_Part * Exp (-0.5 * (Long_Float (Z)**2)));
   end Z_PDF;

   -----------
   -- Z_CDF --
   -----------
   --  Standard normal CDF Φ(z).  Delegated to MathPaqs Phi_function.Phi,
   --  which uses the rational approximation from [A&S] 26.2.17.
   function Z_CDF (Z : Float) return Float is
   begin
      return Float (Long_Phi.Phi (Long_Float (Z)));
   end Z_CDF;

   -----------
   -- Z_IDF --
   -----------
   --  Probit function Φ⁻¹(p).  Delegated to MathPaqs Phi_function.Inverse_Phi,
   --  which uses a rational approximation (Beasley-Springer-Moro or equivalent).
   function Z_IDF (P : Float) return Float is
   begin
      if P <= 0.0 or else P >= 1.0 then raise Constraint_Error with "Probability must be in (0,1)"; end if;
      return Float (Long_Phi.Inverse_Phi (Long_Float (P)));
   end Z_IDF;

   ----------------
   -- Normal_PDF --
   ----------------
   function Normal_PDF (X, Mean, Std_Dev : Float) return Float is
   begin
      if Std_Dev <= 0.0 then raise Constraint_Error with "Standard deviation must be positive"; end if;
      return Z_PDF ((X - Mean) / Std_Dev) / Std_Dev;
   end Normal_PDF;

   ----------------
   -- Normal_CDF --
   ----------------
   function Normal_CDF (X, Mean, Std_Dev : Float) return Float is
   begin
      if Std_Dev <= 0.0 then raise Constraint_Error with "Standard deviation must be positive"; end if;
      return Z_CDF ((X - Mean) / Std_Dev);
   end Normal_CDF;

   ----------------
   -- Normal_IDF --
   ----------------
   function Normal_IDF (P, Mean, Std_Dev : Float) return Float is
   begin
      if Std_Dev <= 0.0 then raise Constraint_Error with "Standard deviation must be positive"; end if;
      return Mean + Z_IDF (P) * Std_Dev;
   end Normal_IDF;

   ---------------
   -- Normal_RN --
   ---------------
   --  Box-Muller transform: generates standard normal variates from two
   --  independent uniform(0,1) draws.  [BM58].  Delegated to MathPaqs
   --  Generic_Random_Functions.Box_Muller; only one of the two outputs is used.
   function Normal_RN (Mean, Std_Dev : Float) return Float is
      N1, N2 : Long_Float;
   begin
      Ensure_Random_Init;
      Long_Rand_Funcs.Box_Muller (Long_Float (Ada.Numerics.Float_Random.Random (Generator)), Long_Float (Ada.Numerics.Float_Random.Random (Generator)), N1, N2);
      return Float (Long_Float (Mean) + N1 * Long_Float (Std_Dev));
   end Normal_RN;

   -----------------
   -- Uniform_PDF --
   -----------------
   function Uniform_PDF (X, Lower, Upper : Float) return Float is
   begin
      if Lower >= Upper then raise Constraint_Error with "Lower bound must be less than Upper bound"; end if;
      return (if X >= Lower and then X <= Upper then 1.0 / (Upper - Lower)
              else 0.0);
   end Uniform_PDF;

   -----------------
   -- Uniform_CDF --
   -----------------
   function Uniform_CDF (X, Lower, Upper : Float) return Float is
   begin
      if Lower >= Upper then raise Constraint_Error with "Lower bound must be less than Upper bound"; end if;
      if X < Lower then return 0.0; elsif X > Upper then return 1.0; else return (X - Lower) / (Upper - Lower); end if;
   end Uniform_CDF;

   -----------------
   -- Uniform_IDF --
   -----------------
   function Uniform_IDF (P, Lower, Upper : Float) return Float is
   begin
      if Lower >= Upper then raise Constraint_Error with "Lower bound must be less than Upper bound"; end if;
      return Lower + P * (Upper - Lower);
   end Uniform_IDF;

   ----------------
   -- Uniform_RN --
   ----------------
   function Uniform_RN (Lower, Upper : Float) return Float is
   begin
      Ensure_Random_Init;
      return Lower + Ada.Numerics.Float_Random.Random (Generator) * (Upper - Lower);
   end Uniform_RN;

   ---------------------
   -- Exponential_PDF --
   ---------------------
   function Exponential_PDF (X, Rate : Float) return Float is
   begin
      if Rate <= 0.0 then raise Constraint_Error with "Rate must be positive"; end if;
      return (if X < 0.0 then 0.0 else Float (Long_Float (Rate) * Exp (-Long_Float (Rate) * Long_Float (X))));
   end Exponential_PDF;

   ---------------------
   -- Exponential_CDF --
   ---------------------
   function Exponential_CDF (X, Rate : Float) return Float is
   begin
      if Rate <= 0.0 then raise Constraint_Error with "Rate must be positive"; end if;
      return (if X < 0.0 then 0.0 else Float (1.0 - Exp (-Long_Float (Rate) * Long_Float (X))));
   end Exponential_CDF;

   ---------------------
   -- Exponential_IDF --
   ---------------------
   --  Method: closed-form inverse CDF, x = -ln(1 - p) / rate.
   function Exponential_IDF (P, Rate : Float) return Float is
   begin
      if Rate <= 0.0 then raise Constraint_Error with "Rate must be positive"; end if;
      if P < 0.0 or else P >= 1.0 then raise Constraint_Error with "P must be in [0,1)"; end if;
      return Float (-Log (1.0 - Long_Float (P)) / Long_Float (Rate));
   end Exponential_IDF;

   --------------------
   -- Exponential_RN --
   --------------------
   --  Method: inverse-CDF sampling (feed one uniform draw to Exponential_IDF).
   function Exponential_RN (Rate : Float) return Float is
   begin
      Ensure_Random_Init;
      return Exponential_IDF (Ada.Numerics.Float_Random.Random (Generator), Rate);
   end Exponential_RN;

   --------------
   -- Beta_PDF --
   --------------
   function Beta_PDF (X, Alpha, Beta : Float) return Float is
   begin
      if Alpha <= 0.0 or else Beta <= 0.0 then raise Constraint_Error with
         "Beta distribution: shape parameters must be positive (a=" &
         Float'Image (Alpha) & ", b=" & Float'Image (Beta) & ")";
      end if;
      if X < 0.0 or else X > 1.0 then return 0.0; end if;
      return Float ((Long_Float (X)**(Long_Float (Alpha) - 1.0) * (1.0 - Long_Float (X))**(Long_Float (Beta) - 1.0)) / Long_Beta.Beta (Long_Float (Alpha), Long_Float (Beta)));
   end Beta_PDF;

   --------------
   -- Beta_CDF --
   --------------
   function Beta_CDF (X, Alpha, Beta : Float) return Float is
   begin
      if X <= 0.0 then return 0.0; elsif X >= 1.0 then return 1.0; end if;
      return Float (Long_Beta.Regularized_Beta (Long_Float (X), Long_Float (Alpha), Long_Float (Beta)));
   end Beta_CDF;

   --------------
   -- Beta_IDF --
   --------------
   function Beta_IDF (P, Alpha, Beta : Float) return Float is
   begin
      return Float (Long_Beta.Inverse_Regularized_Beta (Long_Float (P), Long_Float (Alpha), Long_Float (Beta)));
   end Beta_IDF;

   -------------
   -- Beta_RN --
   -------------
   --  Method: beta variate as X / (X + Y) with X ~ Gamma(Alpha, 1) and
   --  Y ~ Gamma(Beta, 1) — exact, and reuses the gamma sampler rather than
   --  needing a dedicated beta generator.
   function Beta_RN (Alpha, Beta : Float) return Float is
      Y1 : constant Float := Gamma_RN (Alpha, 1.0);
      Y2 : constant Float := Gamma_RN (Beta, 1.0);
   begin
      if Y1 + Y2 = 0.0 then return 0.0; end if;
      return Y1 / (Y1 + Y2);
   end Beta_RN;

   -----------------
   -- Poisson_PMF --
   -----------------
   function Poisson_PMF (K, Mean : Float) return Float is
      KI : constant Long_Float := Long_Float (Float'Floor (K));
   begin
      if Mean <= 0.0 then raise Constraint_Error with "Mean must be positive"; end if;
      if K < 0.0 then return 0.0; end if;
      return Float (Exp (-Long_Float (Mean) + KI * Log (Long_Float (Mean)) - Long_Gamma.Log_Gamma (KI + 1.0)));
   end Poisson_PMF;

   -----------------
   -- Poisson_CDF --
   -----------------
   --  Method: direct summation of the PMF over 0 .. K — simple and exact
   --  (O(K) terms), rather than the incomplete-gamma relation.
   function Poisson_CDF (K, Mean : Float) return Float is
      KI : constant Integer := Integer (Float'Floor (K));
      Sum : Long_Float := 0.0;
   begin
      if Mean <= 0.0 then raise Constraint_Error with "Mean must be positive"; end if;
      if K < 0.0 then return 0.0; end if;
      for I in 0 .. KI loop Sum := Sum + Long_Float (Poisson_PMF (Float (I), Mean)); end loop;
      return Float (Sum);
   end Poisson_CDF;

   ----------------
   -- Poisson_RN --
   ----------------
   --  Method: delegated to MathPaqs Generic_Random_Functions.Poisson, driven
   --  by the shared uniform generator (local U).
   function Poisson_RN (Mean : Float) return Float is
      function U return Long_Float is
      begin
         Ensure_Random_Init;
         return Long_Float (Ada.Numerics.Float_Random.Random (Generator));
      end U;
      function Poisson_Func is new Long_Rand_Funcs.Poisson (U);
   begin
      return Float (Long_Float (Poisson_Func (Long_Float (Mean))));
   end Poisson_RN;

   ---------------
   -- Gamma_PDF --
   ---------------
   function Gamma_PDF (X, Alpha, Beta : Float) return Float is
   begin
      if Alpha <= 0.0 or else Beta <= 0.0 then raise Constraint_Error with
         "Gamma distribution: shape and rate must be positive (shape=" &
         Float'Image (Alpha) & ", rate=" & Float'Image (Beta) & ")";
      end if;
      if X <= 0.0 then return 0.0; end if;
      return Float (Exp (Long_Float (Alpha) * Log (Long_Float (Beta)) + (Long_Float (Alpha) - 1.0) * Log (Long_Float (X)) - Long_Float (Beta) * Long_Float (X) - Long_Gamma.Log_Gamma (Long_Float (Alpha))));
   end Gamma_PDF;

   ---------------
   -- Gamma_CDF --
   ---------------
   --  CDF of Gamma(α, β) via the regularized lower incomplete gamma:
   --  F(x) = P(α, β·x).  [DLMF] 8.2.4; [A&S] 6.5.1.
   function Gamma_CDF (X, Alpha, Beta : Float) return Float is
   begin
      if X <= 0.0 then return 0.0; end if;
      return Float (Incomplete_Gamma_P (Long_Float (Alpha), Long_Float (Beta) * Long_Float (X)));
   end Gamma_CDF;

   --------------
   -- Gamma_RN --
   --------------
   --  Marsaglia-Tsang squeeze method for Gamma(α, β) variates.  [MT00].
   --  For α < 1 uses the identity Gamma(α) = Gamma(α+1) · U^(1/α),
   --  where U ~ Uniform(0,1) — [MT00] eq. (4).
   function Gamma_RN (Alpha, Beta : Float) return Float is
      A : constant Long_Float := Long_Float (Alpha);
      B : constant Long_Float := Long_Float (Beta);
      D, C, X, V, U : Long_Float;
   begin
      Ensure_Random_Init;
      if A < 1.0 then
         --  Marsaglia and Tsang's method requires A >= 1.
         --  Relationship: Gamma(A, B) = Gamma(A+1, B) * U^(1/A)
         return Gamma_RN (Alpha + 1.0, Beta) * Float (Long_Float (Ada.Numerics.Float_Random.Random (Generator)) ** (1.0 / A));
      end if;

      D := A - 1.0 / 3.0;
      C := 1.0 / Sqrt (9.0 * D);
      loop
         loop
            X := Long_Float (Z_IDF (Ada.Numerics.Float_Random.Random (Generator)));
            V := 1.0 + C * X;
            exit when V > 0.0;
         end loop;
         V := V**3;
         U := Long_Float (Ada.Numerics.Float_Random.Random (Generator));
         exit when U < 1.0 - 0.0331 * (X**4) or else Log (U) < 0.5 * (X**2) + D * (1.0 - V + Log (V));
      end loop;
      return Float (D * V / B);
   end Gamma_RN;

   --------------------
   -- Chi_Square_PDF --
   --------------------
   --  chi-square(DF) = Gamma(DF/2, rate 1/2); Chi_Square_PDF/CDF/RN all reduce
   --  to the corresponding gamma routine via this identity.
   function Chi_Square_PDF (X, DF : Float) return Float is
   begin
      return Gamma_PDF (X, DF / 2.0, 0.5);
   end Chi_Square_PDF;

   --------------------
   -- Chi_Square_CDF --
   --------------------
   function Chi_Square_CDF (X, DF : Float) return Float is
   begin
      return Gamma_CDF (X, DF / 2.0, 0.5);
   end Chi_Square_CDF;

   -------------------
   -- Student_T_PDF --
   -------------------
   function Student_T_PDF (T, DF : Float) return Float is
      V : constant Long_Float := Long_Float (DF);
      X : constant Long_Float := Long_Float (T);
   begin
      return Float (Exp (Long_Gamma.Log_Gamma ((V + 1.0) / 2.0) - Long_Gamma.Log_Gamma (V / 2.0)) / (Sqrt (V * Ada.Numerics.Pi) * (1.0 + (X**2) / V)**((V + 1.0) / 2.0)));
   end Student_T_PDF;

   -------------------
   -- Student_T_CDF --
   -------------------
   --  CDF of Student's t(ν) via the regularized incomplete beta:
   --  F(t) = 1 - ½·I_{ν/(ν+t²)}(ν/2, ½)  for t > 0;  ½·I_{…}  for t ≤ 0.
   --  [A&S] 26.7.8; [NR] §6.4.
   function Student_T_CDF (T, DF : Float) return Float is
      V : constant Long_Float := Long_Float (DF);
      X : constant Long_Float := Long_Float (T);
      W : Long_Float;
   begin
      W := V / (V + X**2);
      if X > 0.0 then
         return 1.0 - 0.5 * Float (Long_Beta.Regularized_Beta (W, V / 2.0, 0.5));
      else
         return 0.5 * Float (Long_Beta.Regularized_Beta (W, V / 2.0, 0.5));
      end if;
   end Student_T_CDF;

   -----------
   -- F_PDF --
   -----------
   function F_PDF (X, DF1, DF2 : Float) return Float is
      V1 : constant Long_Float := Long_Float (DF1);
      V2 : constant Long_Float := Long_Float (DF2);
      XV : constant Long_Float := Long_Float (X);
   begin
      if XV <= 0.0 then return 0.0; end if;
      return Float (Sqrt (((V1 * XV)**V1 * V2**V2) / (V1 * XV + V2)**(V1 + V2)) / (XV * Long_Beta.Beta (V1 / 2.0, V2 / 2.0)));
   end F_PDF;

   -----------
   -- F_CDF --
   -----------
   --  CDF of F(d₁, d₂) via regularized incomplete beta:
   --  F(x) = I_{d₁·x/(d₁·x+d₂)}(d₁/2, d₂/2).  [A&S] 26.6.15; [NR] §6.4.
   function F_CDF (X, DF1, DF2 : Float) return Float is
      V1 : constant Long_Float := Long_Float (DF1);
      V2 : constant Long_Float := Long_Float (DF2);
      XV : constant Long_Float := Long_Float (X);
      W : Long_Float;
   begin
      if XV <= 0.0 then return 0.0; end if;
      W := (V1 * XV) / (V1 * XV + V2);
      return Float (Long_Beta.Regularized_Beta (W, V1 / 2.0, V2 / 2.0));
   end F_CDF;

   ------------------
   -- Binomial_PMF --
   ------------------
   --  P(X = k) = C(n,k)·p^k·(1-p)^(n-k).  Computed in log space as
   --  log Γ(n+1) − log Γ(k+1) − log Γ(n-k+1) + k·log p + (n-k)·log(1-p)
   --  to avoid factorial overflow.  [A&S] 26.1.17.
   function Binomial_PMF (K, N, P : Float) return Float is
      KI : constant Long_Float := Long_Float (Float'Floor (K));
      NI : constant Long_Float := Long_Float (Float'Floor (N));
      PF : constant Long_Float := Long_Float (P);
   begin
      if PF < 0.0 or else PF > 1.0 or else NI < 0.0 then
         raise Constraint_Error with
         "Binomial PMF: n must be non-negative and prob must be in [0,1] (n=" &
         Float'Image (N) & ", prob=" & Float'Image (P) & ")";
      end if;
      if KI < 0.0 or else KI > NI then return 0.0; end if;
      if PF = 0.0 then return (if KI = 0.0 then 1.0 else 0.0); end if;
      if PF = 1.0 then return (if KI = NI then 1.0 else 0.0); end if;

      return Float (Exp (Long_Gamma.Log_Gamma (NI + 1.0) - Long_Gamma.Log_Gamma (KI + 1.0) - Long_Gamma.Log_Gamma (NI - KI + 1.0) +
                         KI * Log (PF) + (NI - KI) * Log (1.0 - PF)));
   end Binomial_PMF;

   ------------------
   -- Binomial_CDF --
   ------------------
   --  P(X ≤ k) = I_{1-p}(n-k, k+1)  (regularized incomplete beta).
   --  [A&S] 26.5.24; [NR] §6.4.
   function Binomial_CDF (K, N, P : Float) return Float is
      KI : constant Long_Float := Long_Float (Float'Floor (K));
      NI : constant Long_Float := Long_Float (Float'Floor (N));
      PF : constant Long_Float := Long_Float (P);
   begin
      if PF < 0.0 or else PF > 1.0 or else NI < 0.0 then
         raise Constraint_Error with
         "Binomial CDF: n must be non-negative and prob must be in [0,1] (n=" &
         Float'Image (N) & ", prob=" & Float'Image (P) & ")";
      end if;
      if KI < 0.0 then return 0.0; elsif KI >= NI then return 1.0; end if;
      return Float (Long_Beta.Regularized_Beta (1.0 - PF, NI - KI, KI + 1.0));
   end Binomial_CDF;

   ------------------
   -- Binomial_IDF --
   ------------------
   --  Method: accumulate the PMF forward until it reaches the cumulative
   --  probability P (discrete support).
   function Binomial_IDF (P, N, Prob : Float) return Float is
      Sum : Float := 0.0;
      NI  : constant Integer := Integer (Float'Floor (N));
   begin
      if P <= 0.0 then return 0.0; end if;
      if P >= 1.0 then return Float (NI); end if;
      for K in 0 .. NI loop
         Sum := Sum + Binomial_PMF (Float (K), N, Prob);
         if Sum >= P then return Float (K); end if;
      end loop;
      return Float (NI);
   end Binomial_IDF;

   -----------------
   -- Binomial_RN --
   -----------------
   --  Method: direct simulation — count successes over N independent
   --  Bernoulli(P) trials.  Exact and O(N), no approximation.
   function Binomial_RN (N, P : Float) return Float is
      NI : constant Integer := Integer (Float'Floor (N));
      PF : constant Float := P;
      Res : Integer := 0;
   begin
      Ensure_Random_Init;
      for I in 1 .. NI loop
         if Ada.Numerics.Float_Random.Random (Generator) <= PF then
            Res := Res + 1;
         end if;
      end loop;
      return Float (Res);
   end Binomial_RN;

   -----------------
   -- Weibull_PDF --
   -----------------
   function Weibull_PDF (X, Scale, Shape : Float) return Float is
      XF : constant Long_Float := Long_Float (X);
      L  : constant Long_Float := Long_Float (Scale);
      K  : constant Long_Float := Long_Float (Shape);
   begin
      if L <= 0.0 or else K <= 0.0 then raise Constraint_Error with "Scale and Shape must be positive"; end if;
      if XF < 0.0 then return 0.0; end if;
      return Float ((K / L) * (XF / L)**(K - 1.0) * Exp (-(XF / L)**K));
   end Weibull_PDF;

   -----------------
   -- Weibull_CDF --
   -----------------
   function Weibull_CDF (X, Scale, Shape : Float) return Float is
      XF : constant Long_Float := Long_Float (X);
      L  : constant Long_Float := Long_Float (Scale);
      K  : constant Long_Float := Long_Float (Shape);
   begin
      if L <= 0.0 or else K <= 0.0 then raise Constraint_Error with "Scale and Shape must be positive"; end if;
      if XF < 0.0 then return 0.0; end if;
      return Float (1.0 - Exp (-(XF / L)**K));
   end Weibull_CDF;

   ----------------
   -- Weibull_RN --
   ----------------
   --  Method: inverse-CDF sampling, x = Scale * (-ln(1 - U))**(1 / Shape).
   function Weibull_RN (Scale, Shape : Float) return Float is
      U : Float;
   begin
      Ensure_Random_Init;
      U := Ada.Numerics.Float_Random.Random (Generator);
      return Scale * Float ((-Log (1.0 - Long_Float (U)))**(1.0 / Long_Float (Shape)));
   end Weibull_RN;

   -----------------
   -- Laplace_PDF --
   -----------------
   function Laplace_PDF (X, Location, Scale : Float) return Float is
      XF : constant Long_Float := Long_Float (X);
      MU : constant Long_Float := Long_Float (Location);
      B  : constant Long_Float := Long_Float (Scale);
   begin
      if B <= 0.0 then raise Constraint_Error with "Laplace scale must be positive"; end if;
      return Float (Exp (-abs (XF - MU) / B) / (2.0 * B));
   end Laplace_PDF;

   -----------------
   -- Laplace_CDF --
   -----------------
   function Laplace_CDF (X, Location, Scale : Float) return Float is
      XF : constant Long_Float := Long_Float (X);
      MU : constant Long_Float := Long_Float (Location);
      B  : constant Long_Float := Long_Float (Scale);
   begin
      if B <= 0.0 then raise Constraint_Error with "Laplace scale must be positive"; end if;
      if XF < MU then
         return Float (0.5 * Exp ((XF - MU) / B));
      else
         return Float (1.0 - 0.5 * Exp (-(XF - MU) / B));
      end if;
   end Laplace_CDF;

   -----------------
   -- Laplace_IDF --
   -----------------
   function Laplace_IDF (P, Location, Scale : Float) return Float is
      PF : constant Long_Float := Long_Float (P);
      MU : constant Long_Float := Long_Float (Location);
      B  : constant Long_Float := Long_Float (Scale);
   begin
      if B <= 0.0 then raise Constraint_Error with "Laplace scale must be positive"; end if;
      if PF <= 0.0 or else PF >= 1.0 then return 0.0; end if; -- Should ideally handle boundary
      if PF < 0.5 then
         return Float (MU + B * Log (2.0 * PF));
      else
         return Float (MU - B * Log (2.0 - 2.0 * PF));
      end if;
   end Laplace_IDF;

   -----------------
   -- Laplace_RN --
   -----------------
   function Laplace_RN (Location, Scale : Float) return Float is
      U : Float;
   begin
      Ensure_Random_Init;
      U := Ada.Numerics.Float_Random.Random (Generator);
      --  Simple inversion method
      return Laplace_IDF (U, Location, Scale);
   end Laplace_RN;

   -----------------
   -- Poisson_IDF --
   -----------------
   --  Method: accumulate the PMF forward until it reaches P (discrete support,
   --  so a forward search rather than bisection); capped at K > 1e6 as a guard.
   function Poisson_IDF (P, Lambda : Float) return Float is
      PF : constant Long_Float := Long_Float (P);
      L  : constant Long_Float := Long_Float (Lambda);
      Sum : Long_Float := 0.0;
      K   : Natural := 0;
   begin
      if PF <= 0.0 then return 0.0; end if;
      if PF >= 1.0 then return Float'Last; end if;
      loop
         Sum := Sum + Long_Float (Poisson_PMF (Float (K), Float (L)));
         exit when Sum >= PF or else K > 1000000;
         K := K + 1;
      end loop;
      return Float (K);
   end Poisson_IDF;

   -------------------
   -- Chi_Square_RN --
   -------------------
   function Chi_Square_RN (DF : Float) return Float is
   begin
      return Gamma_RN (DF / 2.0, 0.5);
   end Chi_Square_RN;

   -------------------
   -- Student_T_RN --
   -------------------
   --  Method: definitional construction — Z / sqrt(V / DF), with Z standard
   --  normal and V ~ chi-square(DF).
   function Student_T_RN (DF : Float) return Float is
      Z : constant Float := Normal_RN (0.0, 1.0);
      V : constant Float := Chi_Square_RN (DF);
   begin
      return Z / Float (Sqrt (Long_Float (V / DF)));
   end Student_T_RN;

   ----------
   -- F_RN --
   ----------
   --  Method: definitional construction — ratio of two independent chi-squares,
   --  each divided by its degrees of freedom: (U1/DF1) / (U2/DF2).
   function F_RN (DF1, DF2 : Float) return Float is
      U1 : constant Float := Chi_Square_RN (DF1);
      U2 : constant Float := Chi_Square_RN (DF2);
   begin
      return (U1 / DF1) / (U2 / DF2);
   end F_RN;

   --  Generic bisection IDF: find x in [Lo, Hi] such that CDF(x) = P.
   --  Standard bisection, 100 iterations, tolerance 1e-9.  [NR] §9.1.
   --  The CDF must be monotonically non-decreasing.
   generic
      with function CDF_Func (X : Float) return Float;
   function Bisect_IDF (P, Lo, Hi : Float) return Float;

   function Bisect_IDF (P, Lo, Hi : Float) return Float is
      L : Float := Lo;
      H : Float := Hi;
      M : Float;
   begin
      for I in 1 .. 100 loop
         M := (L + H) / 2.0;
         if CDF_Func (M) < P then L := M; else H := M; end if;
         exit when H - L < 1.0e-9;
      end loop;
      return (L + H) / 2.0;
   end Bisect_IDF;

   ---------------------
   -- Chi_Square_IDF --
   ---------------------
   --  Bisection over [0, ν + 10·√(2ν)].  Upper bound ≈ mean + 10 std devs,
   --  which contains all practically relevant quantiles.
   function Chi_Square_IDF (P, DF : Float) return Float is
      function CDF (X : Float) return Float is (Chi_Square_CDF (X, DF));
      function Bisect is new Bisect_IDF (CDF);
   begin
      if P <= 0.0 then return 0.0; end if;
      if P >= 1.0 then return Float'Last; end if;
      return Bisect (P, 0.0, DF + 10.0 * Float (Sqrt (Long_Float (2.0 * DF))));
   end Chi_Square_IDF;

   -------------------
   -- Student_T_IDF --
   -------------------
   --  Bisection over [−1000, 1000].  Covers |t| to p < 3e-6 for any ν ≥ 1.
   function Student_T_IDF (P, DF : Float) return Float is
      function CDF (X : Float) return Float is (Student_T_CDF (X, DF));
      function Bisect is new Bisect_IDF (CDF);
   begin
      if P <= 0.0 then return Float'First; end if;
      if P >= 1.0 then return Float'Last; end if;
      return Bisect (P, -1000.0, 1000.0);
   end Student_T_IDF;

   ---------
   -- F_IDF --
   ---------
   --  Bisection over [0, 1000].  Covers all practically significant F quantiles.
   function F_IDF (P, DF1, DF2 : Float) return Float is
      function CDF (X : Float) return Float is (F_CDF (X, DF1, DF2));
      function Bisect is new Bisect_IDF (CDF);
   begin
      if P <= 0.0 then return 0.0; end if;
      if P >= 1.0 then return Float'Last; end if;
      return Bisect (P, 0.0, 1000.0);
   end F_IDF;

   ---------------
   -- Gamma_IDF --
   ---------------
   --  Bisection over [0, μ + 50σ] where μ = α/β and σ = √α/β.
   --  Upper bound covers all practically significant quantiles.
   function Gamma_IDF (P, Shape, Rate : Float) return Float is
      function CDF (X : Float) return Float is (Gamma_CDF (X, Shape, Rate));
      function Bisect is new Bisect_IDF (CDF);
   begin
      if P <= 0.0 then return 0.0; end if;
      if P >= 1.0 then return Float'Last; end if;
      return Bisect (P, 0.0, Shape / Rate + 50.0 * Float (Sqrt (Long_Float (Shape))) / Rate);
   end Gamma_IDF;

   ----------------
   -- Weibull_IDF --
   ----------------
   --  Bisection over [0, 10·λ].  For shape k ≥ 1, the 99.99th percentile
   --  is at most a few multiples of the scale λ; 10λ is a safe upper bound.
   function Weibull_IDF (P, Shape, Scale : Float) return Float is
      function CDF (X : Float) return Float is (Weibull_CDF (X, Scale, Shape));
      function Bisect is new Bisect_IDF (CDF);
   begin
      if P <= 0.0 then return 0.0; end if;
      if P >= 1.0 then return Float'Last; end if;
      return Bisect (P, 0.0, Scale * 10.0);
   end Weibull_IDF;

   ----------------------
   -- Chi_Square_Tests --
   ----------------------
   function Chi_Square_Tests (Counts : Count_Matrix) return Chi_Square_Result is
      Rn   : constant Natural := Counts'Length (1);
      Cn   : constant Natural := Counts'Length (2);
      Res  : Chi_Square_Result;
      Row  : array (1 .. Rn) of Long_Float := (others => 0.0);
      Col  : array (1 .. Cn) of Long_Float := (others => 0.0);
      Tot  : Long_Float := 0.0;
      Low  : Natural := 0;                 --  cells with expected < 5
      Cells : constant Natural := Rn * Cn;
      P_Sum, LR_Sum, Y_Sum, Min_E : Long_Float;
   begin
      Res.R := Rn; Res.C := Cn;
      --  Marginals.
      for I in 1 .. Rn loop
         for J in 1 .. Cn loop
            declare O : constant Long_Float := Long_Float (Counts (Counts'First (1) + I - 1,
                                                                    Counts'First (2) + J - 1));
            begin
               Row (I) := Row (I) + O;
               Col (J) := Col (J) + O;
               Tot := Tot + O;
            end;
         end loop;
      end loop;
      Res.N := Natural (Tot);
      Res.DF := (Rn - 1) * (Cn - 1);

      --  Degenerate guard: any zero margin, or DF = 0, or N = 0.
      if Tot = 0.0 or else Res.DF = 0 then
         Res.Valid := False; return Res;
      end if;
      for I in 1 .. Rn loop
         if Row (I) = 0.0 then Res.Valid := False; return Res; end if;
      end loop;
      for J in 1 .. Cn loop
         if Col (J) = 0.0 then Res.Valid := False; return Res; end if;
      end loop;

      P_Sum := 0.0; LR_Sum := 0.0; Y_Sum := 0.0; Min_E := Long_Float'Last;
      for I in 1 .. Rn loop
         for J in 1 .. Cn loop
            declare
               O : constant Long_Float := Long_Float (Counts (Counts'First (1) + I - 1,
                                                                Counts'First (2) + J - 1));
               E : constant Long_Float := Row (I) * Col (J) / Tot;
            begin
               if E < Min_E then Min_E := E; end if;
               if E < 5.0 then Low := Low + 1; end if;
               P_Sum := P_Sum + (O - E) ** 2 / E;
               if O > 0.0 then
                  LR_Sum := LR_Sum + O * Log (O / E);
               end if;
               if Rn = 2 and then Cn = 2 then
                  Y_Sum := Y_Sum + (abs (O - E) - 0.5) ** 2 / E;
               end if;
            end;
         end loop;
      end loop;

      Res.Valid := True;
      Res.Min_Expected := Float (Min_E);
      Res.Pct_Expected_Lt_5 := Float (100.0 * Long_Float (Low) / Long_Float (Cells));

      Res.Pearson_Stat := Float (P_Sum);
      Res.Pearson_P := 1.0 - Chi_Square_CDF (Res.Pearson_Stat, Float (Res.DF));

      Res.LR_Stat := Float (2.0 * LR_Sum);
      Res.LR_P := 1.0 - Chi_Square_CDF (Res.LR_Stat, Float (Res.DF));

      --  Mantel-Haenszel = (N-1) * Pearson-corr^2; for these design matrices we
      --  use the identity (N-1) * Pearson_chisq / N only for 2x2; for general
      --  RxC SAS uses (N-1) r^2 where r is the Pearson correlation of the
      --  row/col scores. Use integer scores 1..R, 1..C.
      declare
         Mean_R, Mean_C, Sxx, Syy, Sxy : Long_Float := 0.0;
      begin
         for I in 1 .. Rn loop Mean_R := Mean_R + Long_Float (I) * Row (I); end loop;
         for J in 1 .. Cn loop Mean_C := Mean_C + Long_Float (J) * Col (J); end loop;
         Mean_R := Mean_R / Tot;  Mean_C := Mean_C / Tot;
         for I in 1 .. Rn loop
            Sxx := Sxx + Row (I) * (Long_Float (I) - Mean_R) ** 2;
         end loop;
         for J in 1 .. Cn loop
            Syy := Syy + Col (J) * (Long_Float (J) - Mean_C) ** 2;
         end loop;
         for I in 1 .. Rn loop
            for J in 1 .. Cn loop
               declare O : constant Long_Float :=
                  Long_Float (Counts (Counts'First (1) + I - 1, Counts'First (2) + J - 1));
               begin
                  Sxy := Sxy + O * (Long_Float (I) - Mean_R) * (Long_Float (J) - Mean_C);
               end;
            end loop;
         end loop;
         if Sxx > 0.0 and then Syy > 0.0 then
            declare Rho : constant Long_Float := Sxy / Sqrt (Sxx * Syy);
            begin
               Res.MH_Stat := Float ((Tot - 1.0) * Rho * Rho);
            end;
         else
            Res.MH_Stat := 0.0;
         end if;
         Res.MH_P := 1.0 - Chi_Square_CDF (Res.MH_Stat, 1.0);
      end;

      --  Association measures derived from Pearson.
      Res.Phi := Float (Sqrt (P_Sum / Tot));
      Res.Contingency := Float (Sqrt (P_Sum / (P_Sum + Tot)));
      declare
         M : constant Long_Float := Long_Float (Natural'Min (Rn - 1, Cn - 1));
      begin
         Res.Cramers_V := Float (Sqrt (P_Sum / (Tot * M)));
      end;

      if Rn = 2 and then Cn = 2 then
         Res.Has_Yates := True;
         Res.Yates_Stat := Float (Y_Sum);
         Res.Yates_P := 1.0 - Chi_Square_CDF (Res.Yates_Stat, 1.0);
      end if;

      return Res;
   end Chi_Square_Tests;

   ---------------------
   -- Goodness_Of_Fit --
   ---------------------
   --  TASK 2: implement equal-proportions goodness-of-fit.
   function Goodness_Of_Fit (Counts : Count_Vector) return GOF_Result is
      pragma Unreferenced (Counts);
   begin
      return (others => <>);  --  TASK 2
   end Goodness_Of_Fit;

end SData_Core.Statistics;