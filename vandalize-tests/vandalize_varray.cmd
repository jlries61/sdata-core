-- Test VANDALIZE with a virtual array (ARRAY command) as source.
-- Source elements are named columns P1/P2/P3; dest is a DIM array.
NEW
REPEAT 4
LET P1 = RECNO()
LET P2 = RECNO() * 10
LET P3 = RECNO() * 100
RUN
ARRAY PRICES P1 P2 P3
-- /MISS=1.0: all output cells missing; verifies NOISY(1..3) are created from P1/P2/P3.
VANDALIZE PRICES INTO NOISY /MISS=1.0
RUN
PRINT NMISS(NOISY(1)) NMISS(NOISY(2)) NMISS(NOISY(3))
RUN
-- /MISS=0.0: copy unchanged; verifies COPY(1..3) are non-missing (values preserved).
VANDALIZE PRICES INTO COPY /MISS=0.0
RUN
PRINT NMISS(COPY(1)) NMISS(COPY(2)) NMISS(COPY(3))
RUN
