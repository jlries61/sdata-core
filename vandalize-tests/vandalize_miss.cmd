-- Test VANDALIZE /MISS operation.

-- Part 1: /MISS=1.0 makes all cells missing.
NEW
REPEAT 5
LET X = RECNO()
RUN
VANDALIZE X INTO X_V /MISS=1.0
RUN
PRINT "N(X_V) should be 0:" N(X_V)
PRINT "NMISS(X_V) should be 5:" NMISS(X_V)
RUN

-- Part 2: /MISS=0.0 leaves all cells unchanged.
NEW
REPEAT 5
LET X = RECNO()
RUN
VANDALIZE X INTO X_V /MISS=0.0
RUN
PRINT "N(X_V) should be 5:" N(X_V)
PRINT "SUM(X_V) should be 15:" SUM(X_V)
RUN

-- Part 3: error — probability sum > 1.0
NEW
REPEAT 3
LET X = RECNO()
RUN
VANDALIZE X INTO X_V /MISS=0.7 /SHUFFLE=0.5
QUIT
