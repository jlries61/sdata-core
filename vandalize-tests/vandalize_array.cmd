-- Test VANDALIZE on a DIM array.
-- DIM X(3) creates X(1), X(2), X(3). VANDALIZE X INTO Y with /MISS=1.0
-- creates Y(1), Y(2), Y(3), all missing.
NEW
REPEAT 4
DIM X(3)
LET X(1) = RECNO() * 1
LET X(2) = RECNO() * 10
LET X(3) = RECNO() * 100
RUN

VANDALIZE X INTO Y /MISS=1.0

RUN
PRINT "NMISS(Y(1)) should be 4:" NMISS(Y(1))
PRINT "NMISS(Y(2)) should be 4:" NMISS(Y(2))
PRINT "NMISS(Y(3)) should be 4:" NMISS(Y(3))
RUN
QUIT
