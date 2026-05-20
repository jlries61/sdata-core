-- Test VANDALIZE in-place (source = destination).
-- MISS=1.0 makes all cells missing deterministically.
NEW
REPEAT 5
LET X = RECNO() * 10
RUN
VANDALIZE X INTO X /MISS=1.0
RUN
PRINT "NMISS(X) should be 5:" NMISS(X)
RUN
QUIT
