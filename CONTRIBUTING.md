# Contributing

Thanks for wanting to help. SmartAutoResearch is mostly Markdown plus two small bash scripts, so contributing usually means editing a command spec, a reference doc, or the scripts — with one firm rule underneath everything: the deterministic seam stays tested.

## The ground rules

1. **Keep the scripts green.** Touch anything in `scripts/` and it has to stay `bash -n` clean and pass `scripts/smoke-test.sh` — 115 assertions right now. Run it before you open a PR:
   ```bash
   bash scripts/smoke-test.sh   # you want RESULT: PASS
   ```
2. **New script logic is test-first.** Adding a `screen-cmd` pattern, a `classify` archetype, a `plateau` rule? Write the smoke-test assertion in the same change, and show it failing before your change and passing after. Nothing untested slips in.
3. **Safety only gets stricter, never looser.** You can broaden a deny-list. You can't weaken one. The no-auto-ship rule, the `screen-cmd` / `screen-path` screens, and the DB-URL allowlist aren't up for negotiation in a PR that's trying to do something else.
4. **Don't break the four-way separation** (`references/four-way-separation.md`). The optimizer never writes the eval, the judge never sees the iteration history, the test-runner never sees the rubric. A change that lets one role peek at another's context gets rejected — no matter how good the rest of it is.
5. **Keep it lean.** Simpler wins. A command file that grows without buying a real capability is a regression, and tokens per invocation matter.

## Where help goes furthest

- **New domain examples for `commands/loop.md`** — a fresh `example-*.py` + `example-test-cases.json` pair for a domain we don't cover yet.
- **Verify-command templates for `commands/plan.md`** — how to pull a metric out as a plain number for a stack we haven't mapped.
- **More `screen-cmd` / `screen-path` patterns** for dangerous commands or secret-bearing files we miss — always with a smoke test.
- **Judge-bias mitigations** beyond the four we already handle (`references/reason-judge-protocol.md`).

## Before you open the PR

- [ ] `bash scripts/smoke-test.sh` prints `RESULT: PASS`.
- [ ] Any new script logic has a matching smoke-test assertion (show the RED→GREEN in the PR description).
- [ ] Nothing safety-related got loosened — deny-lists only grew.
- [ ] The four-way separation still holds.
- [ ] You updated the Directory Layout in `SKILL.md` and `README.md` if you added a file.
- [ ] No secrets, credentials, or PII in any example, test case, or lesson entry.

## One thing worth knowing

This skill is agent *behavior* written in Markdown — there's no compiled artifact, and nothing runs end-to-end without a real agent driving it. What we can test mechanically is the seam: the two scripts plus the example eval. That's what the smoke suite covers, and it's the bar every PR clears.
