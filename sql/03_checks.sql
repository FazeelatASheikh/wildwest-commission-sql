/* 03_checks.sql
   Step 3: checks on the report. Run after 02_commission_report.sql.

   Check 1 shows how many sales are left after each rule.
   Check 2 shows why I count policies per Key_Policy and not per transaction.
*/

/* Check 1: how many paid sales survive each rule? (the same rules as in the report) */
WITH PolicyCodes AS (
    SELECT  Po_No,
            MIN(Pev_PortfolioResponsibleCode)            AS Portfolio_Code,
            COUNT(DISTINCT Pev_PortfolioResponsibleCode) AS Number_Of_Codes,
            SUM(CASE WHEN Pev_PortfolioResponsibleCode IS NULL THEN 1 ELSE 0 END) AS Empty_Codes
    FROM    dbo.Policy_Transactions
    GROUP BY Po_No
),
Flags AS (
    SELECT  CASE WHEN s.Payment_Status = 'Paid' THEN 1 ELSE 0 END                          AS f_paid,
            CASE WHEN s.Product_No BETWEEN 1 AND 8 OR s.Product_No BETWEEN 13 AND 31
                 THEN 1 ELSE 0 END                                                         AS f_product,
            CASE WHEN c.Number_Of_Codes = 1 AND c.Empty_Codes = 0
                  AND c.Portfolio_Code IN ('WILDWEST-2', 'WILDWEST-3') THEN 1 ELSE 0 END   AS f_code,
            CASE WHEN (o.Org_Lvl_Nm IN ('Outbound', 'Internet') AND c.Portfolio_Code = 'WILDWEST-3')
                   OR (o.Org_Lvl_Nm = 'Inbound'                 AND c.Portfolio_Code = 'WILDWEST-2')
                 THEN 1 ELSE 0 END                                                         AS f_channel
    FROM    dbo.Portfolio_Clean AS s
    LEFT JOIN dbo.Policy_Clean  AS p ON p.Key_Policy = s.Key_Policy
    LEFT JOIN dbo.Sales_Org     AS o ON o.Key_SS_Org = s.Key_SS_Org
    LEFT JOIN PolicyCodes       AS c ON c.Po_No      = p.Ext_Refr
)
SELECT 1 AS Step, 'All rows in Portfolio'                       AS Rule_Applied, COUNT(*) AS Rows_Left FROM Flags
UNION ALL
SELECT 2, 'Rule 3: premium is paid',                            SUM(f_paid) FROM Flags
UNION ALL
SELECT 3, 'Rule 4: product 1 to 8 and 13 to 31',                SUM(f_paid * f_product) FROM Flags
UNION ALL
SELECT 4, 'Rules 1 and 2: only WILDWEST-2 or 3, whole life',    SUM(f_paid * f_product * f_code) FROM Flags
UNION ALL
SELECT 5, 'Rule 5: channel matches the code (eligible)',        SUM(f_paid * f_product * f_code * f_channel) FROM Flags
ORDER BY Step;

/* Check 2: a policy number can have many transactions.
   If I join the transactions straight onto the policies, one policy becomes many rows
   and the count and the commission get too high. This query shows how many.  */
SELECT  COUNT(*)                   AS Transactions_With_WildWest_Code,
        COUNT(DISTINCT Po_No)      AS Different_Policy_Numbers
FROM    dbo.Policy_Transactions
WHERE   Pev_PortfolioResponsibleCode IN ('WILDWEST-2', 'WILDWEST-3');
