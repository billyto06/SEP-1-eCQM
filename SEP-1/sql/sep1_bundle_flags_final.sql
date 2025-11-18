USE [physionet-data];
SET NOCOUNT ON;
SET XACT_ABORT ON;

--------------------------------------------------------------------------------
-- PARAMETERS
--------------------------------------------------------------------------------
DECLARE 
  @APPEND_EXTRA bit = 1,           -- set 0 if you do NOT want to add more rows
  @ROWS_PER_MONTH_EXTRA int = 80,  -- adds ~80 admissions per month (Jan–Mar)
  @SEED_PASS3_LOW  int = 42,       -- per-month 3h pass lower bound (%)
  @SEED_PASS3_SPAN int = 27,       -- -> upper = low + span - 1 (i.e., 42–68%)
  @SEED_SHOCK_LOW  int = 33,       -- per-month shock prevalence 33–57%
  @SEED_SHOCK_SPAN int = 25,
  @SEED_PASS6_LOW  int = 48,       -- per-month 6h pass among shock 48–72%
  @SEED_PASS6_SPAN int = 25;

--------------------------------------------------------------------------------
-- OPTIONAL: APPEND EXTRA ADMISSIONS IN JAN–MAR 2025 (LIGHTWEIGHT)
-- (Creates patients + admissions + ICD9 99592 + cefepime ~+2h)
--------------------------------------------------------------------------------
IF @APPEND_EXTRA = 1
BEGIN
  DECLARE @id_start BIGINT;
  SELECT @id_start = ISNULL(MAX(HADM_ID), 1000000) + 100
  FROM [mimiciii_clinical].[admissions];

  IF OBJECT_ID('tempdb..#months_ex') IS NOT NULL DROP TABLE #months_ex;
  CREATE TABLE #months_ex (m INT NOT NULL);
  INSERT INTO #months_ex VALUES (1),(2),(3);

  IF OBJECT_ID('tempdb..#new_extra') IS NOT NULL DROP TABLE #new_extra;
  ;WITH N AS (
    SELECT TOP (@ROWS_PER_MONTH_EXTRA) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.objects
  )
  SELECT 
    ROW_NUMBER() OVER (ORDER BY me.m, n.n) + @id_start AS HADM_ID,
    ROW_NUMBER() OVER (ORDER BY me.m, n.n) + @id_start AS SUBJECT_ID,
    DATEADD(MINUTE, (ABS(CHECKSUM(me.m, n.n, 11)) % (24*60)),
            CAST(DATEFROMPARTS(2025, me.m, 1) AS datetime2)) AS ADMITTIME
  INTO #new_extra
  FROM #months_ex me
  CROSS JOIN N n;

  -- patients
  INSERT INTO [mimiciii_clinical].[patients] (SUBJECT_ID, DOB)
  SELECT e.SUBJECT_ID,
         DATEADD(YEAR, - (25 + (ABS(CHECKSUM(e.HADM_ID,1)) % 60)), CAST(e.ADMITTIME AS date))
  FROM #new_extra e
  WHERE NOT EXISTS (SELECT 1 FROM [mimiciii_clinical].[patients] p WHERE p.SUBJECT_ID = e.SUBJECT_ID);

  -- admissions
  INSERT INTO [mimiciii_clinical].[admissions] (SUBJECT_ID, HADM_ID, ADMITTIME, DISCHTIME, ADMISSION_TYPE)
  SELECT e.SUBJECT_ID, e.HADM_ID, e.ADMITTIME,
         DATEADD(DAY, 3 + (ABS(CHECKSUM(e.HADM_ID,2)) % 5), e.ADMITTIME),
         'EMERGENCY'
  FROM #new_extra e
  WHERE NOT EXISTS (SELECT 1 FROM [mimiciii_clinical].[admissions] a WHERE a.HADM_ID = e.HADM_ID);

  -- ICD9 sepsis (99592)
  INSERT INTO [mimiciii_clinical].[diagnoses_icd] (SUBJECT_ID, HADM_ID, ICD9_CODE)
  SELECT e.SUBJECT_ID, e.HADM_ID, '99592'
  FROM #new_extra e
  WHERE NOT EXISTS (
    SELECT 1 FROM [mimiciii_clinical].[diagnoses_icd] d 
    WHERE d.HADM_ID = e.HADM_ID AND d.ICD9_CODE = '99592'
  );

  -- cefepime ~+2h (to help view compute sepsis_time_zero)
  INSERT INTO [mimiciii_clinical].[prescriptions]
    (SUBJECT_ID, HADM_ID, DRUG, DRUG_NAME_POE, DRUG_NAME_GENERIC, STARTDATE)
  SELECT e.SUBJECT_ID, e.HADM_ID,
         'cefepime 2 g iv','CEFEPIME 2 G IV','cefepime',
         DATEADD(MINUTE, 110 + (ABS(CHECKSUM(e.HADM_ID,3)) % 40), e.ADMITTIME) -- 110–149 min
  FROM #new_extra e
  WHERE NOT EXISTS (
    SELECT 1 FROM [mimiciii_clinical].[prescriptions] p 
    WHERE p.HADM_ID = e.HADM_ID AND LOWER(p.DRUG) LIKE '%cefepime%'
  );
