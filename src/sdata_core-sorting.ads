--  Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
--  License: GNU General Public License v3 or later, with GCC Runtime Library Exception 3.1
--  See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>

--  SData_Core.Sorting holds the table sort: the spilled-dataset SQL ORDER BY
--  path and the in-memory stable merge-sort.  It operates on the column map +
--  insertion order + criteria, and is handed the Backing_Store instance for
--  the spilled path -- it does NOT with Table (no cycle; sec 4.4 recommended).

with SData_Core.Columns;
with SData_Core.Backing_Store;

package SData_Core.Sorting is

   --  Reorder T in place per Criteria.  Stable (record_id / original-index
   --  tie-break).  When Store.Is_Active the sort runs in SQLite; otherwise
   --  in memory.  Column_Order gives user-visible column sequence for the
   --  spilled CREATE/INSERT; Segment_Start is the live segment's first row.
   procedure Sort
     (T             : in out Columns.Column_Maps.Map;
      Column_Order  : Columns.Column_Name_Vectors.Vector;
      Criteria      : Columns.Sort_Criteria_Array;
      Row_Count     : Natural;
      Segment_Start : Positive;
      Store         : in out Backing_Store.Backing_Store);

end SData_Core.Sorting;
