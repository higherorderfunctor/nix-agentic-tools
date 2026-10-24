Add this to the rubric for the worker and every reviewer: each added line must
name a caller or the concrete input it refuses (value, path or environment);
otherwise remove it. A guard with a real but unstated refused input needs that
input named where the guard lives. Flag wrappers, shims, compatibility branches
and tests kept only to preserve an old shape; propose the simpler form when the
code can collapse.
