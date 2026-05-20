-- Test VANDALIZE /PERTURB operation.

-- Part 1: /PERTURB=0.0 — zero probability; output equals source exactly.
NEW
REPEAT 5
LET X = RECNO()
RUN
RSEED 42
VANDALIZE X INTO X_V /PERTURB=0.0
PRINT "NMISS(X_V) should be 0:" NMISS(X_V)
PRINT "N(X_V) should be 5:" N(X_V)
PRINT "X X_V:" X X_V
RUN

-- Part 2: /PERTURB — full perturbation (default prob=1.0, sd-frac=0.01).
-- Noise is tiny (SD~1.58, sd-frac=0.01 => sigma~0.016).
-- Values stay non-missing and very close to original.
NEW
REPEAT 5
LET X = RECNO()
RUN
RSEED 42
VANDALIZE X INTO X_V /PERTURB
PRINT "NMISS(X_V) should be 0:" NMISS(X_V)
PRINT "N(X_V) should be 5:" N(X_V)
PRINT "X X_V:" X X_V
RUN
QUIT
