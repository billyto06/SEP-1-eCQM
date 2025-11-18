--standardSQL
/*
=========================================================================================================================================================
SEP-1 eCQM (DISCOVERY + BASELINE COHORT/BUNDLE WITH 3-HR & 6-HR COMPONENTS)

Purpose
-------
1) Parts 1–4: “Show your work” discovery queries to find codes/ITEMIDs and understand table shapes.
2) Parts 5–7: Build adult cohort, derive time zero, compute both 3-hour and 6-hour bundle components, and output composite flags.

Scope Notes
-----------
- Discovery queries are read-only, for understanding and mapping.
- Baseline bundle logic mirrors your working approach (kept simple and explainable).
- Intentional choices preserved:
  * DATE_DIFF for age
  * COALESCE(...) with sentinel time in time-zero LEAST()
  * + INTERVAL 12 HOUR for prescriptions STARTDATE midpoint
=========================================================================================================================================================
*/


-----------------------------------------------------------------------
-- PART 1: DIAGNOSES OF SEPSIS (feature for later)
-----------------------------------------------------------------------
-- SELECT * FROM `physionet-data.mimiciii_clinical.d_icd_diagnoses`

-- 1A) Admissions with any sepsis-related ICD-9 wording 
WITH sepsis_codes AS (
  SELECT
    d.SUBJECT_ID, d.HADM_ID, dd.ICD9_CODE, dd.SHORT_TITLE, dd.LONG_TITLE
  FROM [physionet-data].[mimiciii_clinical].[diagnoses_icd] d
  INNER JOIN [physionet-data].[mimiciii_clinical].[d_icd_diagnoses] dd
    ON d.icd9_code = dd.icd9_code
  WHERE LOWER(dd.long_title) LIKE '%sepsis%'
     OR LOWER(dd.long_title) LIKE '%septicemia%'
     OR LOWER(dd.long_title) LIKE '%septic%'
)
SELECT a.SUBJECT_ID, a.HADM_ID, a.ADMITTIME, a.DISCHTIME, a.DEATHTIME,
       a.ADMISSION_TYPE, s.ICD9_CODE, s.SHORT_TITLE, s.LONG_TITLE
FROM [physionet-data].[mimiciii_clinical].[admissions] a
INNER JOIN sepsis_codes s
  ON a.SUBJECT_ID = s.SUBJECT_ID AND a.HADM_ID = s.HADM_ID
ORDER BY a.admittime;
-- result: 14,578 admissions related to term sepsis, sepsis '99591', septic shock '99592', severe sepsis '78552'



-----------------------------------------------------------------------
-- PART 2: LAB TESTING DISCOVERY (LACTATE)
-----------------------------------------------------------------------
-- SELECT * FROM `physionet-data.mimiciii_clinical.d_labitems` WHERE ITEMID = 50931

-- 2A) Find lactate ITEMIDs (exclude LDH)
-- LDH is a different test that also has "lactate" in its name
SELECT DISTINCT ITEMID, LABEL, FLUID, CATEGORY, LOINC_CODE
FROM [physionet-data].[mimiciii_clinical].[d_labitems]
WHERE UPPER(label) LIKE '%LACTATE%'
  AND UPPER(label) NOT LIKE '%DEHYDROGENASE%'
ORDER BY LABEL;
-- result: LACTATE_ITEMIDS = 50813

-- 2B) Counts amount of lactate itemids
-- Checking how many lactate tests exist in the database
SELECT l.ITEMID, dl.LABEL, COUNT(*) AS n
FROM [physionet-data].[mimiciii_clinical].[labevents] l
INNER JOIN [physionet-data].[mimiciii_clinical].[d_labitems] dl
  ON dl.itemid = l.itemid
WHERE LOWER(dl.LABEL) LIKE '%lactate%'
  AND LOWER(dl.LABEL) NOT LIKE '%dehydrogenase%'
GROUP BY l.itemid, dl.LABEL
ORDER BY n DESC;
-- result: 187116 items with 'lactate' label, label 50813

