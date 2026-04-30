---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
disable-model-invocation: true
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead.

## Glossary

Terms we've hardened live in `docs/concepts.md`. If it exists, read it at the start of every grill. When the user uses a term that conflicts with an entry, call it out immediately. When a term hardens during a grill, add it to `docs/concepts.md` right then — don't batch.

The file starts empty (created lazily when the first term hardens). Don't impose a format yet — free-form one-liners are fine. After ~10 terms accumulate, we'll see what structure naturally wants to emerge.
