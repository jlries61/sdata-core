-- Test VANDALIZE with /MISS + /SHUFFLE combined.
-- MISS=0.2, SHUFFLE=0.4 (total 0.6; remainder 0.4 unchanged).
-- With 5 records and RSEED=42, verify output is sensible:
-- non-missing X_V values come from the original X set {1,2,3,4,5}.
NEW
RSEED 42
REPEAT 5
LET X = RECNO()
RUN
VANDALIZE X INTO X_V /MISS=0.2 /SHUFFLE=0.4
RUN
PRINT X X_V
RUN
QUIT