-- 2C) Sample rows, looking at actual lactate test results to understand the data format
SELECT TOP (200) HADM_ID, CHARTTIME, ITEMID, VALUENUM, VALUEUOM
FROM [physionet-data].[mimiciii_clinical].[labevents]
WHERE itemid = 50813
ORDER BY charttime;
-- result: inspect value ranges, units (mmol/L), and missingness patterns



-----------------------------------------------------------------------
-- PART 3: CULTURES, WEIGHT, MAP DISCOVERY
-----------------------------------------------------------------------
-- SELECT * FROM `physionet-data.mimiciii_clinical.microbiologyevents`

-- 3A) Blood culture specimen codes (microbiologyevents)
SELECT DISTINCT SPEC_ITEMID, SPEC_TYPE_DESC
FROM [physionet-data].[mimiciii_clinical].[microbiologyevents]
WHERE UPPER(SPEC_TYPE_DESC) LIKE '%BLOOD%'
ORDER BY SPEC_TYPE_DESC;
-- result: BLOOD CULTURE = 70012

-- 3B) First blood culture time for each admission
-- Finding when doctors first suspected infection
SELECT TOP (100) SUBJECT_ID, HADM_ID, 
  MIN(COALESCE(CAST(charttime AS datetime2), CAST(chartdate AS datetime2))) AS first_Time
FROM [physionet-data].[mimiciii_clinical].[microbiologyevents]
WHERE spec_itemid = 70012
GROUP BY subject_id, hadm_id
ORDER BY first_time;
-- result: closest thing to "time zero" where sepsis is suspected (spot-check a few rows)

-- 3C) Find Weight related itemid (for 30 mL/kg denominator)
SELECT ITEMID, LABEL FROM [physionet-data].[mimiciii_clinical].[d_items]
WHERE Lower(LABEL) LIKE '%weight%'
ORDER BY LABEL;
-- result: ITEMID = 226512 -> Admission Weight (kg), 226531 -> Admission Weight (lbs)

-- 3D) Nearest weight to ICU patient's intime 
WITH weights_raw AS (
  SELECT
    i.subject_id, i.hadm_id, i.icustay_id, i.intime,
    ce.charttime, ce.itemid, ce.valuenum
  FROM [physionet-data].[mimiciii_clinical].[icustays] i
  JOIN [physionet-data].[mimiciii_clinical].[chartevents] ce
    ON ce.icustay_id = i.icustay_id
   AND ce.itemid IN (226512, 226531)    -- 226512=kg, 226531=lbs
   AND ce.valuenum IS NOT NULL
),
weights_norm AS (
  SELECT
    subject_id, hadm_id, icustay_id, intime, charttime,
    CASE
      WHEN itemid = 226512 THEN valuenum
      WHEN itemid = 226531 THEN valuenum * 0.453592
    END AS weight_kg,
    CASE WHEN itemid = 226512 THEN 1 ELSE 2 END AS src_priority, -- KG first
    ABS(DATEDIFF(HOUR, intime, charttime)) AS dist_hours
  FROM weights_raw
),
weights_ranked AS (
  SELECT
    subject_id, hadm_id, icustay_id, intime, charttime,
    ROUND(weight_kg, 1) AS weight_kg,
    ROW_NUMBER() OVER (
      PARTITION BY icustay_id
      ORDER BY src_priority, dist_hours, charttime
    ) AS rn
  FROM weights_norm
  WHERE weight_kg BETWEEN 30 AND 300
)
SELECT
  subject_id, hadm_id, icustay_id, intime, charttime, weight_kg
FROM weights_ranked
WHERE rn = 1
ORDER BY intime;
-- result: plausible adult kg close to ICU intime; no zeros/extremes

-- 3E) Mean Arterial Pressure itemid (look for low blood pressure hypotension, sepsis shock)
-- MAP is an average blood pressure reading - low MAP means organs aren't getting enough blood
SELECT DISTINCT ITEMID, LABEL
FROM [physionet-data].[mimiciii_clinical].[d_items]
WHERE LOWER(LABEL) LIKE '%mean%bp%' OR LOWER(LABEL) LIKE '%map%'
ORDER BY LABEL;
-- result: confirm MAP item candidates (e.g., 52, 456, 6702, 220052, 220181, 225312)



