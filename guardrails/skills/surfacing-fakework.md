---
name: surfacing-fakework
description: Use CONTINUOUSLY during any task — feature work, refactor, bug fix, audit, design pass. The moment you notice an empty handler, an exported symbol with no callers, a stub response, a swallowed exception, a TODO papering over broken wiring, or any mismatch between "this advertises a feature" and "the feature actually works end-to-end" — file a GitHub issue immediately and continue your current task. This is the inflight discovery layer; verify-done / verify-contract / verify-storage / verify-identity / verify-honest-failure are the done-claim checkpoints. Do not wait for a checkpoint to surface what you can already see.
---

# surfacing-fakework — inflight discovery, file immediately, keep moving

## Why this exists

The verify-* skill family runs at defined checkpoints: before claiming "done", before claiming "integrated", before claiming "data persisted". These checkpoints catch a lot. But they fire only when an agent reaches a completion gate.

In practice, agents encounter fakework continuously during normal work — while grepping for a bug, reading adjacent code, tracing a call-graph. The instinct is to note it mentally ("I will fix it later") or add a `// TODO` comment, or silently absorb it into the current PR. All three responses fail:

- Mental notes evaporate between sessions.
- `// TODO` comments accumulate and are never acted on.
- Silent absorption into the current PR creates scope creep and monster diffs that are impossible to review.