END

--------------------------------------------------------------------------------
-- BUILD TARGET COHORT (JAN–MAR 2025 WITH ICD9 99592 AND EARLY CEFEPIME)
-- NOTE: We DO NOT store MonthKey; we compute it in CTEs later.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#newset') IS NOT NULL DROP TABLE #newset;
CREATE TABLE #newset (
  SUBJECT_ID BIGINT NOT NULL,
  HADM_ID    BIGINT NOT NULL,
  ADMITTIME  datetime2(7) NOT NULL,
  first_abx  datetime2(7) NOT NULL
);

WITH base AS (
  SELECT a.SUBJECT_ID, a.HADM_ID, a.ADMITTIME
  FROM [mimiciii_clinical].[admissions] a
  JOIN [mimiciii_clinical].[diagnoses_icd] d
    ON d.HADM_ID = a.HADM_ID AND d.ICD9_CODE = '99592'
  WHERE a.ADMITTIME >= '2025-01-01' AND a.ADMITTIME < '2025-04-01'
),
abx AS (
  SELECT p.HADM_ID, MIN(p.STARTDATE) AS first_abx
  FROM [mimiciii_clinical].[prescriptions] p
  WHERE LOWER(p.DRUG) LIKE '%cefepime%'
  GROUP BY p.HADM_ID
)
INSERT INTO #newset (SUBJECT_ID, HADM_ID, ADMITTIME, first_abx)
SELECT DISTINCT b.SUBJECT_ID, b.HADM_ID, b.ADMITTIME, a.first_abx
FROM base b
JOIN abx  a ON a.HADM_ID = b.HADM_ID
WHERE DATEDIFF(MINUTE, b.ADMITTIME, a.first_abx) BETWEEN 90 AND 180; -- broad, includes old+new

--------------------------------------------------------------------------------
-- PER-MONTH RATES WITH DETERMINISTIC JITTER (NO STORED MonthKey)
--------------------------------------------------------------------------------
-- We'll compute MonthKey on the fly in each CTE as:
-- DATEFROMPARTS(YEAR(ADMITTIME), MONTH(ADMITTIME), 1)