-----------------------------------------------------------------------
-- PART 4: MEDS AND FLUIDS DISCOVERY
-----------------------------------------------------------------------
-- 4A) Broad-spectrum antibiotics: Finding all the different names for powerful antibiotics 
WITH rx AS (
  SELECT LOWER(DRUG) AS N FROM [physionet-data].[mimiciii_clinical].[prescriptions]
  UNION SELECT LOWER(DRUG_NAME_POE) FROM [physionet-data].[mimiciii_clinical].[prescriptions]
  UNION SELECT LOWER(DRUG_NAME_GENERIC) FROM [physionet-data].[mimiciii_clinical].[prescriptions] -- checks all possible names
)
SELECT N, COUNT(*) AS CNT
FROM rx
WHERE N LIKE '%cefepime%'
   OR N LIKE '%ceftazidime%'
   OR N LIKE '%piperacillin%'
   OR N LIKE '%tazobactam%'
   OR N LIKE '%zosyn%'
   OR N LIKE '%meropenem%'
   OR N LIKE '%imipenem%'
   OR N LIKE '%doripenem%'
   OR N LIKE '%aztreonam%'
   OR N LIKE '%levofloxacin%'
   OR N LIKE '%ciprofloxacin%'
   OR N LIKE '%moxifloxacin%'
   OR N LIKE '%vancomycin%'
   OR N LIKE '%linezolid%'
   OR N LIKE '%daptomycin%'
   OR N LIKE '%ampicillin/sulbactam%'
   OR N LIKE '%unasyn%'
   OR N LIKE '%ticarcillin%'
   OR N LIKE '%clavulanate%'
GROUP BY N
ORDER BY CNT DESC;
-- result: confirm spellings/aliases that appear in this dataset

-- 4B) Find IV Fluids labels
SELECT DISTINCT ITEMID, LABEL
FROM [physionet-data].[mimiciii_clinical].[d_items]
WHERE LOWER(LABEL) LIKE '%normal saline%'
   OR LOWER(LABEL) LIKE '%sodium chloride 0.9%'
   OR LOWER(LABEL) LIKE '%na cl 0.9%'
   OR LOWER(LABEL) LIKE '%0.9% saline%'
   OR LOWER(LABEL) LIKE '%lactated ringer%'
   OR LOWER(LABEL) LIKE '%ringer% lactate%'
   OR LOWER(LABEL) LIKE '%plasma%lyte%'
ORDER BY LABEL;
-- result: shortlist crystalloids

-- 4C) Find Vasopressors labels (increase blood pressure)
SELECT DISTINCT itemid, label
FROM [physionet-data].[mimiciii_clinical].[d_items]
WHERE LOWER(label) LIKE '%norepinephrine%'
   OR LOWER(label) LIKE '%noradrenaline%'
   OR LOWER(label) LIKE '%levophed%'
   OR LOWER(label) LIKE '%epinephrine%'
   OR LOWER(label) LIKE '%phenylephrine%'
   OR LOWER(label) LIKE '%vasopressin%'
   OR LOWER(label) LIKE '%dopamine%'
ORDER BY label;
-- result: shortlist vasopressor labels



/* ======================================================================
   PARTS 5–7: BASELINE COHORT & BUNDLE (3-HOUR + 6-HOUR COMPONENTS)
   ----------------------------------------------------------------------
   Intentional design choices preserved from your base:
   - DATE_DIFF for age
   - COALESCE sentinels inside LEAST() for time-zero
   - + INTERVAL 12 HOUR applied to prescriptions STARTDATE
   ====================================================================== */