**Case A — Audit v2, Educando billing (May 2026)**: two audit agents filed 15 issues in a batch at the formal audit checkpoint. Excellent. Then during the fix-implementation waves, agents found 1-2 additional issues per wave that the static audit had missed — issues only visible by reading the code they were editing. The right move was to file immediately and continue; in most cases agents did this correctly. In one case (`billing.ts:446`, route-level fail-open absorbed into PR #347 without a dedicated issue) the agent silently subsumed the finding — it was fixed, but no issue was filed, so the campaign log is incomplete and the blast-radius analysis was never done.

**Case B — Inflight discovery during fix work**: issue #365 (`updated.resumed` webhook handler missing) was surfaced while fixing #351 (refund downgrade logic). The agent stopped, filed #365, then continued on #351. Correct behavior. File size: 3-line issue body, 90 seconds of work, saved from becoming a silent regression.

This skill codifies what those two agents did well — and prevents the one failure mode.

## When to invoke

During **any** task. The trigger is noticing, not a checkpoint.

File the moment you observe any of the patterns in the checklist below, regardless of:
- Whether it is inside or outside the current PRs scope.
- Whether "someone else" owns the code.
- Whether you think the issue is obvious to a human reviewer.
- Whether you already have several files open.

This skill does NOT replace verify-done at the done-claim gate. It runs alongside normal work as a continuous background practice. The complementary `verify-done` skill runs at the done-claim checkpoint.

## What counts as a finding

Flag any of the following immediately:

```
[ ] Empty event handler           onClick={() => {}}  onSubmit={noop}  addEventListener("x", () => {})
[ ] Exported symbol, 0 callers    grep -r "MyFunc" src/ | grep -v test | wc -l == 0
[ ] Route returning stub data     res.json({ status: "ok" })  { note: "available when connected" }
[ ] Env var in .env.example not read anywhere in code
[ ] Catch block that swallows     catch (e) {}  except: pass  .catch(() => null)  catch { return [] }
[ ] "Coming soon" / placeholder text in UI, API response, or any user-facing surface
[ ] Conditional render behind always-false flag    if (false)  if (DISABLED_FLAG)  {/* TODO: enable */}
[ ] DB table with write path but no read path (or vice-versa)
[ ] Consumer type diverges from producer schema (naming, shape, envelope)
[ ] ID using per-scope-unique seed in a global key position
[ ] Any mismatch between "this advertises a feature" and "the feature does work end-to-end"
```

Not every item requires deep investigation. If you can see it by reading 10 lines of code, file it. If confirming it requires running the binary, note that in the issue body and file with an `evidence: needs-runtime-confirm` note.

## What NOT to do

- Do NOT add a `// TODO: fix later` comment in the file you are editing. A comment in a file you are already touching looks like a fix; it is not.
- Do NOT mentally note it without filing. Mental notes evaporate between sessions (the very problem this skill addresses).
- Do NOT expand the current PRs scope to fix the discovered fakework. Monster PRs are unreviewed PRs.
- Do NOT skip filing because the code belongs to another subsystem. The issue is a signal to whoever owns it; you are not volunteering to fix it.
- Do NOT bundle 5 findings into 1 issue ("billing has lots of problems"). Atomize. One issue = one root cause = one fixable unit.
- Do NOT silently subsume a finding into your current diff without filing. Even if you fix it inline: file the issue, note it is fixed in the same PR, close it at merge. The campaign log must be complete.

## How to file

**Title format**: match the repos commit convention.

```
fix(scope): imperative phrase describing what is broken
feat(scope): imperative phrase if it is missing functionality, not a bug
chore(scope): imperative phrase if it is cleanup with no behavior change
```

Examples:
- `fix(billing): webhook handler for updated.resumed event is missing`
- `fix(auth): catch block in validateToken swallows all errors silently`
- `feat(health): /health endpoint does not exercise external dependencies`

**Issue body template**:

```markdown
## Evidence
<!-- Paste the exact code snippet at file:line from current main.
     Do NOT paraphrase. Do NOT describe. Show the code. -->

## Repro
```bash
grep -n "catch (e) {}" apps/backend/src/webhooks/stripe.ts
# Expected: 0 matches (or: log.error before return)
# Actual:   line 42 — bare empty catch
```

## Impact
One sentence: what breaks, who notices, blast radius.

## Suggested fix
Concrete. If you do not know, say "decision needed: options A / B".

## Related
Part of billing-fakework campaign: #351 #362
```

**Labels** (create per-project if they do not exist):
- One severity: `priority: critical` | `priority: high` | `priority: medium` | `priority: low`
- One domain: `security` | `billing` | `frontend` | `persistence` | `observability` | etc.
- One campaign tag: e.g. `billing-fakework`, `auth-fakework` — use consistently so you can filter

## How to file during an agent run

1. Stop the current micro-task only long enough to call `gh issue create`.
2. Do NOT open a new branch. Do NOT write new code for the finding. Just file.
3. Note the issue number.
4. Continue your original task.
5. Add the issue number to your final report under "New issues filed (live mode)".

```bash
gh issue create \
  --title "fix(billing): webhook handler for updated.resumed is missing" \
  --body "## Evidence
// apps/backend/src/webhooks/stripe.ts:201
// updated.resumed: not handled — falls through to default no-op

## Repro
grep -n \"updated.resumed\" apps/backend/src/webhooks/stripe.ts

## Impact
Subscription resume events are dropped; customer billing state is never updated.

## Suggested fix
Add case for customer.subscription.updated with status === active after a pause.

## Related
Part of billing-fakework campaign: #351 #362" \
  --label "priority: high,billing,billing-fakework"
```

If the repo does not yet have the campaign label, create it first:

```bash
gh label create billing-fakework --color "#e4e669" --description "Billing fakework campaign"
```

## Handling "I found more fakework while fixing"

Two acceptable responses when you discover additional fakework while implementing a fix:

**Option A — Sibling issue (preferred when scope is clearly separate)**: File a new issue. Reference it from the current PR description. Continue the fix. The new issue goes into the backlog for a future PR.

**Option B — Scope amendment (acceptable when inseparable from the fix)**: Expand the current issues body with an explicit scope amendment comment: "Scope expanded to include X because it is mechanically coupled to the original fix." Update the PR title to reflect both. Do NOT silently absorb without updating the issue.

**Never**: fix it silently without filing anything, then close the original issue as if it were the only problem. This is how campaigns end up with gaps.

Counter-example: in PR #347 (billing-fakework campaign, Educando May 2026), the agent found a route-level fail-open at `billing.ts:446` while fixing the original issue. It was fixed in the same diff but no issue was filed. The fix landed, the problem is gone, but there is no audit trail: no blast-radius analysis, no `Related` cross-reference, and the campaign issue count is understated by 1. Small failure mode with real consequences at post-mortems.

## Verdict / output discipline

Every agent run report must include a "New issues filed (live mode)" section.

**If findings were made:**

```
New issues filed (live mode):
- #381 fix(billing): catch block in renewSubscription swallows all errors (billing-fakework)
- #382 fix(webhooks): updated.resumed handler is missing (billing-fakework)
```

**If no findings:**

```
New issues filed (live mode):
- None — no additional fakework discovered in scope reviewed (stripe.ts, subscription-service.ts, billing-router.ts).
```

The empty report is not a formality. It documents that you looked at those files and found nothing — positive evidence of quality. Empty reports also prevent "maybe the agent missed something" uncertainty in post-mortems.

## Case studies

### Case A — Educando billing-fakework campaign (May 2026)

Two audit agents ran a pre-implementation audit and filed 15 issues covering: empty Stripe webhook handlers, billing routes returning `{ status: "ok" }` without touching the database, subscription status fields read by the frontend but never written by the backend, and catch blocks that returned `200 OK` on payment failures.

During the fix-implementation waves, 1 additional issue (#365, missing `updated.resumed` handler) was surfaced inflight and filed correctly. One finding (`billing.ts:446` fail-open) was silently subsumed into PR #347 without a dedicated issue — the only failure-mode example in the campaign.

Inflight findings that WERE filed as issues took under 2 minutes each to document. The one that was NOT filed required retroactive audit to locate.

### Case B — LeyIA incident (April 2026)

During the LeyIA same-day MVP audit (`INCIDENT_LEYIA_2026-04-29.md`), pattern-search agents found 53 issues across 3 repos in ~25 minutes by dispatching systematically. The discipline of filing immediately rather than noting mentally was what allowed the session to produce a complete, actionable issue backlog — versus the GainShield incident (`FAKE_WORK_AUDIT.md`) where fakework accumulated silently over 3 months because nothing was ever filed.

The difference is not that LeyIA had fewer bugs (it had more). It is that LeyIA surfaced them the same day they were looked at, and every finding became an issue with an evidence trail.

## Relation to verify-* checkpoint skills

| Skill | When it runs | What it catches |
|---|---|---|
| `surfacing-fakework` (this) | Continuously, during ANY work | Whatever you can see while reading code |
| `verify-done` | At done-claim gate | Ghost symbols, missing call-sites, placeholders in diff |
| `verify-contract` | At integration-claim gate | Cross-layer schema drift, field name mismatch |
| `verify-storage` | At persistence-claim gate | Storage layers with no producer, split-brain read/write |
| `verify-identity` | At ID-stability-claim gate | Per-scope seeds used as global keys |
| `verify-honest-failure` | At error-handling-claim gate | Soft fallbacks with no observable signal |

The verify-* skills are audit tools. This skill is practice. Audits find what practice missed; practice reduces what audits need to find.

## References

- `guardrails/docs/FAKE_WORK_AUDIT.md` — GainShield: 60% ghost code, never surfaced until live hardware session
- `guardrails/docs/INCIDENT_LEYIA_2026-04-29.md` — LeyIA: 53 bugs, 0 ghosts; all cross-layer drift surfaced by inflight pattern search
- `guardrails/skills/verify-done.md` — checkpoint skill: done-claim gate
- `guardrails/skills/verify-contract.md` — checkpoint skill: cross-layer schema drift
- `guardrails/skills/verify-storage.md` — checkpoint skill: storage write/read continuity
- `guardrails/skills/verify-identity.md` — checkpoint skill: ID stability
- `guardrails/skills/verify-honest-failure.md` — checkpoint skill: observable error signals
