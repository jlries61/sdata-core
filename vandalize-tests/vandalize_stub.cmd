-- VANDALIZE reaches the handler without crashing.
NEW
REPEAT 3
LET X = RECNO()
RUN
VANDALIZE X INTO X_V /MISS=1.0
QUIT