-----------------------------------------------------------------------
-- PART 5: Cohort + Time Zero (baseline)
-----------------------------------------------------------------------
;WITH patient_cohort AS (
  SELECT 
    p.SUBJECT_ID,
    p.HADM_ID,
    p.ADMITTIME,
    -- Calculate age at admission
    DATEDIFF(YEAR, pat.DOB, p.ADMITTIME) AS age_at_admission,
    
    -- Sepsis type classification
    MAX(CASE WHEN d.ICD9_CODE = '99592' THEN 1 ELSE 0 END) AS severe_sepsis,
    MAX(CASE WHEN d.ICD9_CODE = '78552' THEN 1 ELSE 0 END) AS septic_shock,
    
    -- ICU stay
    CASE WHEN i.ICUSTAY_ID IS NOT NULL THEN 1 ELSE 0 END AS in_icu
    
  FROM [physionet-data].[mimiciii_clinical].[admissions] p
  JOIN [physionet-data].[mimiciii_clinical].[patients] pat ON p.SUBJECT_ID = pat.SUBJECT_ID
  LEFT JOIN [physionet-data].[mimiciii_clinical].[diagnoses_icd] d ON p.SUBJECT_ID = d.SUBJECT_ID AND p.HADM_ID = d.HADM_ID
  LEFT JOIN [physionet-data].[mimiciii_clinical].[icustays] i ON p.SUBJECT_ID = i.SUBJECT_ID AND p.HADM_ID = i.HADM_ID
  WHERE d.ICD9_CODE IN ('99591', '99592', '78552')
    AND DATEDIFF(YEAR, pat.DOB, p.ADMITTIME) >= 18
  GROUP BY p.SUBJECT_ID, p.HADM_ID, p.ADMITTIME, pat.DOB, i.ICUSTAY_ID
),
sepsis_time_zero AS (
  SELECT 
    pc.SUBJECT_ID,
    pc.HADM_ID,
    -- Time zero is earliest of blood culture or antibiotic administration
    CASE 
      WHEN COALESCE(MIN(CAST(m.CHARTTIME AS datetime2)), CAST('9999-12-31' AS datetime2)) 
           <= COALESCE(MIN(DATEADD(HOUR, 12, CAST(rx.STARTDATE AS datetime2))), CAST('9999-12-31' AS datetime2))
      THEN COALESCE(MIN(CAST(m.CHARTTIME AS datetime2)), CAST('9999-12-31' AS datetime2))
      ELSE COALESCE(MIN(DATEADD(HOUR, 12, CAST(rx.STARTDATE AS datetime2))), CAST('9999-12-31' AS datetime2))
    END AS sepsis_time_zero
  FROM patient_cohort pc
  LEFT JOIN [physionet-data].[mimiciii_clinical].[microbiologyevents] m 
    ON pc.SUBJECT_ID = m.SUBJECT_ID AND pc.HADM_ID = m.HADM_ID
    AND m.SPEC_ITEMID = 70012
  LEFT JOIN [physionet-data].[mimiciii_clinical].[prescriptions] rx 
    ON pc.SUBJECT_ID = rx.SUBJECT_ID AND pc.HADM_ID = rx.HADM_ID
    AND (LOWER(rx.DRUG) LIKE '%cefepime%' OR LOWER(rx.DRUG) LIKE '%vancomycin%' OR LOWER(rx.DRUG) LIKE '%piperacillin%')
  GROUP BY pc.SUBJECT_ID, pc.HADM_ID
), -- result: SELECT COUNTIF(sepsis_time_zero IS NOT NULL) AS with_t0, COUNT(*) AS total FROM sepsis_time_zero
lactate_3h AS (
  -- 6.1 Lactate within 3h of time_zero (and capture initial lactate value)
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, CAST(le.CHARTTIME AS datetime2)) <= 3 THEN 1 ELSE 0 END) AS lactate_measured_3h,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, CAST(le.CHARTTIME AS datetime2)) <= 3 THEN le.VALUENUM END) AS initial_lactate_value
  FROM sepsis_time_zero stz
  LEFT JOIN [physionet-data].[mimiciii_clinical].[labevents] le 
    ON stz.SUBJECT_ID = le.SUBJECT_ID AND stz.HADM_ID = le.HADM_ID
    AND le.ITEMID = 50813  -- Lactate
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
), -- result: SELECT AVG(CAST(lactate_measured_3h AS INT64)) FROM lactate_3h
blood_culture_3h AS (
  -- 6.2 Blood culture within 3h of time_zero
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, CAST(m.CHARTTIME AS datetime2)) <= 3 THEN 1 ELSE 0 END) AS blood_culture_3h
  FROM sepsis_time_zero stz
  LEFT JOIN [physionet-data].[mimiciii_clinical].[microbiologyevents] m 
    ON stz.SUBJECT_ID = m.SUBJECT_ID AND stz.HADM_ID = m.HADM_ID
    AND m.SPEC_ITEMID = 70012
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
), -- result: SELECT AVG(CAST(blood_culture_3h AS INT64)) FROM blood_culture_3h
antibiotics_3h AS (
  -- 6.3 Broad-spectrum antibiotic within 3h of time_zero
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, DATEADD(HOUR, 12, CAST(rx.STARTDATE AS datetime2))) <= 3 THEN 1 ELSE 0 END) AS antibiotics_3h
  FROM sepsis_time_zero stz
  LEFT JOIN [physionet-data].[mimiciii_clinical].[prescriptions] rx 
    ON stz.SUBJECT_ID = rx.SUBJECT_ID AND stz.HADM_ID = rx.HADM_ID
    AND (LOWER(rx.DRUG) LIKE '%cefepime%' OR LOWER(rx.DRUG) LIKE '%vancomycin%' OR LOWER(rx.DRUG) LIKE '%piperacillin%')
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
), -- result: SELECT AVG(CAST(antibiotics_3h AS INT64)) FROM antibiotics_3h
fluids_3h AS (
  -- 6.4 For septic shock: fluids within 3h (simple indicator)
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, CAST(ce.CHARTTIME AS datetime2)) <= 3 
             AND ce.ITEMID IN (30061, 30062, 30063) -- Common fluid items (discovery list placeholder)
             THEN 1 ELSE 0 END) AS fluids_administered_3h
  FROM sepsis_time_zero stz
  LEFT JOIN [physionet-data].[mimiciii_clinical].[chartevents] ce 
    ON stz.SUBJECT_ID = ce.SUBJECT_ID AND stz.HADM_ID = ce.HADM_ID
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
), -- result: SELECT AVG(CAST(fluids_administered_3h AS INT64)) FROM fluids_3h
repeat_lactate_6h AS (
  -- 6-Hour Bundle Components
  -- 6.5 For severe sepsis: repeat lactate if initial > 2 (between 3h and 6h)
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, CAST(le.CHARTTIME AS datetime2)) BETWEEN 3 AND 6 THEN 1 ELSE 0 END) AS repeat_lactate_6h
  FROM sepsis_time_zero stz
  LEFT JOIN [physionet-data].[mimiciii_clinical].[labevents] le 
    ON stz.SUBJECT_ID = le.SUBJECT_ID AND stz.HADM_ID = le.HADM_ID
    AND le.ITEMID = 50813  -- Lactate
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
), -- result: SELECT AVG(CAST(repeat_lactate_6h AS INT64)) FROM repeat_lactate_6h
vasopressors_6h AS (
  -- 6.6 For septic shock: vasopressors within 6 hours
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, CAST(ce.CHARTTIME AS datetime2)) <= 6
             AND ce.ITEMID IN (221906, 221289, 221749, 222315, 221662) -- Vasopressors
             THEN 1 ELSE 0 END) AS vasopressors_administered_6h
  FROM sepsis_time_zero stz
  LEFT JOIN [physionet-data].[mimiciii_clinical].[chartevents] ce 
    ON stz.SUBJECT_ID = ce.SUBJECT_ID AND stz.HADM_ID = ce.HADM_ID
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
), -- result: SELECT AVG(CAST(vasopressors_administered_6h AS INT64)) FROM vasopressors_6h
map_after_fluids AS (
  -- 6.7 For septic shock: MAP < 65 after fluids (3–6h)
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN DATEDIFF(HOUR, stz.sepsis_time_zero, CAST(ce.CHARTTIME AS datetime2)) BETWEEN 3 AND 6
             AND ce.ITEMID IN (52, 456, 6702, 443, 220052, 220181, 225312) -- MAP measurements
             AND ce.VALUENUM < 65
             THEN 1 ELSE 0 END) AS persistent_hypotension_6h
  FROM sepsis_time_zero stz
  LEFT JOIN [physionet-data].[mimiciii_clinical].[chartevents] ce 
    ON stz.SUBJECT_ID = ce.SUBJECT_ID AND stz.HADM_ID = ce.HADM_ID
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
), -- result: SELECT AVG(CAST(persistent_hypotension_6h AS INT64)) FROM map_after_fluids
final_measures AS (
  -----------------------------------------------------------------------
  -- PART 7: Final Measures + Output (3h & 6h composites)
  -----------------------------------------------------------------------
  SELECT 
    pc.SUBJECT_ID,
    pc.HADM_ID,
    pc.age_at_admission,
    pc.severe_sepsis,
    pc.septic_shock,
    stz.sepsis_time_zero,

    -- 3-hour bundle measures (for both sepsis types)
    COALESCE(lac.lactate_measured_3h, 0) AS lactate_measured_3h,
    lac.initial_lactate_value,
    COALESCE(bc.blood_culture_3h, 0)     AS blood_culture_3h,
    COALESCE(abx.antibiotics_3h, 0)      AS antibiotics_3h,

    -- Septic shock additional (fluids within 3h)
    COALESCE(fl.fluids_administered_3h, 0) AS fluids_administered_3h,

    -- 6-hour bundle measures
    COALESCE(rl.repeat_lactate_6h, 0)        AS repeat_lactate_6h,
    COALESCE(vs.vasopressors_administered_6h, 0) AS vasopressors_administered_6h,
    COALESCE(mf.persistent_hypotension_6h, 0)    AS persistent_hypotension_6h,
    
    -- Composite scores for 3-hour bundle
    CASE 
      WHEN pc.severe_sepsis = 1 THEN
        CASE WHEN COALESCE(lac.lactate_measured_3h, 0) = 1 
              AND COALESCE(bc.blood_culture_3h, 0) = 1 
              AND COALESCE(abx.antibiotics_3h, 0) = 1 
             THEN 1 ELSE 0 END
      WHEN pc.septic_shock = 1 THEN
        CASE WHEN COALESCE(lac.lactate_measured_3h, 0) = 1 
              AND COALESCE(bc.blood_culture_3h, 0) = 1 
              AND COALESCE(abx.antibiotics_3h, 0) = 1 
              AND COALESCE(fl.fluids_administered_3h, 0) = 1 
             THEN 1 ELSE 0 END
      ELSE 0
    END AS bundle_complete_3h,
    
    -- Composite scores for 6-hour bundle
    CASE 
      WHEN pc.severe_sepsis = 1 THEN
        -- For severe sepsis: repeat lactate if initial > 2
        CASE WHEN (lac.initial_lactate_value IS NULL OR lac.initial_lactate_value <= 2) 
               OR (lac.initial_lactate_value > 2 AND COALESCE(rl.repeat_lactate_6h, 0) = 1)
             THEN 1 ELSE 0 END
      WHEN pc.septic_shock = 1 THEN
        -- For septic shock: vasopressors AND (persistent hypotension OR initial lactate >= 4)
        CASE WHEN COALESCE(vs.vasopressors_administered_6h, 0) = 1 
              AND (COALESCE(mf.persistent_hypotension_6h, 0) = 1 
                   OR (lac.initial_lactate_value IS NOT NULL AND lac.initial_lactate_value >= 4))
             THEN 1 ELSE 0 END
      ELSE 0
    END AS bundle_complete_6h
    
  FROM patient_cohort pc
  JOIN sepsis_time_zero stz ON pc.SUBJECT_ID = stz.SUBJECT_ID AND pc.HADM_ID = stz.HADM_ID
  LEFT JOIN lactate_3h       lac ON pc.SUBJECT_ID = lac.SUBJECT_ID AND pc.HADM_ID = lac.HADM_ID
  LEFT JOIN blood_culture_3h bc  ON pc.SUBJECT_ID = bc.SUBJECT_ID AND pc.HADM_ID = bc.HADM_ID
  LEFT JOIN antibiotics_3h   abx ON pc.SUBJECT_ID = abx.SUBJECT_ID AND pc.HADM_ID = abx.HADM_ID
  LEFT JOIN fluids_3h        fl  ON pc.SUBJECT_ID = fl.SUBJECT_ID AND pc.HADM_ID = fl.HADM_ID
  LEFT JOIN repeat_lactate_6h rl ON pc.SUBJECT_ID = rl.SUBJECT_ID AND pc.HADM_ID = rl.HADM_ID
  LEFT JOIN vasopressors_6h  vs  ON pc.SUBJECT_ID = vs.SUBJECT_ID AND pc.HADM_ID = vs.HADM_ID
  LEFT JOIN map_after_fluids mf  ON pc.SUBJECT_ID = mf.SUBJECT_ID AND pc.HADM_ID = mf.HADM_ID
)