IF OBJECT_ID('tempdb..#month_rates') IS NOT NULL DROP TABLE #month_rates;
;WITH nset AS (
  SELECT 
    ns.*,
    DATEFROMPARTS(YEAR(ns.ADMITTIME), MONTH(ns.ADMITTIME), 1) AS MonthKey
  FROM #newset ns
)
SELECT
  n.MonthKey,
  CAST(@SEED_PASS3_LOW + (ABS(CHECKSUM(n.MonthKey, 31415)) % @SEED_PASS3_SPAN) AS float)/100.0 AS p_pass3,
  CAST(@SEED_SHOCK_LOW + (ABS(CHECKSUM(n.MonthKey, 27182)) % @SEED_SHOCK_SPAN) AS float)/100.0 AS p_shock,
  CAST(@SEED_PASS6_LOW + (ABS(CHECKSUM(n.MonthKey, 16180)) % @SEED_PASS6_SPAN) AS float)/100.0 AS p_pass6
INTO #month_rates
FROM (SELECT DISTINCT MonthKey FROM nset) n;

IF OBJECT_ID('tempdb..#ranked') IS NOT NULL DROP TABLE #ranked;
;WITH nset AS (
  SELECT 
    ns.*,
    DATEFROMPARTS(YEAR(ns.ADMITTIME), MONTH(ns.ADMITTIME), 1) AS MonthKey
  FROM #newset ns
),
r AS (
  SELECT 
    n.HADM_ID,
    n.MonthKey,
    ROW_NUMBER() OVER (
      PARTITION BY n.MonthKey 
      ORDER BY CHECKSUM(n.HADM_ID, n.MonthKey, 424242)
    ) AS rn,
    COUNT(*) OVER (PARTITION BY n.MonthKey) AS cnt
  FROM nset n
)
SELECT * INTO #ranked FROM r;

-- Pass3 selection
IF OBJECT_ID('tempdb..#pass3') IS NOT NULL DROP TABLE #pass3;
;WITH rc AS (
  SELECT DISTINCT MonthKey, cnt FROM #ranked
),
cut AS (
  SELECT 
    rc.MonthKey,
    CAST(FLOOR(m.p_pass3 * rc.cnt) + ((ABS(CHECKSUM(rc.MonthKey, 7)) % 3) - 1) AS int) AS k,
    rc.cnt
  FROM rc
  JOIN #month_rates m ON m.MonthKey = rc.MonthKey
)
SELECT ra.HADM_ID
INTO #pass3
FROM #ranked ra
JOIN cut c ON c.MonthKey = ra.MonthKey
WHERE ra.rn <= CASE WHEN c.k < 0 THEN 0 WHEN c.k > c.cnt THEN c.cnt ELSE c.k END;

-- Shock selection
IF OBJECT_ID('tempdb..#shock') IS NOT NULL DROP TABLE #shock;
;WITH rc AS (
  SELECT DISTINCT MonthKey, cnt FROM #ranked
),
cut AS (
  SELECT 
    rc.MonthKey,
    CAST(FLOOR(m.p_shock * rc.cnt) + ((ABS(CHECKSUM(rc.MonthKey, 11)) % 3) - 1) AS int) AS k,
    rc.cnt
  FROM rc
  JOIN #month_rates m ON m.MonthKey = rc.MonthKey
)
SELECT ra.HADM_ID
INTO #shock
FROM #ranked ra
JOIN cut c ON c.MonthKey = ra.MonthKey
WHERE ra.rn <= CASE WHEN c.k < 0 THEN 0 WHEN c.k > c.cnt THEN c.cnt ELSE c.k END;

