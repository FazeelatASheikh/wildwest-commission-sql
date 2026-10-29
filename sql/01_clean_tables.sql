/* 01_clean_tables.sql
   Step 1: make clean copies of the raw tables.

   The raw tables came in as text. Dates are text, empty dates are '' instead of NULL,
   and Annual_Premium uses a decimal comma ('5719,00000000'). I make new tables with real
   dates and numbers. The raw tables stay as they are.

   TRY_CONVERT gives NULL for a bad value, so one bad row does not stop the whole query.
   Run this file first. It is safe to run again.
*/

DROP TABLE IF EXISTS dbo.Policy_Clean;

SELECT  TRY_CONVERT(bigint, Key_Policy)                 AS Key_Policy,
        CONVERT(varchar(30), LTRIM(RTRIM(Ext_Refr)))    AS Ext_Refr,       -- the policy number
        TRY_CONVERT(date, NULLIF(Bnd_Dt, ''))           AS Bnd_Dt,         -- policy starts
        TRY_CONVERT(date, NULLIF(Pln_End_Dt, ''))       AS Pln_End_Dt,     -- planned end
        TRY_CONVERT(date, NULLIF(Rnew_Dt, ''))          AS Rnew_Dt,        -- planned renewal
        TRY_CONVERT(date, NULLIF(Cncl_Dt, ''))          AS Cncl_Dt,        -- cancellation date
        CONVERT(varchar(10), LTRIM(RTRIM(Agrm_Sts_Cd))) AS Agrm_Sts_Cd     -- ACTIVE or CANCEL
INTO    dbo.Policy_Clean
FROM    dbo.Policy;

DROP TABLE IF EXISTS dbo.Portfolio_Clean;

SELECT  TRY_CONVERT(bigint, Key_Policy)                     AS Key_Policy,
        TRY_CONVERT(date, NULLIF(Sales_Date, ''))           AS Sales_Date,
        TRY_CONVERT(bigint, Key_SS_Org)                     AS Key_SS_Org,
        TRY_CONVERT(date, NULLIF(PaymentDate, ''))          AS PaymentDate,
        CONVERT(varchar(20), LTRIM(RTRIM(Payment_Status)))  AS Payment_Status,
        -- decimal comma to decimal point, then to a number
        TRY_CONVERT(decimal(18,2),
                    REPLACE(CONVERT(nvarchar(50), Annual_Premium), ',', '.')) AS Annual_Premium,
        CONVERT(varchar(30), LTRIM(RTRIM(Product_Name)))    AS Product_Name,
        -- 'Product 13' becomes 13, so I can test a range instead of listing every name
        TRY_CONVERT(int, REPLACE(LTRIM(RTRIM(Product_Name)), 'Product ', '')) AS Product_No
INTO    dbo.Portfolio_Clean
FROM    dbo.Portfolio;

-- Indexes so the joins are faster
CREATE INDEX IX_Policy_Clean_ExtRefr  ON dbo.Policy_Clean    (Ext_Refr);
CREATE INDEX IX_Policy_Clean_Key      ON dbo.Policy_Clean    (Key_Policy);
CREATE INDEX IX_Portfolio_Clean_Key   ON dbo.Portfolio_Clean (Key_Policy);