-- Final output with NULL values for non-applicable measures
SELECT 
  SUBJECT_ID,
  HADM_ID,
  age_at_admission,
  severe_sepsis,
  septic_shock,
  sepsis_time_zero,

  -- 3-hour bundle measures
  lactate_measured_3h,
  initial_lactate_value,
  blood_culture_3h,
  antibiotics_3h,
  CASE WHEN septic_shock = 1 THEN fluids_administered_3h ELSE NULL END AS fluids_administered_3h,

  -- 6-hour bundle measures
  CASE WHEN severe_sepsis = 1 THEN repeat_lactate_6h ELSE NULL END AS repeat_lactate_6h,
  CASE WHEN septic_shock = 1 THEN vasopressors_administered_6h ELSE NULL END AS vasopressors_administered_6h,
  CASE WHEN septic_shock = 1 THEN persistent_hypotension_6h ELSE NULL END AS persistent_hypotension_6h,

  -- Composite scores
  bundle_complete_3h,
  bundle_complete_6h,

  -- Overall bundle completion
  CASE 
    WHEN bundle_complete_3h = 1 AND bundle_complete_6h = 1 THEN 1
    ELSE 0
  END AS bundle_complete_overall
FROM final_measures
ORDER BY SUBJECT_ID, HADM_ID;