-- Pass6 within Shock
IF OBJECT_ID('tempdb..#pass6') IS NOT NULL DROP TABLE #pass6;
;WITH nset AS (
  SELECT 
    ns.*,
    DATEFROMPARTS(YEAR(ns.ADMITTIME), MONTH(ns.ADMITTIME), 1) AS MonthKey
  FROM #newset ns
),
s AS (
  SELECT 
    n.HADM_ID,
    n.MonthKey,
    ROW_NUMBER() OVER (
      PARTITION BY n.MonthKey 
      ORDER BY CHECKSUM(n.HADM_ID, n.MonthKey, 99999)
    ) AS rn,
    COUNT(*) OVER (PARTITION BY n.MonthKey) AS cnt
  FROM nset n
  JOIN #shock  sh ON sh.HADM_ID = n.HADM_ID
),
cut AS (
  SELECT 
    s.MonthKey,
    CAST(FLOOR(m.p_pass6 * s.cnt) + ((ABS(CHECKSUM(s.MonthKey, 13)) % 3) - 1) AS int) AS k,
    s.cnt
  FROM (SELECT DISTINCT MonthKey, cnt FROM s) s
  JOIN #month_rates m ON m.MonthKey = s.MonthKey
)
SELECT s.HADM_ID INTO #pass6
FROM s
JOIN cut c ON c.MonthKey = s.MonthKey
WHERE s.rn <= CASE WHEN c.k < 0 THEN 0 WHEN c.k > c.cnt THEN c.cnt ELSE c.k END;

--------------------------------------------------------------------------------
-- WRITEBACKS: DIAGNOSIS (shock), 3h COMPONENTS, 6h COMPONENTS, NON-PASSER JITTER
--------------------------------------------------------------------------------

-- Add shock ICD9 (78552) where selected
INSERT INTO [mimiciii_clinical].[diagnoses_icd] (SUBJECT_ID, HADM_ID, ICD9_CODE)
SELECT n.SUBJECT_ID, n.HADM_ID, '78552'
FROM #newset n
JOIN #shock  s ON s.HADM_ID = n.HADM_ID
WHERE NOT EXISTS (
  SELECT 1 FROM [mimiciii_clinical].[diagnoses_icd] d
  WHERE d.HADM_ID = n.HADM_ID AND d.ICD9_CODE = '78552'
);

-- CULTURE for Pass3 (before abx; around +8–15m)
INSERT INTO [mimiciii_clinical].[microbiologyevents]
  (SUBJECT_ID, HADM_ID, SPEC_ITEMID, SPEC_TYPE_DESC, CHARTTIME, CHARTDATE)
SELECT n.SUBJECT_ID, n.HADM_ID, 70012, 'BLOOD CULTURE',
       DATEADD(MINUTE, 8 + (ABS(CHECKSUM(n.HADM_ID,21)) % 8), n.ADMITTIME),
       CAST(DATEADD(MINUTE, 8 + (ABS(CHECKSUM(n.HADM_ID,21)) % 8), n.ADMITTIME) AS date)
FROM #newset n
JOIN #pass3  p ON p.HADM_ID = n.HADM_ID
WHERE NOT EXISTS (
  SELECT 1 FROM [mimiciii_clinical].[microbiologyevents] me
  WHERE me.HADM_ID = n.HADM_ID
);

-- LACTATE for Pass3 (60–140 min), item 50813
INSERT INTO [mimiciii_clinical].[labevents]
  (SUBJECT_ID, HADM_ID, CHARTTIME, ITEMID, VALUENUM, VALUEUOM)
SELECT n.SUBJECT_ID, n.HADM_ID,
       DATEADD(MINUTE, 60 + (ABS(CHECKSUM(n.HADM_ID,22)) % 80), n.ADMITTIME),
       50813,
       CASE WHEN ABS(CHECKSUM(n.HADM_ID,23)) % 2 = 0 THEN 1.8 ELSE 4.6 END,
       'mmol/L'
FROM #newset n
JOIN #pass3  p ON p.HADM_ID = n.HADM_ID
WHERE NOT EXISTS (
  SELECT 1 FROM [mimiciii_clinical].[labevents] le
  WHERE le.HADM_ID = n.HADM_ID AND le.ITEMID = 50813
);

-- FLUIDS in 3h for Shock+Pass3
INSERT INTO [mimiciii_clinical].[chartevents]
  (SUBJECT_ID, HADM_ID, ICUSTAY_ID, CHARTTIME, ITEMID, VALUENUM)
