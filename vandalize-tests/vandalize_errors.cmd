-- Test VANDALIZE parse/validation errors

-- Error: INTO keyword with no destination name following
NEW
REPEAT 3
LET X = RECNO()
RUN
VANDALIZE X INTO /MISS=1.0
QUIT
