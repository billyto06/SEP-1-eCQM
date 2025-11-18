--standardSQL
/*
=====================================================================
SEP-1 eCQM (Discovery + Baseline Cohort with 3-hour & 6-hour components)
Purpose:
1) Parts 1–4: locate codes/ITEMIDs and inspect table shapes
2) Parts 5–7: build adult cohort, derive time zero, and compute bundle flags
=====================================================================
*/

-----------------------------------------------------------------------
-- PART 1: Diagnoses of sepsis
-----------------------------------------------------------------------
-- SELECT * FROM `physionet-data.mimiciii_clinical.d_icd_diagnoses`

-- 1A) Admissions with sepsis-related ICD-9 descriptions
WITH sepsis_codes AS (
  SELECT
    d.SUBJECT_ID, d.HADM_ID, dd.ICD9_CODE, dd.SHORT_TITLE, dd.LONG_TITLE
  FROM `physionet-data.mimiciii_clinical.diagnoses_icd` d
  INNER JOIN `physionet-data.mimiciii_clinical.d_icd_diagnoses` dd
    ON d.icd9_code = dd.icd9_code
  WHERE LOWER(dd.long_title) LIKE '%sepsis%'
     OR LOWER(dd.long_title) LIKE '%septicemia%'
     OR LOWER(dd.long_title) LIKE '%septic%'
)
SELECT a.SUBJECT_ID, a.HADM_ID, a.ADMITTIME, a.DISCHTIME, a.DEATHTIME,
       a.ADMISSION_TYPE, s.ICD9_CODE, s.SHORT_TITLE, s.LONG_TITLE
FROM `physionet-data.mimiciii_clinical.admissions` a
INNER JOIN sepsis_codes s
  ON a.SUBJECT_ID = s.SUBJECT_ID AND a.HADM_ID = s.HADM_ID
ORDER BY a.admittime;
-- result: 14,578 admissions related to sepsis terms including 99591, 99592, 78552


-----------------------------------------------------------------------
-- PART 2: Lab testing (lactate)
-----------------------------------------------------------------------
-- SELECT * FROM `physionet-data.mimiciii_clinical.d_labitems` WHERE ITEMID = 50931

-- 2A) Lactate ITEMIDs (exclude LDH)
SELECT DISTINCT ITEMID, LABEL, FLUID, CATEGORY, LOINC_CODE
FROM `physionet-data.mimiciii_clinical.d_labitems`
WHERE UPPER(label) LIKE '%LACTATE%'
  AND UPPER(label) NOT LIKE '%DEHYDROGENASE%'
ORDER BY LABEL;
-- result: LACTATE_ITEMIDS = 50813

-- 2B) Lactate label counts
SELECT l.ITEMID, dl.LABEL, COUNT(*) AS n
FROM `physionet-data.mimiciii_clinical.labevents` l
INNER JOIN `physionet-data.mimiciii_clinical.d_labitems` dl
  ON dl.itemid = l.itemid
WHERE LOWER(dl.LABEL) LIKE '%lactate%'
  AND LOWER(dl.LABEL) NOT LIKE '%dehydrogenase%'
GROUP BY l.itemid, dl.LABEL
ORDER BY n DESC;
-- result: 187,116 rows with lactate label; predominant ITEMID 50813

-- 2C) Sample lactate rows to view value ranges/units
SELECT HADM_ID, CHARTTIME, ITEMID, VALUENUM, VALUEUOM
FROM `physionet-data.mimiciii_clinical.labevents`
WHERE itemid = 50813
ORDER BY charttime
LIMIT 200;
-- result: units typically mmol/L


-----------------------------------------------------------------------
-- PART 3: Cultures, weight, MAP
-----------------------------------------------------------------------
-- SELECT * FROM `physionet-data.mimiciii_clinical.microbiologyevents`

-- 3A) Blood culture specimen codes
SELECT DISTINCT SPEC_ITEMID, SPEC_TYPE_DESC
FROM `physionet-data.mimiciii_clinical.microbiologyevents`
WHERE UPPER(SPEC_TYPE_DESC) LIKE '%BLOOD%'
ORDER BY SPEC_TYPE_DESC;
-- result: blood culture SPEC_ITEMID = 70012

