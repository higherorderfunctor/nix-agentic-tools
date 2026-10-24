Record the HEAD as the review base before the worker's first write. Every round
reviews the full base..HEAD change and what it touches, including the current
working diff when fixes are not yet committed; never review only the latest fix.
A round with no upheld finding ends the loop. Otherwise the worker fixes the
validated findings within the task, then review runs again. Such fixes need no
approval from the user. Run at most 3 rounds for the task; never split the work
to reset the cap. If the same defect survives 2 rounds, change the brief instead
of repeating it. At the cap, return the result, open defects and the decision
needed.
