-- Test VANDALIZE /SHUFFLE operation.

-- Part 1: /SHUFFLE=0.0 — no cells shuffled; output equals source.
NEW
REPEAT 5
LET X = RECNO() * 10
RUN
VANDALIZE X INTO X_V /SHUFFLE=0.0
RUN
PRINT "SUM(X_V):" SUM(X_V)
PRINT "MIN(X_V):" MIN(X_V)
PRINT "MAX(X_V):" MAX(X_V)
RUN

-- Part 2: /SHUFFLE=1.0 — all cells shuffled; sum/min/max unchanged.
NEW
RSEED 42
REPEAT 5
LET X = RECNO() * 10
RUN
VANDALIZE X INTO X_V /SHUFFLE=1.0
RUN
PRINT "SUM(X_V):" SUM(X_V)
PRINT "MIN(X_V):" MIN(X_V)
PRINT "MAX(X_V):" MAX(X_V)
RUN
QUIT