-- 3B) First blood culture time per admission
SELECT SUBJECT_ID, HADM_ID, 
  MIN(COALESCE(CAST(charttime AS TIMESTAMP), CAST(chartdate AS TIMESTAMP))) AS first_time
FROM `physionet-data.mimiciii_clinical.microbiologyevents`
WHERE spec_itemid = 70012
GROUP BY subject_id, hadm_id
ORDER BY first_time
LIMIT 100;
-- result: earliest suspected-infection time candidate

-- 3C) Weight itemids (for 30 mL/kg denominator)
SELECT ITEMID, LABEL FROM `physionet-data.mimiciii_clinical.d_items`
WHERE LOWER(LABEL) LIKE '%weight%'
ORDER BY LABEL;
-- result: 226512 = admission weight (kg); 226531 = admission weight (lbs)

-- 3D) Nearest weight to ICU intime (kg)
WITH weights_raw AS (
  SELECT
    i.subject_id, i.hadm_id, i.icustay_id, i.intime,
    ce.charttime, ce.itemid, ce.valuenum
  FROM `physionet-data.mimiciii_clinical.icustays` i
  JOIN `physionet-data.mimiciii_clinical.chartevents` ce
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
    CASE WHEN itemid = 226512 THEN 1 ELSE 2 END AS src_priority, -- prefer kg
    ABS(TIMESTAMP_DIFF(charttime, intime, HOUR)) AS dist_hours
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
-- result: nearest plausible adult weight in kg at ICU admission

-- 3E) MAP itemids (hypotension screening)
SELECT DISTINCT ITEMID, LABEL
FROM `physionet-data.mimiciii_clinical.d_items`
WHERE LOWER(LABEL) LIKE '%mean%bp%' OR LOWER(LABEL) LIKE '%map%'
ORDER BY LABEL;
-- result: candidates include 52, 456, 6702, 220052, 220181, 225312


-----------------------------------------------------------------------
-- PART 4: Medications and fluids
-----------------------------------------------------------------------
-- 4A) Broad-spectrum antibiotic variants present in prescriptions
WITH rx AS (
  SELECT LOWER(DRUG) AS N FROM `physionet-data.mimiciii_clinical.prescriptions`
  UNION DISTINCT SELECT LOWER(DRUG_NAME_POE) FROM `physionet-data.mimiciii_clinical.prescriptions`
  UNION DISTINCT SELECT LOWER(DRUG_NAME_GENERIC) FROM `physionet-data.mimiciii_clinical.prescriptions`
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
-- result: confirms antibiotic spellings/aliases present

-- 4B) IV crystalloids labels
SELECT DISTINCT ITEMID, LABEL
FROM `physionet-data.mimiciii_clinical.d_items`
WHERE LOWER(LABEL) LIKE '%normal saline%'
   OR LOWER(LABEL) LIKE '%sodium chloride 0.9%'
   OR LOWER(LABEL) LIKE '%na cl 0.9%'
   OR LOWER(LABEL) LIKE '%0.9% saline%'
   OR LOWER(LABEL) LIKE '%lactated ringer%'
   OR LOWER(LABEL) LIKE '%ringer% lactate%'
   OR LOWER(LABEL) LIKE '%plasma%lyte%'
ORDER BY LABEL;
-- result: shortlist of crystalloid items

-- 4C) Vasopressors labels
SELECT DISTINCT itemid, label
FROM `physionet-data.mimiciii_clinical.d_items`
WHERE LOWER(label) LIKE '%norepinephrine%'
   OR LOWER(label) LIKE '%noradrenaline%'
   OR LOWER(label) LIKE '%levophed%'
   OR LOWER(label) LIKE '%epinephrine%'
   OR LOWER(label) LIKE '%phenylephrine%'
   OR LOWER(label) LIKE '%vasopressin%'
   OR LOWER(label) LIKE '%dopamine%'
