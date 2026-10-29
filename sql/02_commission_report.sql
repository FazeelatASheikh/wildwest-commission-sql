/* 02_commission_report.sql

   The monthly commission report for Wild West AB, January to August 2024.
   Run 01_clean_tables.sql first, because this file reads the clean tables it makes.

   The idea: I do not try to write one big query. I build the answer in small steps with CTEs
   (the WITH ... AS parts). Every step uses the one before it, and every step can be run alone
   if I put a SELECT * FROM <step name> under it. That is how I checked each step.

   The rules from the brief
     1. The policy has the portfolio code WILDWEST-2 or WILDWEST-3.
     2. It had that code for its whole life.
     3. The premium is paid.
     4. Only Product 1 to 8 and Product 13 to 31.
     5. Outbound and Internet sales need WILDWEST-3. Inbound sales need WILDWEST-2.
     Commission: 12 percent of the annual premium for the first 1500 policies, 14 percent from
     policy number 1501.
     Clawback: if a policy is cancelled in the middle of its term, we only keep the commission
     for the days it was active. The rest goes back to the insurance company.

   What I assumed, because the brief does not say
     A1. One paid row in Portfolio (one Key_Policy) is one policy.
     A2. "The first 1500" are counted over all eligible policies, in the order they were paid
         (PaymentDate, then Sales_Date, then Key_Policy so the order is the same every time).
         The count does not start again each month. If it did, nobody would ever reach the 14
         percent rate, because no month has 1500 policies.
     A3. A commission belongs to the month of the PaymentDate.
     A4. The term of a policy runs from Bnd_Dt to Rnew_Dt. If there is no Rnew_Dt, I use
         Pln_End_Dt plus one day.
     A5. A cancellation is saved on a separate policy row (status CANCEL, same policy number),
         not on the paid row. So I look it up by policy number.
     A6. I show the clawback in the same month as the commission. That keeps the report simple.
*/

DECLARE @ReportStart date = '2024-01-01';
DECLARE @ReportEnd   date = '2024-09-01';   -- the end date is not included, so this is up to 31 August

