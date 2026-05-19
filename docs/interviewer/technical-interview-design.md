# Principal Data Engineer — Technical Interview Design

**Status:** Design (problems and execution layer locked; build TODO)
**Last updated:** 2026-05-17
**Role:** [Principal Data Engineer](https://job-boards.greenhouse.io/extend/jobs/5987927004)

## Format

- **Live, 60 minutes.** Candidate brings their own AI tools (Claude Code, Cursor, Codex, etc.).
- **Self-contained local repo.** Python (`uv` for env), dbt + DuckDB, no cloud infra.
- **Patterns mirror Extend's `dbt_snowflake` repo** — naming, layering, style, sqlfluff config.
- **Pre-interview setup** — candidate confirms Python version + `uv` ahead of time so the clock isn't burned on env setup.

## What we're testing (and what we're not)

**We are testing:**
- How the candidate **solves problems** with AI in the loop — do they research the repo first, ask the AI to explain before acting, verify claims, push back when something looks off
- How they **handle complex data models** — grain reasoning, blast radius, source reconciliation
- How they **communicate and collaborate** — do they ask before they assume, do they recognize when a problem wants a design rather than code

**We are explicitly not testing:**
- Raw coding speed (AI removes most of that signal)
- Greenfield wizardry (AI is great at greenfield; we picked existing code on purpose)
- SQL trivia or memorization

## Repo framing

**The candidate inherited this repo from a contractor.** This framing does several jobs at once: it justifies inconsistent doc quality, it gives implicit permission to question decisions and clean things up, and it makes "the code is wrong" feel diegetic ("finance flagged numbers look off") rather than gotcha-y.

The repo contains a generic e-commerce warehouse — orders, merchants, line items, shipments, refunds. We deliberately avoided Extend-adjacent domains (warranty / claims) so candidates with insurance background don't get a head start on schema comprehension. Every minute spent learning the domain is a minute not spent on the actual signal we're trying to gather; e-commerce is the universal donor.

Tables ship with **mixed documentation quality on purpose**:

- Some tables fully documented (the parts the contractor cared about)
- Some partially documented (a few columns explained, others bare)
- Some undocumented entirely (raw sources, especially)
- Cryptic enum values planted: `customer_type` = `B2B` / `B2C` / `MKT` (is `MKT` *marketplace* or *marketing*?), `tier` = `STD` / `ENT` / `PLT`, undocumented order and line statuses, an `is_test` flag mostly NULL with some TRUE/FALSE, a `revenue` field that doesn't say gross / net / with-tax

The undocumented surfaces are not laziness — they are a **deliberate test of whether the candidate asks or assumes**. AI tools always assume; this is the single highest-signal behavior to grade for someone who'll work alongside AI.

## Sequencing

**Problem 1 first, then Problem 2.**

The argument for 1 → 2 is twofold: schema familiarity from Problem 1 means Problem 2 doesn't waste time on orientation, and Problem 1 is a confidence-builder that lets the candidate find their footing. There's a counterargument — Problem 2 first while context is empty would more cleanly test whether they can engage a data model from a clean slate — but it costs us recovery time if the candidate gets rattled in the first minute.

There's a subtle bonus to 1 → 2: Problem 1 establishes a code-shipping rhythm. Problem 2 is shaped completely differently. The candidate who **notices the shape change and adjusts** is exactly the candidate we want. The one who keeps shipping reflexively is also giving us signal.

**Time budget (60 min):**
- 5 min — setup, orient, read the README
- ~15 min expected — Problem 1 (no hard cap; the real ceiling is "the candidate is satisfied")
- remainder (~35 min) — Problem 2
- 5 min — wrap, candidate questions

The asymmetric budget is deliberate. Problem 1 is a gatekeeper for AI-fluent engineers; expecting it to take 25 minutes signals to interviewers that struggling here = struggling against the floor. Most strong candidates will be done in 10–15. The remaining time lets Problem 2 breathe, which addresses the most fragile part of this design.

## Problem 1 — The grain bug (gatekeeper)

### What it tests

This is the **gatekeeper**. The bar: if you can't figure this out *with AI*, the role isn't going to work. We expect AI-fluent candidates to find and fix the bug; the differentiator is everything *around* the fix — boy scout instincts, how they interrogate the AI, whether they verify before trusting.

### The setup

`order_fact` is an incremental dbt model with `unique_key='order_id'`, joining `stg_orders` → `stg_shipments` → `stg_shipment_line_items` → `stg_line_items`, supposed to produce one row per order with total revenue. It's been in prod for a quarter.

### The trap

The contractor's mental model went: "join is fanning out → aggregate per shipment → I have multiple rows per order → I need one row per order → qualify to first shipment." Each step is locally reasonable. The collective error is that they took *one shipment's* revenue and called it the order's revenue. They wanted the first `shipped_at` as the order's metadata; they accidentally also took the first shipment's revenue.

Roughly:

```sql
shipment_totals as (
    -- aggregated to one row per (order, shipment)
    select
        order_id,
        shipment_id,
        shipped_at,
        sum(shipment_line_revenue) as shipment_revenue
    from joined
    group by 1, 2, 3
)

select
    order_id,
    shipped_at,
    -- dedupe to one row per order (orders can have multiple shipments)
    shipment_revenue as revenue
from shipment_totals
qualify row_number() over (partition by order_id order by shipped_at) = 1
```

Behaviors:
- **Single-shipment orders** — shipment revenue = order revenue. ✅
- **Multi-shipment orders** — shipment revenue < order revenue. **Silently under-counted.**
- **`unique` test on `order_id`** — passes. ✅
- **A custom warn-level reconciliation test** — fails (see "Entry ramp" below).

The `QUALIFY ROW_NUMBER()` line is doubly tricky because it's actually the **prescribed Extend dedup pattern** per the `dbt_snowflake` style guide. A candidate who pattern-matches "this is how we dedup here, must be fine" is being misled by a real convention.

The contractor's **comment is the real bait**: it reads as confident-correct mechanics ("dedupe to one row per order, orders can have multiple shipments") and is true at face value. What it doesn't reveal is that this isn't the right fix for the actual symptom. We deliberately did *not* leave a `TODO` — a confident-but-wrong contractor doesn't leave a "TODO figure out" comment, they leave a confident one-liner.

### Why AI struggles with this

AI sees "duplicate rows" and reaches for `DISTINCT` / `QUALIFY` / dedup — exactly what the previous contractor did. It treats the symptom. The real fix requires restructuring: separate "order revenue" (from line items, independent of shipment) from "first shipped_at" (from shipments). AI tools also rarely think to run a full-refresh-vs-incremental diff as a debugging step on their own initiative.

### Revenue definition (locked for Problem 1)

- **Gross of refunds.** Refunds aren't loaded yet — that's literally what Problem 2 introduces. This is also why finance is reconciling against Stripe captures, which are gross.
- **No tax, no shipping.** `unit_price * quantity` is the line revenue, full stop. Documented in the model description.
- **No discounts.** Seed data ships without any discount fields or promo logic. Documented explicitly in the model description so a candidate who asks "what about discounts?" gets a clean answer (none in this dataset). We have enough nuances to surface elsewhere; list-vs-purchase price isn't worth the complexity here.
- **Calculated from line items per order, *independent of shipment status*.** Unshipped orders should have a populated `revenue` and a NULL `shipped_at`.

This last bullet is what makes the structural fix the right one: revenue must come from line items per order; shipments are only for the `shipped_at` metadata.

### Entry ramp

The repo ships with a **custom warn-level reconciliation test** at `tests/order_fact_revenue_reconciliation.sql`, comparing `sum(order_fact.revenue)` to `sum(stg_line_items.quantity * stg_line_items.unit_price)` filtered to non-test orders. It comes back with a non-zero discrepancy. Severity: `warn`. **We do not tell the candidate this exists.**

A candidate who runs `dbt test` before touching anything finds it instantly. A candidate who dives straight into code does not. This is itself signal: *do they think about tests before they think about edits?* The `warn` severity means CI is green, so it doesn't scream. It points them at the join area without giving away the qualify line.

**Important grading nuance — what they do with the warn matters more than whether they saw it.** A candidate who runs `dbt test`, sees the warn, and shrugs ("probably nothing, moving on") is *worse* than a candidate who never ran the test but reasoned to the bug from the ticket's reconciliation hint. The rubric grades on **investigation**, not **command execution**. Running `dbt test` reflexively earns nothing on its own; engaging with what the test reveals is the actual signal.

The **ticket** the candidate sees is realistic and vague: *"Q1 live revenue from real merchants is off by ~$AMOUNT vs. our Stripe reconciliation. Can you take a look at `order_fact`?"* — direction unspecified, definition of revenue unspecified, reconciliation source mentioned but not detailed.

The phrase **"live revenue from real merchants"** is doing real work: it tells the candidate the comparison number excludes test orders (a thoughtful candidate parses "real merchants" as "not-test"). A candidate who narrows their investigation to non-test orders before computing the comparison number is doing the right thing — and then has to *also* find the qualify bug. Filtering test orders gets them *closer* but not matching. Two layers, both genuinely there.

The exact dollar amount is computed by the setup script and templated into the ticket so it always matches the data.

### Boy scout opportunities (bonus only — no penalty for missing)

Boy scout finds are **realism props that occasionally earn bonus signal but never penalize**. We do not grade on volume of finds, and we do not penalize a candidate for ignoring them. They exist primarily to make the repo feel real and to give thoughtful candidates a way to demonstrate taste.

Cheap-tier finds embedded in or near the model:
- Add the missing test that *would have caught this* — see "Test surface" below
- The contractor's comment reads as confident — a thoughtful refactor would either remove or accurately describe the dedup
- A `dbt source freshness` check on `stg_shipments` is commented out
- A stale `TODO` comment from the contractor on an unrelated model
- Style nits caught by `sqlfluff lint` on a different model (not `order_fact` — we don't want lint noise on the buggy file)
- Long lines, missing column descriptions on partially-documented YAML files

Bigger structural finds (e.g., the `shipped_at` smell, a dim that wants Type 2 history) belong in the *primary* rubric, not the boy-scout tier — they're discriminators, not bonus.

### Model column shape (~14 columns)

```
order_id              (pk)
merchant_id
merchant_name         (from lkp_merchants)
customer_id
customer_type         (from lkp_merchants — the cryptic B2B/B2C/MKT)
order_status          (the order-level status)
is_test
ordered_at
paid_at
shipped_at            (first shipment, where the qualify lives)
shipment_count        (count of distinct shipments per order)
line_count            (distinct line items in the order)
total_quantity        (sum of line item quantities)
revenue               (the buggy column — decimal dollars)
created_at_dwh
updated_at_dwh
```

`shipment_count` is a useful sanity-check column for the candidate: it's correct in the buggy structure, and noticing "wait, `shipment_count` is right but `revenue` is wrong" is a valid clue without being a giveaway.

### What "passing" looks like in 25 min

A strong candidate:
- Runs `dbt test` before touching anything → sees the `warn` failure
- Asks the AI to *explain* the model and the failing test before changing code
- Identifies the qualify-at-wrong-grain bug, not just the symptom
- Restructures the join (separates `order_revenue` from `order_first_ship`) rather than patching with another dedup
- Adds a regression test
- Mentions one or two boy-scout cleanups, either done or noted

Three valid fix shapes, ranked:
1. **Best (principal-tier):** Recognizes that `shipped_at` on an *order*-grain fact is the architectural smell that *enables* the bug. The fact is at order grain; shipment metadata being on it forces the contractor's mistake of "picking a shipment." Strong candidate proposes that revenue must be derived from line items per order with no shipment join at all, and `first_shipped_at` is a derived `min(shipped_at)` scalar — or even better, that shipment metadata wants to live on a `shipment_fact` and `order_fact` only carries derivations of it. Few candidates find this; recognizing it is a top-tier discriminator.
2. **Better (senior-tier):** Separate CTEs for `order_revenue` (from line items per order, no shipments) and `order_first_ship` (first `shipped_at` per order), then join. Cleanly separates concerns even if the candidate doesn't explicitly name the architectural smell.
3. **Acceptable:** Keep contractor's structure, replace qualify with `sum(shipment_revenue) over (partition by order_id)`. One-line surgical fix, correctly diagnoses the bug, but doesn't reflect the conceptual separation.

A weaker candidate:
- Dives straight into editing `order_fact`
- Asks AI for a "fix" without understanding the bug
- Reaches for another `DISTINCT` / `QUALIFY` / dedup, thinking the issue is duplicate rows
- Fixes the symptom and declares victory without comparing to a known-good number
- Doesn't notice or doesn't act on any boy-scout signals

### Test surface — what the candidate should add or notice is missing

The shipped reconciliation test is **detection-grade, not regression-grade**. An aggregate-sum reconciliation is brittle: errors can cancel, and once Problem 2 lands the refund-affected sides drift. The right *regression* test for a grain bug is **row-level parity**: per-order revenue equals the sum of its line items. A strong candidate writes (or proposes) something like:

```sql
-- per-order parity: order_fact.revenue must equal sum of its line items
select
    o.order_id,
    o.revenue as fact_revenue,
    li.expected_revenue
from {{ ref('order_fact') }} o
join (
    select order_id, sum(quantity * unit_price) as expected_revenue
    from {{ ref('stg_line_items') }}
    group by 1
) li on o.order_id = li.order_id
where abs(o.revenue - li.expected_revenue) > 0.01
```

Other tests a strong candidate adds or notices are missing:
- `not_null` on `revenue` (revenue should never be null per the locked definition; currently absent)
- `relationships` from `order_fact.order_id` to `stg_orders.order_id`
- `accepted_values` on `order_status` and `customer_type` — undocumented enums that warrant explicit acceptance lists
- Temporal sanity: `shipped_at >= ordered_at`, `shipped_at <= today`
- Internal consistency: `shipment_count >= 1 when shipped_at is not null`

A weaker candidate escalates the existing warn-level test to `error` and calls it done. That's a fix, not a regression test.

**Meta-discriminator on severity.** A strong candidate notices that `warn` for a revenue reconciliation is wrong as a real-warehouse pattern — that test should be `error`, period. A candidate who escalates `warn → error` as part of the fix has caught the meta-point. A candidate who leaves it at `warn` has missed it.

## Problem 2 — Refunds across messy sources (judgment problem)

### What it tests

This is the **principal-level judgment problem**. The technical surface is easy to describe and impossibly broad to actually solve in 25 minutes — which is the point. The signal is in **scoping, decomposition, and stakeholder collaboration**, not in code shipped.

### The setup

The candidate is asked to bring refund data into the warehouse and surface refund totals on `order_fact` and per-line refund amounts on `order_line_fact` (which exists pre-problem as a thin skeleton — one row per order line — that the candidate extends). Three raw sources, none with a unified `refund_id`, all describing the same underlying refund events at **different grains**:

- `raw.refunds_shopify` — line-level (`order_id`, `line_item_id`, `qty_refunded`, `amount_in_cents`, `refunded_at`), no tender info
- `raw.refunds_stripe` — payment-event-level (`order_id`, `tender_type`, `amount_in_cents`, `processed_at`), no line info
- `raw.refunds_internal_pos` — order-level only (`order_id`, `amount_in_cents`, `refunded_at`), one merchant's clunky POS

Different merchants use different subsets:

- 1 merchant uses Shopify only — clean line-level refunds
- 1 merchant uses Stripe only — clean tender-level refunds
- 1 merchant uses internal POS only — order-level refunds
- 1 merchant uses Shopify + Stripe — overlapping witnesses, the reconciliation puzzle
- 1 merchant has no refunds — sanity baseline

Among the refunds, deliberately small but rich texture:
- 2-3 split-tender refunds (CC + store credit), all on the Shopify + Stripe merchant
- 1-2 partial-line refunds (refund 1 of 3 of a quantity)
- 1 refund where order-level says "cancelled" but line-level says "fulfilled" (the cancel-vs-refund nuance)

### Why this is genuinely hard (for humans and AI)

The richness comes from **three orthogonal allocation problems stacked on the same data**, and recognizing they're orthogonal is itself the principal-level insight:

1. **Line allocation** — when refund data arrives at order grain (Stripe, internal POS), how do you populate `order_line_fact.refunded`? Pro-rata by revenue? By quantity? Tax-aware? Discount-aware?
2. **Tender allocation** — split-tender refund (e.g., $50 CC + $50 store credit for 3 items): which tender absorbs the refund matters. Store credit doesn't reduce cash revenue. CC refunds carry fees. Some merchants have ordering rules ("refund to CC first").
3. **Source reconciliation** — Shopify says "line 2 refunded $30." Stripe says "$30 to CC ending 4242." Internal POS just says "order refunded $30." Same money, three witnesses, no shared ID.

Each one alone is a good question. Stacking them is the real principal challenge: the candidate has to **decompose the problem before they can model it**. AI tools cannot do this decomposition unprompted — they will write a single model that conflates all three concerns and looks done.

### The ticket

*"Finance needs net revenue. Bring refunds into the warehouse and surface refund totals on `order_fact` and per-line refund amounts on `order_line_fact`. They want to reconcile against Stripe settlement reports."*

That's it. Definitions of "net revenue" are not provided. Allocation rules are not provided. Stakeholder priorities are not provided.

### What "passing" looks like

The deliverable is framed by the interviewer as: *"At the end, walk us through what you'd bring to the finance analytics team for sign-off before this hits prod."* This phrasing is **deliberately neutral on format** — code, design doc, whiteboard, slack message are all valid. It does not say "write a design doc" because the moment we say that, we've collapsed the test.

A strong candidate:
- Recognizes the problem shape is different from Problem 1 — this isn't a "fix the bug" task, it's a "design under ambiguity" task
- Asks the in-character stakeholder questions before writing code
- Decomposes the problem into the three allocation concerns
- Produces a design artifact (markdown, whiteboard, walkthrough) explicitly tailored to a finance analytics audience with basic data-modeling vocabulary
- Surfaces the major assumptions, the data nuances, the open questions — and which questions block prod vs which can be deferred
- If they ship code, they ship one **clean slice** (e.g., a `refund_fact` from Shopify only) with the rest as documented TODOs

A weaker candidate:
- Stays in code-shipping mode from Problem 1 and starts writing SQL immediately
- Builds a single model that conflates line / tender / source concerns
- Doesn't ask any questions; assumes pro-rata-by-revenue line allocation; assumes store credit refunds reduce revenue
- Finishes 100% of the wrong problem confidently

We're looking for **mode-switching**: did they recognize the shape change and adjust their approach, or did they reflexively keep doing what worked in Problem 1.

### How we make the right answer available without making it obvious

The hardest design question for this problem was: **how do we make a design-first answer appropriate but not the obvious right answer?** If we tell the candidate "write a design doc," we collapse the test — now they're picking from a menu instead of reading the room. The signal is *did they generate this option themselves.*

Five mechanisms, none sufficient alone, all working together:

1. **Frame the deliverable as an audience, not a format.** *"Walk us through what you'd bring to finance analytics for sign-off before this hits prod."* A thoughtful candidate hears "sign-off before prod" and works backwards. A reflexive candidate hears "walk us through" and assumes "show me what you built."

2. **Use Problem 1 to set a code-shipping rhythm, then let Problem 2 break it.** Problem 1 has a clear right answer that you implement and verify. Problem 2 is shaped completely differently — but the candidate doesn't know that yet. Whether they notice the shape change is itself the test.

3. **In-character stakeholder, silent by default.** The interviewer plays "Jamie from finance analytics, available on Slack for questions." If asked, Jamie answers in-character with realistic vagueness. If not asked, Jamie says nothing. Reflexively reaching for the stakeholder is a huge discriminator.

4. **Plant ambient signals that design-first is how this team works — without saying so.** A prior contractor design doc committed at `docs/designs/2024-Q3-orders-redesign.md`. A reference to "design review" in `CONTRIBUTING.md`. A PR template with a "design link" field. None of these *say* "you should write a design." They say "people who work here write designs."

   **The deeper purpose: testing AI-prompting maturity.** Ambient signals were challenged in review as "theater" on the basis that candidates under pressure don't read repo metadata. That critique misses something fundamental: **with AI in the loop, every committed file is reachable via a one-line prompt**. A weak candidate types `fix this` and the AI dives in blind. A strong candidate prompts `explore the codebase, understand the patterns and conventions, then propose an approach` — and the AI surfaces CONTRIBUTING, the prior design doc, the PR template, the sqlfluff config, all of it. The ambient signals therefore test something fundamentally more important than "does the candidate read the room": **does the candidate prompt their AI to read the room before doing work**. That is the actual AI-fluency signal we want for a principal hire.

   The signals serve a second purpose: they're **props for Jamie**. When asked "what's the expected process here," Jamie can point to precedent in-character ("like the design doc Sandra wrote in Q3"). Without the artifact, Jamie is asserting design culture from thin air. This reduces interviewer-calibration variance — Jamie's responses become grounded in committed artifacts rather than improvised.

5. **Grade on what they decided to produce and why, not on what they produced.** Two candidates can both end with zero SQL written — one is a strong pass (correctly diagnosed scope, delivered design + open questions), one is a fail (got lost, never started). Two candidates can both ship working SQL — one is a strong pass (asked questions, made tradeoffs explicit), one is a weak pass (built the wrong thing confidently).

The thing we explicitly **do not do** is offer "feel free to write a design doc instead of code" as a path. That collapses the test.

## Stakeholder character brief (for interviewer)

Lives as its own interviewer-only doc to keep calibration tight across interviewers. Without a brief, calibration drifts.

**Jamie, senior finance analyst.** Has a basic data-modeling vocabulary (knows what grain, fact, dim mean). Strong opinions on definitions but willing to be educated. Knows Stripe is the source of truth for cash but doesn't know what Shopify reports independently. Will **answer good questions** but **will not volunteer answers to questions not asked**.

Examples of in-character responses:
- *"What do you mean by net revenue?"* → "Good question. Gross of tax, but net of refunds. I'm not sure on shipping refunds, let me check — proceed assuming net of shipping for now."
- *"Should store-credit refunds reduce revenue?"* → "Hmm. I'd want them tracked separately so we can see both views, but for the headline number — exclude them. Cash refunds only."
- *"How do we want to handle the merchant on internal POS where we don't have line-level data?"* → "Honest answer? I don't know yet. What are the options?"
- *"Do we have payment data to reconcile original tender against refund tender?"* → "Yes but it's in a separate Stripe export we haven't loaded yet — out of scope for this iteration."
- (Unprompted, after silence) → nothing.

## Execution layer (locked)

### Stack

- **DuckDB** + `dbt-duckdb`. SQL dialect (incl. `QUALIFY`, window functions, CTEs) overlaps heavily with Snowflake — the qualify-at-wrong-grain trap works *exactly* as it would in Snowflake. Single-file database, fast on millions of rows, near-zero setup. SQLite was rejected because no `QUALIFY` (would break the trap); Postgres rejected because Docker setup adds friction with no upside.
- **`uv`** for Python env (per repo convention).
- **`dbt seed`** for loading raw CSVs. The `dbt_snowflake` "no seed" rule exists because of PII risk; here all data is fake, so the rule doesn't apply.
- **`.env`** committed at repo root with working values (`DBT_PROFILES_DIR=.`, `DBT_TARGET=dev`). No secrets to fill in. No copy step.
- **`Makefile`** (or shell shim) wraps `dbt` invocations so the candidate runs `make run` / `make test` / `make lint` and isn't fighting CLI flags. Optional but recommended.
- **`sqlfluff`** lifted from `dbt_snowflake/.sqlfluff`, adapted to DuckDB dialect. Config preserved verbatim except `dialect = duckdb` and `profile = dbt_duckdb`. Excluded rules preserved (`structure.column_order`, `structure.using`). The contractor's `order_fact.sql` **passes lint cleanly** — bug is logic, not style.

### Repo layout

```
models/
  orders/
    base/         base_orders.sql, base_shipments.sql, base_shipment_line_items.sql, base_line_items.sql
    staging/      stg_orders.sql, stg_shipments.sql, stg_shipment_line_items.sql, stg_line_items.sql
    dw/           order_fact.sql      # Problem 1 trap lives here
                  order_line_fact.sql # Problem 2 extends this skeleton
    reporting/    daily_revenue.sql   # downstream, surfaces blast radius
  merchants/
    base/         base_merchants.sql, base_products.sql
    staging/      stg_merchants.sql, stg_products.sql
    lookup/       lkp_merchants.sql, lkp_products.sql

raw/                  # ignored by git
  *.csv               # generated by setup script

setup/
  generate.py         # generate seed CSVs + load to DuckDB + render DATA-123.md
  sql.py              # agent-friendly SQL runner

tests/
  order_fact_revenue_reconciliation.sql  # warn-level, planted

macros/
  get_incremental_value.sql  # DuckDB-flavored shim of Extend's macro

docs/
  designs/
    2024-Q3-orders-redesign.md  # ambient design-first signal

.github/
  PULL_REQUEST_TEMPLATE.md      # has "Design link:" field

DATA-123.md               # the ticket — gitignored, rendered by setup script
DATA-123.md.tmpl          # committed template
.sqlfluff                 # adapted from dbt_snowflake
.sqlfluffignore           # adapted from dbt_snowflake
.env                      # committed with working values
CONTRIBUTING.md           # mentions design review
README.md                 # normal repo readme + setup
dbt_project.yml           # patterned on dbt_snowflake
profiles.yml              # in-repo, points to ./warehouse.duckdb
pyproject.toml            # uv-managed
Makefile                  # wraps dbt invocations
warehouse.duckdb          # gitignored, regenerated by setup
```

### Seed data

- **Volumes:** ~10k orders, ~12k shipments (~10–15% multi-shipment), ~25k line items, ~5k merchants, ~500 products. Generates and builds in seconds.
- **Time range:** 18 months. Multi-shipment cases planted to span month boundaries so incremental-vs-full-refresh can produce visibly different numbers.
- **Currency:** raw and base in `_in_cents` integers (matches Stripe API reality); staging onward in decimals. **No cents in fact tables.** Refund data follows the same pattern.
- **`is_test`:** ~95% NULL (legacy never backfilled), ~3% TRUE, ~2% FALSE. Realistic and a quiet ambiguity hook (NULL ≠ FALSE; AI assumes it does).
- **Order/line statuses:** order-level statuses (`pending`, `paid`, `shipped`, `partially_shipped`, `cancelled`, `partially_cancelled`, `refunded`, `partially_refunded`); line-level statuses (`pending`, `fulfilled`, `cancelled`, `refunded`). 5–10 **deliberately planted mismatches** between order-level and line-level status (logged in internal answer key). Asking about it = points; missing it doesn't block. ~85% of orders are clean; the other 15% holds the texture.
- **Ground-truth revenue number** for the ticket is computed at generation time and templated into `DATA-123.md`. Setup script is canonical source of truth; no hardcoded numbers drift.
- **Line-quantity ↔ shipment-quantity invariant.** For every line item, `sum(shipment_line_items.quantity_shipped)` across all shipments either equals `line_items.quantity` (fully shipped) or is strictly less (partially shipped, remainder pending). Never greater. The setup generator must enforce this; without it, the partial-shipment plant becomes incoherent and a sharp candidate will spot data inconsistency rather than the model bug.

### SQL runner

`uv run setup/sql.py "<query>"` — single-shot, agent-friendly, **read-only**. No `--limit` flag (forgetting `LIMIT` on a fact table query is itself a small judgment signal). No `--write` flag at all — the warehouse is built from models, full stop. This protects against an AI assistant "fixing" something by mutating DuckDB directly, which would be a quietly bad outcome.

DuckDB CLI suggested as a nicer optional path (`brew install duckdb`); candidates can also rely on the bundled Python `duckdb` dep installed by `uv sync`.

## Open design questions (parked)

- **Nudge protocol.** If a candidate is clearly drowning at minute 15 of Problem 2, do we send one in-character nudge to test recovery, or stay silent? Decision deferred until after dry runs.

## Internal rubric

Internal-only — not shown to candidates. Implementation correctness is **necessary but not sufficient**.

Five primary dimensions, weighted roughly equally:

1. **AI-prompting maturity** — does the candidate prompt the AI to *explore* the codebase, conventions, and prior designs before acting; ask the AI to *explain* before changing code; verify AI claims against actual code; push back when something looks off. This is the load-bearing AI-fluency signal: a weak candidate types `fix this` and watches; a strong candidate orchestrates the AI's investigation.
2. **Asks vs assumes** — questions to the in-character stakeholder, questions to clarify undocumented columns, questions about ambiguous requirements; vs reflexive assumption-making.
3. **Mode-switching** — recognizes Problem 2 has a different shape than Problem 1; doesn't reflexively ship code on the design problem.
4. **Modeling judgment** — for Problem 1: how cleanly is the bug diagnosed and fixed? Did they spot the architectural smell (`shipped_at` on the order fact) or merely patch the surface? For Problem 2: did they decompose the three orthogonal allocation concerns? Did they propose a `refund_fact` rather than dump columns onto `order_fact`?
5. **Scoping judgment** — punts thoughtfully with documented open questions vs ships the wrong thing confidently; gets a clean slice into prod-shape vs muddles through everything.

**Bonus (no penalty):**
- **Boy scout finds** — stale TODOs, commented source freshness, sqlfluff nits, undocumented columns. Realism props that occasionally earn signal but never penalize.

**Discriminators worth flagging in interviewer notes:**
- Did they investigate the warn-level test or shrug at it? (What they do with the warn matters more than whether they saw it.)
- Did they escalate the warn-level reconciliation test to `error` as part of the fix? (Meta-discriminator on test severity hygiene.)
- Did they write a row-level parity regression test, or just escalate the existing aggregate test?
- Did they identify `shipped_at` on `order_fact` as the architectural smell that enabled the bug? (Top-tier principal signal.)
- Did their Problem 2 design name testable invariants — reconciliation, allocation, source-overlap?

## Build checklist (near-complete)

Historical build record. Kept for reference; all implementation artifacts are in-repo, with dry-run still pending.

- [x] Seed generator (`setup/generate.py`) — emits CSVs, loads to DuckDB, renders `DATA-123.md` from template, logs internal answer key
- [x] SQL runner (`setup/sql.py`) — read-only, single-shot, agent-friendly
- [x] dbt project — `dbt_project.yml`, `profiles.yml`, macros, models for both `orders/` and `merchants/` subprojects, mixed-quality YAML docs
- [x] Planted trap in `order_fact.sql` with realistic ~14-column shape, confident contractor comment, no TODO
- [x] Warn-level reconciliation test
- [x] Cheap-tier boy scout opportunities: stale TODO on an unrelated model, commented source freshness, documentation gaps, lint nits on a non-`order_fact` file
- [x] Adapted `.sqlfluff` config (DuckDB dialect)
- [x] `docs/designs/2024-Q3-orders-redesign.md` — ambient design-first signal
- [x] PR template with "Design link" field
- [x] `CONTRIBUTING.md` with design-review reference
- [x] Candidate-facing `README.md`
- [x] Interviewer-only stakeholder character brief
- [ ] Dry-run with one or two internal engineers before going live
```