ORDER BY label;
-- result: shortlist of vasopressor items


/* ======================================================================
   PARTS 5–7: Baseline cohort & bundle (3-hour + 6-hour components)
   ====================================================================== */

-----------------------------------------------------------------------
-- PART 5: Cohort + Time Zero
-----------------------------------------------------------------------
WITH patient_cohort AS (
  SELECT 
    p.SUBJECT_ID,
    p.HADM_ID,
    p.ADMITTIME,
    -- age at admission
    DATE_DIFF(p.ADMITTIME, pat.DOB, YEAR) AS age_at_admission,
    
    -- sepsis type indicators
    MAX(CASE WHEN d.ICD9_CODE = '99592' THEN 1 ELSE 0 END) AS severe_sepsis,
    MAX(CASE WHEN d.ICD9_CODE = '78552' THEN 1 ELSE 0 END) AS septic_shock,
    
    -- ICU stay flag
    CASE WHEN i.ICUSTAY_ID IS NOT NULL THEN 1 ELSE 0 END AS in_icu
    
  FROM `physionet-data.mimiciii_clinical.admissions` p
  JOIN `physionet-data.mimiciii_clinical.patients` pat ON p.SUBJECT_ID = pat.SUBJECT_ID
  LEFT JOIN `physionet-data.mimiciii_clinical.diagnoses_icd` d ON p.SUBJECT_ID = d.SUBJECT_ID AND p.HADM_ID = d.HADM_ID
  LEFT JOIN `physionet-data.mimiciii_clinical.icustays` i ON p.SUBJECT_ID = i.SUBJECT_ID AND p.HADM_ID = i.HADM_ID
  WHERE d.ICD9_CODE IN ('99591', '99592', '78552')
    AND DATE_DIFF(p.ADMITTIME, pat.DOB, YEAR) >= 18
  GROUP BY p.SUBJECT_ID, p.HADM_ID, p.ADMITTIME, pat.DOB, i.ICUSTAY_ID
),

sepsis_time_zero AS (
  SELECT 
    pc.SUBJECT_ID,
    pc.HADM_ID,
    -- earliest of blood culture or antibiotics
    LEAST(
      COALESCE(MIN(CAST(m.CHARTTIME AS TIMESTAMP)), TIMESTAMP('9999-12-31')),
      COALESCE(MIN(TIMESTAMP(rx.STARTDATE) + INTERVAL 12 HOUR), TIMESTAMP('9999-12-31'))
    ) AS sepsis_time_zero
  FROM patient_cohort pc
  LEFT JOIN `physionet-data.mimiciii_clinical.microbiologyevents` m 
    ON pc.SUBJECT_ID = m.SUBJECT_ID AND pc.HADM_ID = m.HADM_ID
    AND m.SPEC_ITEMID = 70012 -- blood culture
  LEFT JOIN `physionet-data.mimiciii_clinical.prescriptions` rx 
    ON pc.SUBJECT_ID = rx.SUBJECT_ID AND pc.HADM_ID = rx.HADM_ID
    AND (LOWER(rx.DRUG) LIKE '%cefepime%' OR LOWER(rx.DRUG) LIKE '%vancomycin%' OR LOWER(rx.DRUG) LIKE '%piperacillin%')
  GROUP BY pc.SUBJECT_ID, pc.HADM_ID
)
-- result: admissions with defined sepsis_time_zero
,

-----------------------------------------------------------------------
-- PART 6: Bundle components (3-hour + 6-hour)
-----------------------------------------------------------------------

-- 6.1 Lactate within 3h of time zero; capture initial value
lactate_3h AS (
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN TIMESTAMP_DIFF(CAST(le.CHARTTIME AS TIMESTAMP), stz.sepsis_time_zero, HOUR) <= 3 THEN 1 ELSE 0 END) AS lactate_measured_3h,
    MAX(CASE WHEN TIMESTAMP_DIFF(CAST(le.CHARTTIME AS TIMESTAMP), stz.sepsis_time_zero, HOUR) <= 3 THEN le.VALUENUM END) AS initial_lactate_value
  FROM sepsis_time_zero stz
  LEFT JOIN `physionet-data.mimiciii_clinical.labevents` le 
    ON stz.SUBJECT_ID = le.SUBJECT_ID AND stz.HADM_ID = le.HADM_ID
    AND le.ITEMID = 50813  -- lactate
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
),
-- result: binary flag and value for initial lactate