WITH PolicyCodes AS (
    /* Step 1. One row per policy number.
       Policy_Transactions has many rows for each policy (one for every action on it).
       I count how many different portfolio codes each policy number has ever had.
       If it is only one, the policy had the same code for its whole life (rule 2).
       Empty_Codes counts transactions with no code at all. Those would mean the policy was
       not marked at that time, so I do not accept them. */
    SELECT  Po_No,
            MIN(Pev_PortfolioResponsibleCode)             AS Portfolio_Code,
            COUNT(DISTINCT Pev_PortfolioResponsibleCode)  AS Number_Of_Codes,
            SUM(CASE WHEN Pev_PortfolioResponsibleCode IS NULL THEN 1 ELSE 0 END) AS Empty_Codes
    FROM    dbo.Policy_Transactions
    GROUP BY Po_No
),
EligiblePolicies AS (
    /* Step 2. Keep the policies that follow rules 1 to 5.
       Portfolio_Clean is the sale (premium, product, payment).
       Policy_Clean has the dates of the policy.
       Sales_Org tells which sales channel sold it.
       PolicyCodes has the code. Because PolicyCodes has one row per policy number, this join
       does not make extra rows. */
    SELECT  s.Key_Policy,
            p.Ext_Refr,
            o.Org_Lvl_Nm,
            c.Portfolio_Code,
            s.Product_Name,
            s.Sales_Date,
            s.PaymentDate,
            s.Annual_Premium,
            p.Bnd_Dt                                             AS Term_Start,
            COALESCE(p.Rnew_Dt, DATEADD(day, 1, p.Pln_End_Dt))   AS Term_End
    FROM    dbo.Portfolio_Clean AS s
    JOIN    dbo.Policy_Clean    AS p ON p.Key_Policy = s.Key_Policy
    JOIN    dbo.Sales_Org       AS o ON o.Key_SS_Org = s.Key_SS_Org
    JOIN    PolicyCodes         AS c ON c.Po_No      = p.Ext_Refr
    WHERE   s.Payment_Status = 'Paid'                                            -- rule 3
      AND   (s.Product_No BETWEEN 1 AND 8 OR s.Product_No BETWEEN 13 AND 31)     -- rule 4
      AND   c.Number_Of_Codes = 1 AND c.Empty_Codes = 0                          -- rule 2
      AND   c.Portfolio_Code IN ('WILDWEST-2', 'WILDWEST-3')                     -- rule 1
      AND   (   (o.Org_Lvl_Nm IN ('Outbound', 'Internet') AND c.Portfolio_Code = 'WILDWEST-3')   -- rule 5
             OR (o.Org_Lvl_Nm = 'Inbound'                 AND c.Portfolio_Code = 'WILDWEST-2'))
),
RankedPolicies AS (
    /* Step 3. Number the policies and find the cancellations.
       ROW_NUMBER() OVER (ORDER BY ...) is a window function. It gives the first paid policy
       number 1, the next number 2, and so on, without removing any rows.
       The part in brackets further down is a subquery. For each policy it looks in
       Policy_Clean for a CANCEL row with the same policy number, and takes the latest
       cancellation date that falls inside the term. If there is none, the result is NULL. */
    SELECT  e.*,
            ROW_NUMBER() OVER (ORDER BY e.PaymentDate, e.Sales_Date, e.Key_Policy) AS Policy_Rank,
            DATEDIFF(day, e.Term_Start, e.Term_End)                                AS Term_Days,
            (SELECT MAX(x.Cncl_Dt)
             FROM   dbo.Policy_Clean AS x
             WHERE  x.Ext_Refr    = e.Ext_Refr
               AND  x.Agrm_Sts_Cd = 'CANCEL'
               AND  x.Cncl_Dt >= e.Term_Start
               AND  x.Cncl_Dt <  e.Term_End)                                       AS Cancel_Dt
    FROM    EligiblePolicies AS e
),
PricedPolicies AS (
    /* Step 4. The commission rate and the number of days the policy was active.
       Policy_Rank 1 to 1500 gets 12 percent, the rest gets 14 percent.
       If the policy was cancelled, the active days are from the start of the term to the
       cancellation day (the +1 counts the cancellation day too). If it was not cancelled,
       the active days are the whole term. */
    SELECT  r.*,
            CASE WHEN r.Policy_Rank <= 1500 THEN 0.12 ELSE 0.14 END                AS Commission_Rate,
            CASE WHEN r.Cancel_Dt IS NULL THEN r.Term_Days
                 ELSE DATEDIFF(day, r.Term_Start, r.Cancel_Dt) + 1 END             AS Active_Days
    FROM    RankedPolicies AS r
),
CommissionPerPolicy AS (
    /* Step 5. The money for each policy.
       Commission is the premium times the rate.
       Clawback is the share of the commission for the days the policy was NOT active:
       commission * (term days - active days) / term days.
       A policy that was not cancelled has no clawback, so I set it to 0. */
    SELECT  q.*,
            ROUND(q.Annual_Premium * q.Commission_Rate, 2)                        AS Commission,
            CASE WHEN q.Cancel_Dt IS NULL THEN 0
                 ELSE ROUND(q.Annual_Premium * q.Commission_Rate
                            * (q.Term_Days - q.Active_Days) / q.Term_Days, 2)
            END                                                                   AS Clawback
    FROM    PricedPolicies AS q
)
/* Step 6. The report. One row per month.
   The date filter is here at the end and not earlier, because the rank has to be counted
   from the first eligible policy. If I filtered to 2024 earlier, the ranking would start
   at the wrong place. */
SELECT  YEAR(PaymentDate)                                          AS [Year],
        MONTH(PaymentDate)                                         AS [Month],
        COUNT(*)                                                   AS Policies,
        SUM(CASE WHEN Commission_Rate = 0.12 THEN 1 ELSE 0 END)    AS Policies_At_12pct,
        SUM(CASE WHEN Commission_Rate = 0.14 THEN 1 ELSE 0 END)    AS Policies_At_14pct,
        SUM(Annual_Premium)                                        AS Annual_Premium,
        SUM(Commission)                                            AS Gross_Commission,
        SUM(CASE WHEN Cancel_Dt IS NOT NULL THEN 1 ELSE 0 END)     AS Cancelled_Policies,
        CAST(SUM(Clawback) AS decimal(18,2))                       AS Clawback,
        CAST(SUM(Commission) - SUM(Clawback) AS decimal(18,2))     AS Net_Commission
FROM    CommissionPerPolicy
WHERE   PaymentDate >= @ReportStart AND PaymentDate < @ReportEnd
GROUP BY YEAR(PaymentDate), MONTH(PaymentDate)
ORDER BY [Year], [Month];
