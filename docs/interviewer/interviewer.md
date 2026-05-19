# Interviewer Run Sheet

**Internal only — do not share with candidates.** Use this *during* the live 60-minute Principal Data Engineer interview. Post-call PR grading lives in [`pr-grading-rubric.md`](./pr-grading-rubric.md).

<!-- MAINTAINER NOTE: The reconciliation amount $12,989,886.01 is hardcoded in
two places below — Jamie's Q&A row and the Problem 1 opening script. If you
regenerate seeds (`make seed`), update both to match `answer-key.md`. -->


---

## Before the call (~10 min)

1. **Instruct the candidate to clone the repo and run setup:**
   ```bash
   uv sync
   make setup
   ```
   Candidate runs this; you do not need to.

2. **Re-read** [`stakeholder-brief-jamie.md`](./stakeholder-brief-jamie.md) for posture. The Jamie quote table below is the in-call cheat sheet.

3. **Onboarding (one-time):** read [`technical-interview-design.md`](./technical-interview-design.md) and [`pr-grading-rubric.md`](./pr-grading-rubric.md) once.

---

## Time budget (60 min)

| Minutes | Phase | Notes |
|---|---|---|
| 0–5 | Setup & orient | Candidate reads `README.md` and `DATA-123.md`. Don't fill silence. |
| 5–20 | Problem 1 (grain bug) | **Target: ~15 min.** If still working at 20, let it run to ~30 — but it eats P2 time. 25+ min on P1 = "struggling against the floor." |
| 20–55 | Problem 2 (refunds) | **Protect this block.** P2 is the design problem and the Principal signal. Asymmetric budget is deliberate. |
| 55–60 | Wrap + candidate Qs | Hard stop. |

P1 sets a code-shipping rhythm; P2 deliberately breaks it. **Whether the candidate notices the shape change is itself the test.**

---

## Jamie (in-character stakeholder)

- **Default posture: silent.** Respond when asked, do not volunteer.
- **Do not lead** to the bug, to "write a design doc", or to ambient signals.
- **Out-of-scope deflections:** tax, shipping refunds beyond "net of shipping", the unloaded Stripe payment export, any merchant outside the seeded set.

**If asked, respond verbatim (or close to it):**

| Candidate asks | Jamie says |
|---|---|
| *"What do you mean by net revenue?"* | "Good question. Gross of tax, but net of refunds. I'm honestly not sure on shipping refunds — proceed assuming net of shipping for now." |
| *"Should store-credit refunds reduce revenue?"* | "Hmm. I'd want them tracked separately so we can see both views, but for the headline number — exclude them. Cash refunds only." |
| *"How do we handle the merchant on internal POS where we don't have line-level data?"* | "Honest answer? I don't know yet. What are the options?" |
| *"Do we have payment data to reconcile original tender against refund tender?"* | "Yes, but it's in a separate Stripe export we haven't loaded yet — out of scope for this iteration." |
| *"What's the expected reconciliation number?"* (P1) | "My captures show \$12,989,886.01 for real merchants in the relevant period." |
| *"Is a design doc expected?"* | "Yeah, this team usually does design review before non-trivial work hits prod. There's a doc Sandra wrote in Q3 (`docs/designs/2024-Q3-orders-redesign.md`) that's a good template." |

---

## Problem 1 — the grain bug

**Opening script (verbatim, after candidate has read `README.md` and `DATA-123.md`):**

> *"Q1 live revenue from real merchants is coming in below our Stripe captures of ~\$12,989,886.01. Can you take a look at `order_fact`?"*

Then stop. Do not say where the bug is. Do not mention `dbt test`.

**Cross-check data:**
- Bug location: `models/orders/dw/order_fact.sql` — revenue computed by `qualify`-ing at the wrong grain.
- True non-test revenue after fix: see [`answer-key.md`](./answer-key.md).
- Verify with: `make sql Q="select sum(revenue) from main_orders_dw.order_fact where not coalesce(is_test, false)"`
- Reconciliation test passing (was warn): `make test`

**Watch for (jot in notes for post-call rubric):**
- Did they run `dbt test` before editing, or dive in?
- What did they do with the warn-level test? (Investigated / shrugged / escalated to error.)
- Did they write a row-level parity regression test?
- Did they identify the `shipped_at`-on-order-fact architectural smell? *(Top-tier principal signal.)*

---

## Problem 2 — refunds across messy sources

**Opening script (verbatim, transitioning from P1):**

> *"Okay, let's move on. Finance needs net revenue. Your task is to bring refunds into the warehouse and surface refund totals on `order_fact` and per-line refund amounts on `order_line_fact`. They want to be able to reconcile against Stripe settlement reports. Jamie from finance analytics is available on Slack if you have questions."*

Then stop. Do not add context. Do not say "write a design doc." Do not say "this one's more open-ended." Silence is load-bearing.

**Closing deliverable ask (~5 min left, or when they're wrapping up):**

> *"Before we close out — walk us through what you'd bring to the finance analytics team for sign-off before this hits prod."*

**Deliberately format-neutral** — code, design doc, whiteboard, Slack message all valid. **Do not** say "write a design doc" — that collapses the test.

**Cross-check data:** Cross-check candidate's work against the planted refund cases in [`answer-key.md`](./answer-key.md). Patterns to verify: Shopify partial-line refund, internal_pos order-level refund (line statuses still 'fulfilled'), shopify_stripe split-tender (card + store_credit).

Status mismatches in the `O000001`–`O000008` range are planted separately (order/line status conflicts) — see [`answer-key.md`](./answer-key.md) for the canonical list. Bonus if the candidate surfaces them.

**Watch for (jot in notes for post-call rubric):**
- **Mode-switching:** recognized the shape change, or kept shipping reflexively?
- Did they ask Jamie a substantive question before writing code?
- Did they decompose into line / tender / source allocation concerns?

---

## After the call

**Ask the candidate to open a PR with their changes.** Then:

1. Fill in [`section-b-notes-template.md`](./section-b-notes-template.md) while context is fresh — focus on Section B of [`pr-grading-rubric.md`](./pr-grading-rubric.md): AI-prompting maturity, asks-vs-assumes, mode-switching. Specific quotes/moments are gold.
2. Hand the PR + your notes + [`pr-grading-rubric.md`](./pr-grading-rubric.md) to a grading agent for a 1–5 score per criterion and hire recommendation.
3. Calibrate: did any of your responses (especially as Jamie) nudge them off-frame? Note for next time.

