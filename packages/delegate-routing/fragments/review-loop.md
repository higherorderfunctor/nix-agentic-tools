Record HEAD as the review base before the first write. Each round reviews the
accumulated diff from the pinned pre-write base to HEAD (`base..HEAD`), plus
touched dependencies. The worker fixes accepted issues within its task without
asking the user. Stop early when no accepted issue is medium severity or higher;
otherwise repeat write then review, up to 3 rounds. If the same defect survives
2 rounds, change the brief instead of repeating it. At the cap, return the
result, open defects and decision needed.
