--  In-crate unit tests for SData_Core.Statistics (standards review
--  remediation #3).  The module's ~54 distribution / IDF / RNG functions were
--  previously exercised only indirectly through consumer integration scripts.
--
--  Strategy: assert mathematical *properties* that catch real bugs without
--  depending on a particular internal approximation —
--    * canonical reference values (e.g. Z_CDF(0)=0.5, Z_CDF(1.96)=0.975),
--    * CDF boundaries (-> 0 at the low tail, -> 1 at the high tail),
--    * CDF monotonicity,
--    * IDF round-trips (CDF(IDF(p)) ~= p; >= p for discrete quantiles),
--    * symmetry where the distribution is symmetric,
--    * PDF/PMF non-negativity,
--    * RNG support membership and a loose seeded sample mean.
--
--  Parameter-order notes verified against the bodies:
--    * Gamma_CDF/IDF: third arg Beta/Rate is a RATE (Gamma(1,1) = Exp(rate 1)).
--    * Weibull_CDF (X, Scale, Shape) but Weibull_IDF (P, Shape, Scale) — the
--      Scale/Shape order is REVERSED between the two.
--
--  Plain inline assertions; no framework.

with Ada.Text_IO;          use Ada.Text_IO;
with Ada.Command_Line;
with SData_Core.Statistics; use SData_Core.Statistics;
with SData_Core.Values;     use SData_Core.Values;
--  The Statistics API returns Real (SData_Core.Values); this makes the type
--  name and its arithmetic/relational operators directly visible here.

procedure Statistics_Tests is

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

   --  Absolute-tolerance float comparison.
   function Approx (A, B : Real; Tol : Real := 1.0e-4) return Boolean is
   begin
      return abs (A - B) <= Tol;
   end Approx;

   Sqrt_2pi_Inv : constant Real := 0.3989422804;  -- 1 / sqrt(2*pi)

begin
   Put_Line ("=== Statistics_Tests ===");

   ----------------------------------------------------------------------------
   --  Standard normal (Z)
   ----------------------------------------------------------------------------
   Assert (Approx (Z_PDF (0.0), Sqrt_2pi_Inv),        "Z_PDF(0) = 1/sqrt(2pi)");
   Assert (Approx (Z_PDF (-1.0), Z_PDF (1.0)),        "Z_PDF symmetric");
   Assert (Approx (Z_CDF (0.0), 0.5),                 "Z_CDF(0) = 0.5");
   Assert (Approx (Z_CDF (1.0), 0.8413447, 1.0e-3),   "Z_CDF(1) ~ 0.8413");
   Assert (Approx (Z_CDF (1.96), 0.975, 1.0e-3),      "Z_CDF(1.96) ~ 0.975");
   Assert (Approx (Z_CDF (-1.0) + Z_CDF (1.0), 1.0, 1.0e-3),
                                                      "Z_CDF symmetry: F(-x)+F(x)=1");
   Assert (Z_CDF (-10.0) < 1.0e-3,                    "Z_CDF low tail -> 0");
   Assert (Z_CDF (10.0) > 1.0 - 1.0e-3,               "Z_CDF high tail -> 1");
   Assert (Z_CDF (0.5) < Z_CDF (0.6),                 "Z_CDF monotone");
   Assert (Approx (Z_IDF (0.5), 0.0, 1.0e-3),         "Z_IDF(0.5) = 0");
   Assert (Approx (Z_IDF (0.975), 1.96, 1.0e-2),      "Z_IDF(0.975) ~ 1.96");
   Assert (Approx (Z_CDF (Z_IDF (0.25)), 0.25, 1.0e-3), "Z round-trip p=0.25");
   Assert (Approx (Z_CDF (Z_IDF (0.80)), 0.80, 1.0e-3), "Z round-trip p=0.80");

   ----------------------------------------------------------------------------
   --  Normal (general) — anchored to Z
   ----------------------------------------------------------------------------
   Assert (Approx (Normal_PDF (0.0, 0.0, 1.0), Z_PDF (0.0)),   "Normal_PDF(0,0,1)=Z_PDF(0)");
   Assert (Approx (Normal_CDF (5.0, 5.0, 2.0), 0.5),          "Normal_CDF(mean)=0.5");
   Assert (Approx (Normal_CDF (7.0, 5.0, 2.0), Z_CDF (1.0), 1.0e-4),
                                                              "Normal_CDF standardizes to Z");
   Assert (Approx (Normal_IDF (0.5, 3.0, 4.0), 3.0, 1.0e-3),  "Normal_IDF(0.5)=mean");
   Assert (Approx (Normal_CDF (Normal_IDF (0.3, 2.0, 1.5), 2.0, 1.5), 0.3, 1.0e-3),
                                                              "Normal round-trip");

   ----------------------------------------------------------------------------
   --  Uniform
   ----------------------------------------------------------------------------
   Assert (Approx (Uniform_PDF (0.5, 0.0, 1.0), 1.0),   "Uniform_PDF(.,0,1)=1");
   Assert (Approx (Uniform_PDF (5.0, 0.0, 1.0), 0.0),   "Uniform_PDF outside=0");
   Assert (Approx (Uniform_CDF (0.3, 0.0, 1.0), 0.3),   "Uniform_CDF(0.3,0,1)=0.3");
   Assert (Approx (Uniform_CDF (-1.0, 0.0, 1.0), 0.0),  "Uniform_CDF below=0");
   Assert (Approx (Uniform_CDF (2.0, 0.0, 1.0), 1.0),   "Uniform_CDF above=1");
   Assert (Approx (Uniform_IDF (0.7, 2.0, 4.0), 3.4, 1.0e-4), "Uniform_IDF(0.7,2,4)=3.4");

   ----------------------------------------------------------------------------
   --  Exponential (rate parameterization)
   ----------------------------------------------------------------------------
   Assert (Approx (Exponential_PDF (0.0, 1.0), 1.0),            "Exp_PDF(0,rate1)=1");
   Assert (Approx (Exponential_CDF (0.0, 1.0), 0.0),           "Exp_CDF(0)=0");
   Assert (Approx (Exponential_CDF (1.0, 1.0), 0.6321206, 1.0e-4),
                                                               "Exp_CDF(1,1)=1-e^-1");
   Assert (Exponential_CDF (50.0, 1.0) > 1.0 - 1.0e-6,         "Exp_CDF high tail -> 1");
   Assert (Approx (Exponential_IDF (0.5, 1.0), 0.6931472, 1.0e-3),
                                                               "Exp_IDF(0.5,1)=ln2");
   Assert (Approx (Exponential_CDF (Exponential_IDF (0.4, 2.0), 2.0), 0.4, 1.0e-3),
                                                               "Exp round-trip");

   ----------------------------------------------------------------------------
   --  Beta
   ----------------------------------------------------------------------------
   Assert (Approx (Beta_PDF (0.5, 1.0, 1.0), 1.0),       "Beta(1,1)_PDF=Uniform");
   Assert (Approx (Beta_CDF (0.5, 1.0, 1.0), 0.5),       "Beta(1,1)_CDF(0.5)=0.5");
   Assert (Approx (Beta_CDF (0.5, 2.0, 2.0), 0.5, 1.0e-4), "Beta(2,2) symmetric CDF(0.5)=0.5");
   Assert (Approx (Beta_CDF (0.0, 2.0, 3.0), 0.0),       "Beta_CDF(0)=0");
   Assert (Approx (Beta_CDF (1.0, 2.0, 3.0), 1.0),       "Beta_CDF(1)=1");
   Assert (Beta_CDF (0.3, 2.0, 3.0) < Beta_CDF (0.6, 2.0, 3.0), "Beta_CDF monotone");
   Assert (Beta_PDF (0.4, 2.0, 5.0) >= 0.0,              "Beta_PDF non-negative");
   Assert (Approx (Beta_CDF (Beta_IDF (0.65, 2.0, 5.0), 2.0, 5.0), 0.65, 1.0e-3),
                                                         "Beta round-trip");

   ----------------------------------------------------------------------------
   --  Gamma (third arg is RATE; Gamma(1,1) = Exp(rate 1))
   ----------------------------------------------------------------------------
   Assert (Approx (Gamma_CDF (1.0, 1.0, 1.0), Exponential_CDF (1.0, 1.0), 1.0e-4),
                                                         "Gamma(1,rate1)=Exp(rate1)");
   Assert (Approx (Gamma_CDF (0.0, 2.0, 1.0), 0.0),      "Gamma_CDF(0)=0");
   Assert (Gamma_CDF (200.0, 2.0, 1.0) > 1.0 - 1.0e-3,   "Gamma_CDF high tail -> 1");
   Assert (Gamma_CDF (1.0, 2.0, 1.0) < Gamma_CDF (3.0, 2.0, 1.0), "Gamma_CDF monotone");
   Assert (Gamma_PDF (2.0, 2.0, 1.0) >= 0.0,             "Gamma_PDF non-negative");
   Assert (Approx (Gamma_CDF (Gamma_IDF (0.5, 3.0, 2.0), 3.0, 2.0), 0.5, 1.0e-3),
                                                         "Gamma round-trip");

   ----------------------------------------------------------------------------
   --  Chi-square (df=2 equals Exponential with rate 1/2)
   ----------------------------------------------------------------------------
   Assert (Approx (Chi_Square_CDF (2.0, 2.0), Exponential_CDF (2.0, 0.5), 1.0e-3),
                                                         "ChiSq(df2)=Exp(rate 1/2)");
   Assert (Approx (Chi_Square_CDF (0.0, 3.0), 0.0),      "ChiSq_CDF(0)=0");
   Assert (Chi_Square_CDF (1.0, 3.0) < Chi_Square_CDF (5.0, 3.0), "ChiSq_CDF monotone");
   Assert (Chi_Square_PDF (3.0, 3.0) >= 0.0,             "ChiSq_PDF non-negative");
   Assert (Approx (Chi_Square_CDF (Chi_Square_IDF (0.95, 5.0), 5.0), 0.95, 1.0e-3),
                                                         "ChiSq round-trip p=0.95");

   ----------------------------------------------------------------------------
   --  Student's t (symmetric about 0; large df -> normal)
   ----------------------------------------------------------------------------
   Assert (Approx (Student_T_CDF (0.0, 10.0), 0.5),      "T_CDF(0)=0.5");
   Assert (Approx (Student_T_CDF (-1.5, 8.0) + Student_T_CDF (1.5, 8.0), 1.0, 1.0e-4),
                                                         "T_CDF symmetry");
   Assert (Approx (Student_T_CDF (1.0, 1000.0), Z_CDF (1.0), 2.0e-3),
                                                         "T(large df) ~ Normal");
   Assert (Student_T_PDF (0.5, 5.0) >= 0.0,              "T_PDF non-negative");
   Assert (Approx (Student_T_CDF (Student_T_IDF (0.9, 7.0), 7.0), 0.9, 1.0e-3),
                                                         "T round-trip p=0.9");

   ----------------------------------------------------------------------------
   --  F distribution (median of F(d,d) is 1)
   ----------------------------------------------------------------------------
   Assert (Approx (F_CDF (1.0, 6.0, 6.0), 0.5, 2.0e-3),  "F_CDF(1,d,d)=0.5");
   Assert (Approx (F_CDF (0.0, 4.0, 8.0), 0.0),          "F_CDF(0)=0");
   Assert (F_CDF (1.0, 4.0, 8.0) < F_CDF (3.0, 4.0, 8.0), "F_CDF monotone");
   Assert (F_PDF (1.5, 4.0, 8.0) >= 0.0,                 "F_PDF non-negative");
   Assert (Approx (F_CDF (F_IDF (0.9, 4.0, 8.0), 4.0, 8.0), 0.9, 2.0e-3),
                                                         "F round-trip p=0.9");

   ----------------------------------------------------------------------------
   --  Poisson (discrete: PMF(0)=e^-mean; IDF is a quantile, CDF(IDF(p)) >= p)
   ----------------------------------------------------------------------------
   Assert (Approx (Poisson_PMF (0.0, 1.0), 0.3678794, 1.0e-5),  "Poisson_PMF(0,1)=e^-1");
   Assert (Approx (Poisson_PMF (1.0, 1.0), 0.3678794, 1.0e-5),  "Poisson_PMF(1,1)=e^-1");
   Assert (Approx (Poisson_CDF (0.0, 1.0), 0.3678794, 1.0e-5),  "Poisson_CDF(0,1)=e^-1");
   Assert (Poisson_PMF (3.0, 4.0) >= 0.0,                       "Poisson_PMF non-negative");
   Assert (Poisson_CDF (Poisson_IDF (0.5, 4.0), 4.0) >= 0.5 - 1.0e-6,
                                                               "Poisson IDF quantile CDF >= p");

   ----------------------------------------------------------------------------
   --  Binomial (discrete)
   ----------------------------------------------------------------------------
   Assert (Approx (Binomial_PMF (0.0, 10.0, 0.5), 0.0009765625, 1.0e-6),
                                                               "Binomial_PMF(0,10,.5)=.5^10");
   Assert (Approx (Binomial_PMF (5.0, 10.0, 0.5), 0.2460938, 1.0e-5),
                                                               "Binomial_PMF(5,10,.5)=252/1024");
   Assert (Approx (Binomial_CDF (10.0, 10.0, 0.5), 1.0, 1.0e-5), "Binomial_CDF(n,n,p)=1");
   Assert (Binomial_PMF (4.0, 10.0, 0.3) >= 0.0,               "Binomial_PMF non-negative");
   Assert (Binomial_CDF (Binomial_IDF (0.5, 10.0, 0.5), 10.0, 0.5) >= 0.5 - 1.0e-6,
                                                               "Binomial IDF quantile CDF >= p");

   ----------------------------------------------------------------------------
   --  Weibull (CDF takes (Scale, Shape); IDF takes (Shape, Scale) — reversed)
   ----------------------------------------------------------------------------
   Assert (Approx (Weibull_CDF (1.0, 1.0, 1.0), Exponential_CDF (1.0, 1.0), 1.0e-4),
                                                               "Weibull(scale1,shape1)=Exp(1)");
   Assert (Approx (Weibull_CDF (0.0, 2.0, 1.5), 0.0),          "Weibull_CDF(0)=0");
   Assert (Weibull_CDF (100.0, 2.0, 1.5) > 1.0 - 1.0e-6,       "Weibull_CDF high tail -> 1");
   Assert (Weibull_CDF (1.0, 2.0, 1.5) < Weibull_CDF (3.0, 2.0, 1.5),
                                                               "Weibull_CDF monotone");
   --  Round-trip honoring the reversed IDF parameter order:
   Assert (Approx (Weibull_CDF (Weibull_IDF (0.6, 1.5, 2.0), 2.0, 1.5), 0.6, 1.0e-3),
                                                               "Weibull round-trip (param order)");

   ----------------------------------------------------------------------------
   --  Laplace (symmetric about location)
   ----------------------------------------------------------------------------
   Assert (Approx (Laplace_PDF (0.0, 0.0, 1.0), 0.5),    "Laplace_PDF(0,0,1)=0.5");
   Assert (Approx (Laplace_CDF (0.0, 0.0, 1.0), 0.5),    "Laplace_CDF(0,0,1)=0.5");
   Assert (Approx (Laplace_CDF (-2.0, 0.0, 1.0) + Laplace_CDF (2.0, 0.0, 1.0), 1.0, 1.0e-5),
                                                         "Laplace_CDF symmetry");
   Assert (Approx (Laplace_IDF (0.5, 3.0, 2.0), 3.0, 1.0e-4), "Laplace_IDF(0.5)=location");
   Assert (Approx (Laplace_CDF (Laplace_IDF (0.2, 0.0, 1.0), 0.0, 1.0), 0.2, 1.0e-4),
                                                         "Laplace round-trip");

   ----------------------------------------------------------------------------
   --  RNG: seeded determinism, support membership, loose sample mean
   ----------------------------------------------------------------------------
   declare
      N_Draw : constant := 2000;
      Sum    : Real := 0.0;
      X      : Real;
      In_Range : Boolean := True;
   begin
      Set_Seed (12345);
      for I in 1 .. N_Draw loop
         X := Uniform_Random;
         if X < 0.0 or else X >= 1.0 then In_Range := False; end if;
         Sum := Sum + X;
      end loop;
      Assert (In_Range, "Uniform_Random in [0,1)");
      Assert (Approx (Sum / Real (N_Draw), 0.5, 0.05), "Uniform_Random sample mean ~ 0.5");

      --  Support membership for each *_RN (seeded, deterministic).
      Set_Seed (777);
      In_Range := True;
      for I in 1 .. 200 loop
         if Exponential_RN (1.0) < 0.0 then In_Range := False; end if;
      end loop;
      Assert (In_Range, "Exponential_RN >= 0");

      In_Range := True;
      for I in 1 .. 200 loop
         X := Uniform_RN (2.0, 5.0);
         if X < 2.0 or else X >= 5.0 then In_Range := False; end if;
      end loop;
      Assert (In_Range, "Uniform_RN in [2,5)");

      In_Range := True;
      for I in 1 .. 200 loop
         X := Beta_RN (2.0, 5.0);
         if X < 0.0 or else X > 1.0 then In_Range := False; end if;
      end loop;
      Assert (In_Range, "Beta_RN in [0,1]");

      In_Range := True;
      for I in 1 .. 200 loop
         X := Binomial_RN (10.0, 0.5);
         if X < 0.0 or else X > 10.0 then In_Range := False; end if;
      end loop;
      Assert (In_Range, "Binomial_RN in [0,n]");

      In_Range := True;
      for I in 1 .. 200 loop
         if Poisson_RN (3.0) < 0.0 then In_Range := False; end if;
      end loop;
      Assert (In_Range, "Poisson_RN >= 0");

      In_Range := True;
      for I in 1 .. 200 loop
         if Weibull_RN (2.0, 1.5) < 0.0 then In_Range := False; end if;
      end loop;
      Assert (In_Range, "Weibull_RN >= 0");

      In_Range := True;
      for I in 1 .. 200 loop
         if Chi_Square_RN (4.0) < 0.0 then In_Range := False; end if;
      end loop;
      Assert (In_Range, "Chi_Square_RN >= 0");
   end;

   ----------------------------------------------------------------------------
   --  Chi_Square_Tests: contingency-table chi-square family
   ----------------------------------------------------------------------------

   --  ==== Chi_Square_Tests: 2x2 [[10,20],[30,40]] ====
   declare
      M : constant Count_Matrix (1 .. 2, 1 .. 2) :=
        (1 => (10, 20), 2 => (30, 40));
      R : constant Chi_Square_Result := Chi_Square_Tests (M);
   begin
      Assert (R.Valid,                                   "ChiSq 2x2 valid");
      Assert (R.N = 100,                                 "ChiSq 2x2 N=100");
      Assert (R.DF = 1,                                  "ChiSq 2x2 DF=1");
      Assert (Approx (R.Pearson_Stat, 0.79365, 1.0e-3),  "ChiSq 2x2 Pearson");
      Assert (Approx (R.Pearson_P,    0.373,   1.0e-2),  "ChiSq 2x2 Pearson p");
      Assert (Approx (R.LR_Stat,      0.80424, 1.0e-3),  "ChiSq 2x2 LR");
      Assert (R.Has_Yates,                               "ChiSq 2x2 has Yates");
      Assert (Approx (R.Yates_Stat,   0.44643, 1.0e-3),  "ChiSq 2x2 Yates");
      Assert (Approx (R.MH_Stat,      0.78571, 1.0e-3),  "ChiSq 2x2 MH");
      Assert (Approx (R.Phi,          0.08909, 1.0e-3),  "ChiSq 2x2 phi");
      Assert (Approx (R.Cramers_V,    0.08909, 1.0e-3),  "ChiSq 2x2 Cramer V");
      Assert (Approx (R.Contingency,  0.08874, 1.0e-3),  "ChiSq 2x2 contingency");
   end;

   --  ==== Chi_Square_Tests: 2x3, no Yates, expected>=5 all ====
   declare
      --  [[20,30,50],[30,20,50]] : N=200, DF=2
      M : constant Count_Matrix (1 .. 2, 1 .. 3) :=
        (1 => (20, 30, 50), 2 => (30, 20, 50));
      R : constant Chi_Square_Result := Chi_Square_Tests (M);
   begin
      Assert (R.DF = 2,                    "ChiSq 2x3 DF=2");
      Assert (not R.Has_Yates,             "ChiSq 2x3 no Yates");
      Assert (R.Valid,                     "ChiSq 2x3 valid");
      Assert (Approx (R.Pct_Expected_Lt_5, 0.0, 1.0e-6), "ChiSq 2x3 no low cells");
   end;

   --  ==== Degenerate: a zero-margin column -> Valid=False ====
   declare
      M : constant Count_Matrix (1 .. 2, 1 .. 2) := (1 => (5, 0), 2 => (7, 0));
      R : constant Chi_Square_Result := Chi_Square_Tests (M);
   begin
      Assert (not R.Valid,   "ChiSq zero-margin invalid");
   end;

   ----------------------------------------------------------------------------
   --  Goodness_Of_Fit: equal-proportions one-way chi-square
   ----------------------------------------------------------------------------

   --  ==== Goodness_Of_Fit: [10,20,30] equal-proportions ====
   declare
      V : constant Count_Vector (1 .. 3) := (10, 20, 30);
      R : constant GOF_Result := Goodness_Of_Fit (V);
   begin
      Assert (R.Valid,                          "GOF valid");
      Assert (R.K = 3 and then R.N = 60,        "GOF k=3 N=60");
      Assert (R.DF = 2,                         "GOF DF=2");
      Assert (Approx (R.Stat, 10.0, 1.0e-4),    "GOF stat=10");
      Assert (Approx (R.P, 0.006738, 1.0e-4),   "GOF p=exp(-5)");
   end;

   --  Single category or empty -> invalid (DF=0).
   declare
      V : constant Count_Vector (1 .. 1) := (1 => 42);
      R : constant GOF_Result := Goodness_Of_Fit (V);
   begin
      Assert (not R.Valid,   "GOF single-category invalid");
   end;

   --  Summary
   New_Line;
   Put_Line (Passed'Image & " passed," & Failed'Image & " failed.");
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Statistics_Tests;