SELECT n.SUBJECT_ID, n.HADM_ID, 900000 + n.HADM_ID,
       DATEADD(MINUTE, 70 + (ABS(CHECKSUM(n.HADM_ID,24)) % 90), n.ADMITTIME),
       CASE ABS(CHECKSUM(n.HADM_ID,25)) % 3 WHEN 0 THEN 30061 WHEN 1 THEN 30062 ELSE 30063 END,
       1000.0
FROM #newset n
JOIN #pass3  p ON p.HADM_ID = n.HADM_ID
JOIN #shock  s ON s.HADM_ID = n.HADM_ID
WHERE NOT EXISTS (
  SELECT 1 FROM [mimiciii_clinical].[chartevents] ce
  WHERE ce.HADM_ID = n.HADM_ID
    AND ce.ITEMID IN (30061,30062,30063)
    AND ce.CHARTTIME BETWEEN DATEADD(HOUR,-1,n.ADMITTIME) AND DATEADD(HOUR,6,n.ADMITTIME)
);

-- NON-PASS3: jitter cefepime later → 4.0–5.8h (240–347 min) after admit
;WITH np AS (
  SELECT n.HADM_ID, n.ADMITTIME
  FROM #newset n
  WHERE NOT EXISTS (SELECT 1 FROM #pass3 p WHERE p.HADM_ID = n.HADM_ID)
)
UPDATE p
SET p.STARTDATE = DATEADD(
      MINUTE, 
      240 + (ABS(CHECKSUM(p.HADM_ID, 123)) % 108),  -- 240–347
      np.ADMITTIME
    )
FROM [mimiciii_clinical].[prescriptions] p
JOIN np ON np.HADM_ID = p.HADM_ID
WHERE LOWER(p.DRUG) LIKE '%cefepime%';

-- NON-PASS3: add cultures with spread (some after abx, some late-before)
INSERT INTO [mimiciii_clinical].[microbiologyevents]
  (SUBJECT_ID, HADM_ID, SPEC_ITEMID, SPEC_TYPE_DESC, CHARTTIME, CHARTDATE)
SELECT n.SUBJECT_ID, n.HADM_ID, 70012, 'BLOOD CULTURE',
       CASE 
         WHEN ABS(CHECKSUM(n.HADM_ID,5)) % 10 < 3 
           THEN DATEADD(MINUTE, 240 + (ABS(CHECKSUM(n.HADM_ID,55)) % 120), n.ADMITTIME) -- 4–6h after admit (after abx)
         ELSE DATEADD(MINUTE, 170 + (ABS(CHECKSUM(n.HADM_ID,56)) % 80),  n.ADMITTIME)   -- 2.8–4.1h, still before delayed abx
       END,
       CAST(
         CASE 
           WHEN ABS(CHECKSUM(n.HADM_ID,5)) % 10 < 3 
             THEN DATEADD(MINUTE, 240 + (ABS(CHECKSUM(n.HADM_ID,55)) % 120), n.ADMITTIME)
           ELSE DATEADD(MINUTE, 170 + (ABS(CHECKSUM(n.HADM_ID,56)) % 80),  n.ADMITTIME)
         END AS date)
FROM #newset n
WHERE NOT EXISTS (SELECT 1 FROM #pass3 p WHERE p.HADM_ID = n.HADM_ID)
  AND NOT EXISTS (SELECT 1 FROM [mimiciii_clinical].[microbiologyevents] me WHERE me.HADM_ID = n.HADM_ID);

-- PASS6 (shock subset): norepinephrine + pressor event; ensure first lactate >=4.0
INSERT INTO [mimiciii_clinical].[prescriptions]
  (SUBJECT_ID, HADM_ID, DRUG, DRUG_NAME_POE, DRUG_NAME_GENERIC, STARTDATE)
SELECT n.SUBJECT_ID, n.HADM_ID, 'norepinephrine iv','NOREPINEPHRINE IV','norepinephrine',
       DATEADD(MINUTE, 150 + (ABS(CHECKSUM(n.HADM_ID,61)) % 120), n.ADMITTIME) -- 2.5–4.5h
FROM #newset n
JOIN #pass6 x ON x.HADM_ID = n.HADM_ID
WHERE NOT EXISTS (
  SELECT 1 FROM [mimiciii_clinical].[prescriptions] p
  WHERE p.HADM_ID = n.HADM_ID AND LOWER(p.DRUG) LIKE '%norepinephrine%'
);

INSERT INTO [mimiciii_clinical].[chartevents]
  (SUBJECT_ID, HADM_ID, ICUSTAY_ID, CHARTTIME, ITEMID, VALUENUM)
SELECT n.SUBJECT_ID, n.HADM_ID, 900000 + n.HADM_ID,
       DATEADD(MINUTE, 150 + (ABS(CHECKSUM(n.HADM_ID,62)) % 120), n.ADMITTIME),
       221906, 0.1
FROM #newset n
JOIN #pass6 x ON x.HADM_ID = n.HADM_ID
WHERE NOT EXISTS (
  SELECT 1 FROM [mimiciii_clinical].[chartevents] ce
  WHERE ce.HADM_ID = n.HADM_ID AND ce.ITEMID = 221906
);

;WITH FirstLac AS (
  SELECT le.HADM_ID, MIN(le.CHARTTIME) AS FirstTime
  FROM [mimiciii_clinical].[labevents] le
  WHERE le.ITEMID = 50813
    AND le.HADM_ID IN (SELECT HADM_ID FROM #newset)
  GROUP BY le.HADM_ID
)
UPDATE le
SET le.VALUENUM = CASE WHEN le.VALUENUM IS NULL OR le.VALUENUM < 4.0 THEN 4.3 ELSE le.VALUENUM END
FROM [mimiciii_clinical].[labevents] le
JOIN FirstLac f ON f.HADM_ID = le.HADM_ID AND f.FirstTime = le.CHARTTIME
WHERE EXISTS (SELECT 1 FROM #pass6 x WHERE x.HADM_ID = le.HADM_ID);

-- Optional: repeat lactate 3–6h for Pass6
INSERT INTO [mimiciii_clinical].[labevents]
  (SUBJECT_ID, HADM_ID, CHARTTIME, ITEMID, VALUENUM, VALUEUOM)
SELECT n.SUBJECT_ID, n.HADM_ID,
       DATEADD(MINUTE, 210 + (ABS(CHECKSUM(n.HADM_ID,63)) % 120), n.ADMITTIME),
       50813, 3.2, 'mmol/L'
FROM #newset n
JOIN #pass6 x ON x.HADM_ID = n.HADM_ID
WHERE NOT EXISTS (
  SELECT 1 FROM [mimiciii_clinical].[labevents] le
  WHERE le.HADM_ID = n.HADM_ID 
    AND le.ITEMID = 50813 
    AND le.CHARTTIME BETWEEN DATEADD(MINUTE, 200, n.ADMITTIME) AND DATEADD(MINUTE, 360, n.ADMITTIME)
);

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------
DECLARE @n INT  = (SELECT COUNT(*) FROM #newset);
DECLARE @p3 INT = (SELECT COUNT(*) FROM #pass3);
DECLARE @sh INT = (SELECT COUNT(*) FROM #shock);
DECLARE @p6 INT = (SELECT COUNT(*) FROM #pass6);

PRINT CONCAT(
  'Jan–Mar 2025 normalization complete. Cohort=', @n,
  ' | Pass3=', @p3,
  ' | Shock=', @sh,
  ' | Pass6=', @p6, 
  CASE WHEN @APPEND_EXTRA = 1 THEN ' | Extra admissions appended.' ELSE ' | No extra admissions appended.' END
);
