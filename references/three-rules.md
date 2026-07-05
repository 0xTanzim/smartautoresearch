# The Three Rules

Every criterion — whether proposed by the agent or provided by the user — MUST pass these three rules before it's allowed to gate any loop (`commands/loop.md`) or feed the eval agent (`agents/eval-agent.md`). This is the single highest-leverage check in the whole optimize path: bad criteria produce bad evals, and bad evals waste every iteration that follows them.

## Rule 1: State the exact condition, not the goal

Don't describe what you want. Describe what you can measure.

| Bad | Good |
|---|---|
| "Make sure the hook is short" | "The first line must be under 136 characters including spaces" |
| "Should be professional" | "Contains no exclamation marks and no ALL CAPS words (3+ letters)" |
| "Include relevant data" | "Contains at least one specific number or statistic with a source" |

## Rule 2: One criterion, one variable

Each criterion tests exactly one thing. If you're tempted to use "and" to connect two checks, split them into two separate criteria.

| Bad | Good |
|---|---|
| "Under 150 words and ends with a question" | Criterion 1: "Under 150 words" / Criterion 2: "Last sentence ends with a question mark" |
| "Professional tone with no jargon" | Criterion 1: "No words from the banned jargon list" / Criterion 2: "No sentences over 25 words" |

## Rule 3: Define the test (optional but strongly preferred)

Describe how to verify the criterion — what to count, what regex to match, what structure to look for. This helps the eval agent write better checks and helps the judge score more consistently.

| Criterion | Test definition |
|---|---|
| "First line under 136 characters" | `len(lines[0]) <= 136` |
| "Contains at least one statistic" | `re.search(r'\d+[%x]?\s', text)` returns a match |
| "Ends with a question" | `text.rstrip().endswith("?")` |

## Applying the Rules

If the user provides criteria that violate The Three Rules, rewrite them — show the before/after so the user understands the improvement, don't silently substitute.

### The walkthrough script (use verbatim in chat, before proposing criteria)

> **The Three Rules** — every criterion must pass these before we start:
>
> 1. **State the exact condition, not the goal.** "First line under 136 characters" not "keep the hook short."
> 2. **One criterion, one variable.** If it has "and", split it into two.
> 3. **Define the test (optional).** How to check it — what to count, match, or look for.

Then propose 5-7 quality criteria. **Every criterion MUST pass The Three Rules.** Write the list in chat (not in a popup/short-form UI) — long lists in a small confirmation surface become unreadable. If using a structured confirm mechanism (e.g. `AskUserQuestion`), keep that surface to a short question only ("Do these quality criteria look right?" with "These look good" / "Adjust some" options) — put all substantive detail in chat first, never in the popup.

### Who this applies to

- `commands/loop.md` Setup, when the user pastes raw content to optimize.
- `agents/eval-agent.md`, which independently re-validates every criterion against these same three rules before generating `eval.py` or `rubric.md` — the main agent and the eval agent both check, because the eval agent is the last line of defense against a criterion that slipped through.
- `commands/probe.md`, when constraints extracted from persona interrogation are candidates for becoming a loop's Metric/Verify — a probed constraint that can't pass Rule 1 isn't ready to gate anything yet, it needs another round.