/*
result: quick checks
--------------------
1) Size:
   SELECT COUNT(*) FROM final_measures;

2) Time-zero coverage:
   SELECT AVG(CAST(sepsis_time_zero IS NOT NULL AS INT64)) FROM final_measures;

3) 3-hour component rates:
   SELECT AVG(CAST(lactate_measured_3h AS INT64)) AS pct_lac3,
          AVG(CAST(blood_culture_3h   AS INT64)) AS pct_bc3,
          AVG(CAST(antibiotics_3h     AS INT64)) AS pct_abx3
   FROM final_measures;

4) 6-hour component rates:
   SELECT AVG(CAST(repeat_lactate_6h          AS INT64)) AS pct_rl6,
          AVG(CAST(vasopressors_administered_6h AS INT64)) AS pct_vp6,
          AVG(CAST(persistent_hypotension_6h   AS INT64)) AS pct_map6
   FROM final_measures;

5) Bundle rates:
   SELECT AVG(CAST(bundle_complete_3h AS INT64)) AS pct_bundle3,
          AVG(CAST(bundle_complete_6h AS INT64)) AS pct_bundle6,
          AVG(CAST(bundle_complete_overall AS INT64)) AS pct_overall
   FROM (
     SELECT bundle_complete_3h, bundle_complete_6h, 
            CASE WHEN bundle_complete_3h=1 AND bundle_complete_6h=1 THEN 1 ELSE 0 END AS bundle_complete_overall
     FROM final_measures
   );
*/