-- 6.2 Blood culture within 3h
blood_culture_3h AS (
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN TIMESTAMP_DIFF(CAST(m.CHARTTIME AS TIMESTAMP), stz.sepsis_time_zero, HOUR) <= 3 THEN 1 ELSE 0 END) AS blood_culture_3h
  FROM sepsis_time_zero stz
  LEFT JOIN `physionet-data.mimiciii_clinical.microbiologyevents` m 
    ON stz.SUBJECT_ID = m.SUBJECT_ID AND stz.HADM_ID = m.HADM_ID
    AND m.SPEC_ITEMID = 70012 -- blood culture
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
),
-- result: binary flag for culture timing

-- 6.3 Broad-spectrum antibiotic within 3h
antibiotics_3h AS (
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN TIMESTAMP_DIFF(TIMESTAMP(rx.STARTDATE) + INTERVAL 12 HOUR, stz.sepsis_time_zero, HOUR) <= 3 THEN 1 ELSE 0 END) AS antibiotics_3h
  FROM sepsis_time_zero stz
  LEFT JOIN `physionet-data.mimiciii_clinical.prescriptions` rx 
    ON stz.SUBJECT_ID = rx.SUBJECT_ID AND stz.HADM_ID = rx.HADM_ID
    AND (LOWER(rx.DRUG) LIKE '%cefepime%' OR LOWER(rx.DRUG) LIKE '%vancomycin%' OR LOWER(rx.DRUG) LIKE '%piperacillin%')
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
),
-- result: binary flag for antibiotic timing

-- 6.4 Septic shock: fluids within 3h (indicator)
fluids_3h AS (
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN TIMESTAMP_DIFF(CAST(ce.CHARTTIME AS TIMESTAMP), stz.sepsis_time_zero, HOUR) <= 3 
             AND ce.ITEMID IN (30061, 30062, 30063) -- common crystalloid items; confirm locally
             THEN 1 ELSE 0 END) AS fluids_administered_3h
  FROM sepsis_time_zero stz
  LEFT JOIN `physionet-data.mimiciii_clinical.chartevents` ce 
    ON stz.SUBJECT_ID = ce.SUBJECT_ID AND stz.HADM_ID = ce.HADM_ID
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
),
-- result: binary flag for initial fluid administration

-- 6-hour components
-- 6.5 Severe sepsis: repeat lactate 3–6h
repeat_lactate_6h AS (
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN TIMESTAMP_DIFF(CAST(le.CHARTTIME AS TIMESTAMP), stz.sepsis_time_zero, HOUR) BETWEEN 3 AND 6 THEN 1 ELSE 0 END) AS repeat_lactate_6h
  FROM sepsis_time_zero stz
  LEFT JOIN `physionet-data.mimiciii_clinical.labevents` le 
    ON stz.SUBJECT_ID = le.SUBJECT_ID AND stz.HADM_ID = le.HADM_ID
    AND le.ITEMID = 50813  -- lactate
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
),
-- result: binary flag for repeat lactate timing

-- 6.6 Septic shock: vasopressors within 6h
vasopressors_6h AS (
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN TIMESTAMP_DIFF(CAST(ce.CHARTTIME AS TIMESTAMP), stz.sepsis_time_zero, HOUR) <= 6
             AND ce.ITEMID IN (221906, 221289, 221749, 222315, 221662) -- norepinephrine, epinephrine, phenylephrine, vasopressin, dopamine (ICU itemids)
             THEN 1 ELSE 0 END) AS vasopressors_administered_6h
  FROM sepsis_time_zero stz
  LEFT JOIN `physionet-data.mimiciii_clinical.chartevents` ce 
    ON stz.SUBJECT_ID = ce.SUBJECT_ID AND stz.HADM_ID = ce.HADM_ID
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
),
-- result: binary flag for vasopressor timing

