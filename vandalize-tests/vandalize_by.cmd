-- Test /BY= stratification: shuffle stays within groups.
-- Two groups: GRP=1 (values 1,2,3) and GRP=2 (values 10,20,30).
-- After full-shuffle, GRP=1 rows contain only values from {1,2,3}
-- and GRP=2 rows contain only values from {10,20,30}.
NEW
RSEED 17
REPEAT 6
IF RECNO() <= 3 THEN LET GRP = 1 ELSE LET GRP = 2
IF RECNO() <= 3 THEN LET X = RECNO() ELSE LET X = (RECNO()-3) * 10
RUN
SORT GRP
VANDALIZE X INTO X_V /SHUFFLE=1.0 /BY=GRP
RUN
PRINT GRP X X_V
RUN
QUIT
