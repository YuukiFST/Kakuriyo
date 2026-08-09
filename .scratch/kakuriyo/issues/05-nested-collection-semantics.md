# Nested Collection semantics

Type: grilling
Status: resolved
Assigned to: pi session
Blocked by:

## Question

Nested **Collections** (e.g. Links → Amazon, ebay - GPUs, youtube - games): rules for create/rename/move/delete, moving Entries between Collections, empty Collections, and whether an Entry lives in exactly one Collection. What must keyboard navigation respect in the tree?

## Answer

**Containment**: an Entry lives in exactly one location — a Collection or the Vault root (loose, no Collection). Collections are folders, not tags; moving an Entry relocates it (no copies, no multi-parent). Root holds both Collections and loose Entries.

| Rule | v1 decision |
| --- | --- |
| **Create Collection** | Anywhere (root or inside any Collection), via context menu + keyboard; name required, non-blank |
| **Name uniqueness** | Per parent (siblings only); same name allowed under different parents; rename checks siblings only |
| **Max depth** | No hard cap in v1; tree UI and keyboard traversal handle arbitrary nesting |
| **Move Collection** | Whole subtree (Collections + Entries) relocates to any target except itself or its own descendants (cycle prevention) |
| **Delete Collection** | Never deletes children: sub-Collections and Entries evacuate to the deleted Collection's parent. Empty Collection deletion just removes it |
| **Empty Collections** | Allowed and persistent — created empty stays until content; no auto-prune |
| **Keyboard minimum (feeds 07)** | Arrow traversal across nested levels; expand/collapse via key; inline create/rename/delete (e.g. F2, Delete-with-confirm); single-select; move Entry via keyboard cut/paste |