-- 6.7 Septic shock: MAP < 65 after fluids (3–6h)
map_after_fluids AS (
  SELECT 
    stz.SUBJECT_ID,
    stz.HADM_ID,
    MAX(CASE WHEN TIMESTAMP_DIFF(CAST(ce.CHARTTIME AS TIMESTAMP), stz.sepsis_time_zero, HOUR) BETWEEN 3 AND 6
             AND ce.ITEMID IN (52, 456, 6702, 443, 220052, 220181, 225312) -- MAP itemids
             AND ce.VALUENUM < 65
             THEN 1 ELSE 0 END) AS persistent_hypotension_6h
  FROM sepsis_time_zero stz
  LEFT JOIN `physionet-data.mimiciii_clinical.chartevents` ce 
    ON stz.SUBJECT_ID = ce.SUBJECT_ID AND stz.HADM_ID = ce.HADM_ID
  GROUP BY stz.SUBJECT_ID, stz.HADM_ID
)
-- result: binary flag for MAP < 65 in 3–6h window
,

-----------------------------------------------------------------------
-- PART 7: Final measures + output (3h & 6h composites)
-----------------------------------------------------------------------
final_measures AS (
  SELECT 
    pc.SUBJECT_ID,
    pc.HADM_ID,
    pc.age_at_admission,
    pc.severe_sepsis,
    pc.septic_shock,
    stz.sepsis_time_zero,

    -- 3-hour bundle
    COALESCE(lac.lactate_measured_3h, 0) AS lactate_measured_3h,
    lac.initial_lactate_value,
    COALESCE(bc.blood_culture_3h, 0)     AS blood_culture_3h,
    COALESCE(abx.antibiotics_3h, 0)      AS antibiotics_3h,

    -- septic shock additional (fluids within 3h)
    COALESCE(fl.fluids_administered_3h, 0) AS fluids_administered_3h,

    -- 6-hour bundle
    COALESCE(rl.repeat_lactate_6h, 0)        AS repeat_lactate_6h,
    COALESCE(vs.vasopressors_administered_6h, 0) AS vasopressors_administered_6h,
    COALESCE(mf.persistent_hypotension_6h, 0)    AS persistent_hypotension_6h,
    
    -- 3-hour composite
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
    
    -- 6-hour composite
    CASE 
      WHEN pc.severe_sepsis = 1 THEN
        CASE WHEN (lac.initial_lactate_value IS NULL OR lac.initial_lactate_value <= 2) 
               OR (lac.initial_lactate_value > 2 AND COALESCE(rl.repeat_lactate_6h, 0) = 1)
             THEN 1 ELSE 0 END
      WHEN pc.septic_shock = 1 THEN
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

-- final output (NULL for non-applicable measures)
SELECT 
  SUBJECT_ID,
  HADM_ID,
  age_at_admission,
  severe_sepsis,
  septic_shock,
  sepsis_time_zero,

  -- 3-hour bundle
  lactate_measured_3h,
  initial_lactate_value,
  blood_culture_3h,
  antibiotics_3h,
  CASE WHEN septic_shock = 1 THEN fluids_administered_3h ELSE NULL END AS fluids_administered_3h,

  -- 6-hour bundle
  CASE WHEN severe_sepsis = 1 THEN repeat_lactate_6h ELSE NULL END AS repeat_lactate_6h,
  CASE WHEN septic_shock = 1 THEN vasopressors_administered_6h ELSE NULL END AS vasopressors_administered_6h,
  CASE WHEN septic_shock = 1 THEN persistent_hypotension_6h ELSE NULL END AS persistent_hypotension_6h,

  -- composites
  bundle_complete_3h,
  bundle_complete_6h,

  -- overall bundle completion
  CASE 
    WHEN bundle_complete_3h = 1 AND bundle_complete_6h = 1 THEN 1
    ELSE 0
  END AS bundle_complete_overall
FROM final_measures
ORDER BY SUBJECT_ID, HADM_ID;
