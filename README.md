# Wild West AB: commission and clawback report in SQL

A SQL project from Data Analysis & Infrastructure at Hyper Island. The task is to calculate the monthly commissions that an insurance company pays to a partner, Wild West AB, for January to August 2024.

The data comes from the course case and is not in this repo.

## The task

The insurance company pays Wild West AB a commission for the policies they sell, but only if the policy follows some rules:

1. The policy has portfolio code WILDWEST-2 or WILDWEST-3
2. ...and it had that code for its whole life
3. The premium is paid
4. The product is Product 1 to 8 or Product 13 to 31
5. Outbound and Internet sales need WILDWEST-3, Inbound sales need WILDWEST-2

The commission is 12% of the annual premium for the first 1500 policies and 14% from policy 1501. If a policy is cancelled in the middle of its term, only the share that matches the days it was active is kept. The rest is a clawback.

The data has four tables: `Portfolio`, `Policy`, `Policy_Transactions` and `Sales_Org`.

## What is in this repo

| File | What it does |
|---|---|
| `sql/01_clean_tables.sql` | Makes clean copies of the raw tables with real dates and numbers |
| `sql/02_commission_report.sql` | The monthly report, built step by step with CTEs |
| `sql/03_checks.sql` | Checks: how many sales are left after each rule, and the row-count problem below |
| `sql/04_extra_analysis.sql` | Extra analysis of the clawback by channel, product and how fast customers cancel |

Run them in this order in SQL Server Management Studio, in a database called `WildWest`. File 04 is the extra analysis, and it needs 01 to be run first.

## How the report is built

- **Cleaning first.** The raw tables are text. Dates are text, empty dates are `''`, and the premium has a decimal comma (`5719,00000000`). I used `TRY_CONVERT`, `NULLIF` and `REPLACE` to make a clean copy.
- **Rule 2 with a CTE.** One row per policy number, with a count of the different portfolio codes it ever had. If the count is 1, the policy had the same code for its whole life.
- **Joins.** Portfolio, Policy, Sales_Org and the code CTE are joined, and the rules 1 to 5 are in the `WHERE`.
- **Window function.** `ROW_NUMBER()` numbers the policies in the order they were paid. Number 1500 is the last one at 12%.
- **Subquery.** A cancellation is saved on a separate policy row with the status CANCEL. A subquery finds the cancellation date for each policy number.
- **Clawback.** `commission * (term days - active days) / term days`.

## A mistake I found in my first version

My first version joined the transactions straight onto the policies and grouped by the transaction time. A policy number can have many transactions, so one policy became several rows. Between January and August the query counted about 6,500 policies, but there are only 4,569 different ones. The count and the commission were too high. I fixed it by first making one row per policy number (the CTE in step 1) and then joining.

## My assumptions

The brief does not say these things, so I chose and I wrote them in the code:

- One paid row in `Portfolio` (one `Key_Policy`) is one policy.
- "The first 1500" is counted over all eligible policies in the order they were paid. It does not start again each month. If it did, the 14% rate would never be used, because no month has 1500 policies.
- A commission belongs to the month of the payment date.
- The policy term runs from `Bnd_Dt` to `Rnew_Dt`.
- The clawback is shown in the same month as the commission.

Other choices would give other numbers. For example, with the count restarting each month, the total gross commission for the period would be about 10% lower.

## Result

| Month | Policies | At 14% | Gross commission | Clawback | Net commission |
|---|---|---|---|---|---|
| Jan 2024 | 37 | 0 | 18,336 | 1,040 | 17,295 |
| Feb 2024 | 279 | 0 | 158,756 | 14,645 | 144,111 |
| Mar 2024 | 374 | 0 | 246,371 | 32,319 | 214,051 |
| Apr 2024 | 596 | 0 | 305,386 | 27,198 | 278,188 |
| May 2024 | 806 | 620 | 423,236 | 50,677 | 372,559 |
| Jun 2024 | 834 | 834 | 453,250 | 44,707 | 408,543 |
| Jul 2024 | 843 | 843 | 455,417 | 42,100 | 413,317 |
| Aug 2024 | 800 | 800 | 456,479 | 38,730 | 417,749 |
| **Total** | **4,569** | **3,097** | **2,517,232** | **251,417** | **2,265,815** |

The 1500th policy is reached in May, so the 14% rate starts in the middle of that month. About 12% of the policies were cancelled before the end of their term.

## What the checks show

`03_checks.sql` counts how many sales are left after each rule:

| Step | Rows left |
|---|---|
| All rows in Portfolio | 214,900 |
| Premium is paid | 168,442 |
| Product 1 to 8 and 13 to 31 | 167,477 |
| WILDWEST-2 or 3 for the whole life | 12,634 |
| Channel matches the code (eligible) | 5,911 |

Rules 1 and 2 remove most of the sales. Only about 7.5% of the paid sales in the right products had a WILDWEST code for their whole life. The clawback is about 10% of the gross commission.

## Extra analysis: where the clawback comes from

The brief gives extra points for more analysis, so I looked at the clawback in `04_extra_analysis.sql`.

- **Almost everything is Inbound.** Of the 4,569 policies, 4,567 are Inbound and 2 are Outbound. There are none from Internet. So a comparison between channels says nothing here.
- **One product dominates.** Product 22 has 2,489 policies and about 75% of the clawback (188,278 of 251,417). Its cancel rate (12.9%) is close to the average, so it is the size of the product that matters, not that it cancels more.
- **Some small products cancel much more.** Product 13 (11 policies) has 45% cancelled and Product 15 (41 policies) has 32%. These are small numbers, so I do not draw a conclusion from them.
- **Early cancellations cost the most.** 143 of the 554 cancelled policies (26%) were cancelled within 30 days, and they make up 97,647 of the clawback (39%). The typical cancelled policy was active about 71 days.

## Limits

- The brief does not say how to treat a policy that is cancelled before it is paid. I did not make a special rule for it.
- The clawback depends on my choice of term dates (assumption above).
- I did not check the numbers against an answer from the course, so they are my reading of the rules.

## About the work

This was a group project at Hyper Island and the deliverable was a presentation. The SQL here is my version. I used an AI assistant to review my query, find the row-count problem and tidy the final scripts. I checked the logic myself.

## Not in the repo

The data and the course brief are not included, because they belong to the course. The scripts show the table and column names, so you can see the structure.
