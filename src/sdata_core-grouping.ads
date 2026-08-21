--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  SData_Core.Grouping holds the BY-group state: the active BY-variable names
--  and the same-group test.  In_Same_Group reads cell values via
--  Columns.Column_Maps + the Backing_Store directly -- it does NOT with Table
--  (sec 4.4).  The BY-var list is package-level state, mirroring the prior
--  Table_By_Vars singleton.

with Ada.Containers.Vectors;
with SData_Core.Columns;
with SData_Core.Backing_Store;

package SData_Core.Grouping is

   procedure Clear_By_Vars;
   procedure Add_By_Var (Name : String);
   function  By_Var_Count return Natural;
   function  By_Var_Name (I : Positive) return String;

   --  True iff rows Idx1 and Idx2 share all BY-var values (empty BY => always
   --  True; equal indices => True; out-of-range => False).  Reads cells from T
   --  (live segment) or Store (spilled), exactly as the old Get_Value_Upper.
   function In_Same_Group
     (Idx1, Idx2    : Positive;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Boolean;

   --  ADR-0013: partitions Physical_Rows into BY-key groups by the current
   --  BY variables' values -- NOT by physical/logical adjacency.  A row's
   --  membership depends only on its own BY-var values, so callers no
   --  longer need the table pre-sorted by BY for correct grouping (that
   --  requirement belonged to the old adjacency-scan implementation, not
   --  to grouping itself).
   --
   --  Physical_Rows may be any caller-selected subset/order of physical row
   --  indices -- e.g. Table.Partition_By_Key passes the SELECT-filtered
   --  logical-to-physical list for SData_Core.Commands.Group_Boundaries's
   --  callers (AGGREGATE/STATS/TRANSPOSE/TABLES), while data-vandal's
   --  Compute_Groups passes the raw, unfiltered 1 .. Row_Count -- this
   --  primitive has no opinion on filtering, only on grouping.
   --
   --  Empty BY (Table_By_Vars.Is_Empty): all of Physical_Rows form a single
   --  group, in their given order -- matches In_Same_Group's own "empty BY
   --  => always True" convention and the pre-existing Group_Boundaries
   --  contract for "no active BY".
   --
   --  Otherwise: rows are bucketed by composite BY-key value (equal BY-var
   --  values, compared the same way In_Same_Group compares them), then the
   --  resulting groups are ordered by that key ascending -- reproducing the
   --  row order BY's old forced table-sort used to produce as a side
   --  effect, without touching any table's actual row order to get it.
   package Row_Index_Vectors is
     new Ada.Containers.Vectors (Positive, Positive);
   package Row_Group_Vectors is
     new Ada.Containers.Vectors
       (Positive, Row_Index_Vectors.Vector, Row_Index_Vectors."=");

   function Partition_By_Key
     (Physical_Rows : Row_Index_Vectors.Vector;
      T             : Columns.Column_Maps.Map;
      Store         : in out Backing_Store.Backing_Store;
      Segment_Start : Positive;
      Row_Count     : Natural) return Row_Group_Vectors.Vector;

end SData_Core.Grouping;
