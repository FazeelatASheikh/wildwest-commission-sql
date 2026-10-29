/* 04_extra_analysis.sql

   Extra analysis: where does the clawback come from?
   The brief gives extra points for more analysis of the monthly data, and the clawback is the
   part of the commission that is easiest to lose, so I looked at it more closely.

   Run 01 first. This file uses the same steps as 02_commission_report.sql (I copied the CTEs),
   but it saves the result of the last step in a temporary table called #Policies. A CTE only
   works for one query, and I want to run four different queries on the same result.
   A temporary table (the # in front) disappears when I close the query window.

   Only policies paid from January to August 2024 are used, the same as in the report.
   The rank for the 1500 limit is still counted from the first eligible policy, as in 02.
*/

DECLARE @ReportStart date = '2024-01-01';
DECLARE @ReportEnd   date = '2024-09-01';

DROP TABLE IF EXISTS #Policies;

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

SELECT  *
INTO    #Policies
FROM    CommissionPerPolicy
WHERE   PaymentDate >= @ReportStart AND PaymentDate < @ReportEnd;


/* Question 1. Which sales channel do the policies come from?
   Look at how many policies each channel has before comparing the rates. */
SELECT  Org_Lvl_Nm                                                    AS Sales_Channel,
        COUNT(*)                                                      AS Policies,
        SUM(CASE WHEN Cancel_Dt IS NOT NULL THEN 1 ELSE 0 END)        AS Cancelled,
        CAST(100.0 * SUM(CASE WHEN Cancel_Dt IS NOT NULL THEN 1 ELSE 0 END)
                   / COUNT(*) AS decimal(5,2))                        AS Cancel_Rate_Pct,
        CAST(SUM(Commission) AS decimal(18,2))                        AS Gross_Commission,
        CAST(SUM(Clawback) AS decimal(18,2))                          AS Clawback,
        CAST(100.0 * SUM(Clawback) / SUM(Commission) AS decimal(5,2)) AS Clawback_Pct_Of_Commission
FROM    #Policies
GROUP BY Org_Lvl_Nm
ORDER BY Policies DESC;


/* Question 2. Which products give the biggest clawback? (top 10) */
SELECT  TOP 10
        Product_Name,
        COUNT(*)                                                      AS Policies,
        SUM(CASE WHEN Cancel_Dt IS NOT NULL THEN 1 ELSE 0 END)        AS Cancelled,
        CAST(100.0 * SUM(CASE WHEN Cancel_Dt IS NOT NULL THEN 1 ELSE 0 END)
                   / COUNT(*) AS decimal(5,2))                        AS Cancel_Rate_Pct,
        CAST(SUM(Commission) AS decimal(18,2))                        AS Gross_Commission,
        CAST(SUM(Clawback) AS decimal(18,2))                          AS Clawback
FROM    #Policies
GROUP BY Product_Name
ORDER BY SUM(Clawback) DESC;


/* Question 3. How fast do customers cancel, and what does it cost?
   Active_Days is the number of days the policy was active before it was cancelled.
   A policy that is cancelled early gives back more of its commission. */
SELECT  CASE WHEN Active_Days <= 30  THEN '1. Up to 30 days'
             WHEN Active_Days <= 90  THEN '2. 31 to 90 days'
             WHEN Active_Days <= 180 THEN '3. 91 to 180 days'
             ELSE                         '4. Over 180 days' END      AS Active_Before_Cancel,
        COUNT(*)                                                      AS Cancelled_Policies,
        CAST(SUM(Clawback) AS decimal(18,2))                          AS Clawback,
        CAST(AVG(Clawback) AS decimal(18,2))                          AS Avg_Clawback_Per_Policy
FROM    #Policies
WHERE   Cancel_Dt IS NOT NULL
GROUP BY CASE WHEN Active_Days <= 30  THEN '1. Up to 30 days'
              WHEN Active_Days <= 90  THEN '2. 31 to 90 days'
              WHEN Active_Days <= 180 THEN '3. 91 to 180 days'
              ELSE                         '4. Over 180 days' END
ORDER BY Active_Before_Cancel;


/* Question 4. Does the cancel rate change by payment month?
   Be careful when reading this. A policy paid in January has had more time to be cancelled
   than a policy paid in August, so the later months look better than they are. */
SELECT  DATEFROMPARTS(YEAR(PaymentDate), MONTH(PaymentDate), 1)       AS Payment_Month,
        COUNT(*)                                                      AS Policies,
        SUM(CASE WHEN Cancel_Dt IS NOT NULL THEN 1 ELSE 0 END)        AS Cancelled,
        CAST(100.0 * SUM(CASE WHEN Cancel_Dt IS NOT NULL THEN 1 ELSE 0 END)
                   / COUNT(*) AS decimal(5,2))                        AS Cancel_Rate_Pct
FROM    #Policies
GROUP BY DATEFROMPARTS(YEAR(PaymentDate), MONTH(PaymentDate), 1)
ORDER BY Payment_Month;
