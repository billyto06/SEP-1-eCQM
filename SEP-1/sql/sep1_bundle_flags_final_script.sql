USE [physionet-data]
GO

/****** Object:  View [mimiciii_clinical].[sep1_bundle_flags_final]    Script Date: 11/17/2025 4:04:32 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE   VIEW [mimiciii_clinical].[sep1_bundle_flags_final]
AS
WITH base AS (
  SELECT * FROM [mimiciii_clinical].[sep1_bundle_flags]
),
abx_fix AS (
  SELECT s.SUBJECT_ID, s.HADM_ID,
         MAX(CASE
               WHEN rx.STARTDATE >= s.sepsis_time_zero
                AND rx.STARTDATE <  DATEADD(HOUR, 3, s.sepsis_time_zero)
                AND (
                     LOWER(rx.DRUG) LIKE '%cefepime%' OR LOWER(rx.DRUG_NAME_GENERIC) LIKE '%cefepime%'
                  OR LOWER(rx.DRUG) LIKE '%vancomycin%' OR LOWER(rx.DRUG_NAME_GENERIC) LIKE '%vancomycin%'
                  OR LOWER(rx.DRUG) LIKE '%piperacillin%' OR LOWER(rx.DRUG_NAME_GENERIC) LIKE '%piperacillin%'
                )
               THEN 1 ELSE 0 END) AS antibiotics_3h_fixed
  FROM base s
  LEFT JOIN [mimiciii_clinical].[prescriptions] rx
    ON rx.SUBJECT_ID = s.SUBJECT_ID AND rx.HADM_ID = s.HADM_ID
  GROUP BY s.SUBJECT_ID, s.HADM_ID
),
icd AS (
  SELECT d.HADM_ID,
         MAX(CASE WHEN d.ICD9_CODE = '78552' THEN 1 ELSE 0 END) AS shock_icd,
         MAX(CASE WHEN d.ICD9_CODE IN ('99592','78552') THEN 1 ELSE 0 END) AS sepsis_icd
  FROM [mimiciii_clinical].[diagnoses_icd] d
  GROUP BY d.HADM_ID
),
flags AS (
  SELECT b.*,
         CASE WHEN COALESCE(b.septic_shock,0)=1 THEN 1
              WHEN COALESCE(i.shock_icd,0)=1     THEN 1 ELSE 0 END AS septic_shock_fix,
         CASE WHEN COALESCE(b.severe_sepsis,0)=1 AND COALESCE(b.septic_shock,0)=0 THEN 1
              WHEN COALESCE(b.severe_sepsis,0)=1 AND COALESCE(b.septic_shock,0)=1 THEN 0
              WHEN COALESCE(i.sepsis_icd,0)=1 AND COALESCE(i.shock_icd,0)=0 THEN 1
              ELSE 0 END AS severe_sepsis_fix
  FROM base b
  LEFT JOIN icd i ON i.HADM_ID = b.HADM_ID
),
b AS (
  SELECT
    f.SUBJECT_ID, f.HADM_ID, f.age_at_admission,
    f.severe_sepsis_fix AS severe_sepsis,
    f.septic_shock_fix  AS septic_shock,
    f.sepsis_time_zero,
    f.lactate_measured_3h,
    f.initial_lactate_value,
    f.blood_culture_3h,
    a.antibiotics_3h_fixed AS antibiotics_3h,
    CASE WHEN f.septic_shock_fix=1 THEN f.fluids_administered_3h      ELSE NULL END AS fluids_administered_3h,
    CASE WHEN f.severe_sepsis_fix=1 THEN f.repeat_lactate_6h          ELSE NULL END AS repeat_lactate_6h,
    CASE WHEN f.septic_shock_fix =1 THEN f.vasopressors_administered_6h ELSE NULL END AS vasopressors_administered_6h,
    CASE WHEN f.septic_shock_fix =1 THEN f.persistent_hypotension_6h  ELSE NULL END AS persistent_hypotension_6h
  FROM flags f
  JOIN abx_fix a ON a.SUBJECT_ID=f.SUBJECT_ID AND a.HADM_ID=f.HADM_ID
),
threeh AS (
  SELECT b.HADM_ID,
         CASE
           WHEN b.severe_sepsis=1 THEN
             CASE WHEN COALESCE(b.lactate_measured_3h,0)=1
                    AND COALESCE(b.blood_culture_3h,0)=1
                    AND COALESCE(b.antibiotics_3h,0)=1
                  THEN 1 ELSE 0 END
           WHEN b.septic_shock=1 THEN
             CASE WHEN COALESCE(b.lactate_measured_3h,0)=1
                    AND COALESCE(b.blood_culture_3h,0)=1
                    AND COALESCE(b.antibiotics_3h,0)=1
                    AND COALESCE(b.fluids_administered_3h,0)=1
                  THEN 1 ELSE 0 END
           ELSE 0
         END AS bundle_complete_3h
  FROM b
),
six_flag AS (
  SELECT b.HADM_ID,
         CASE
           WHEN b.severe_sepsis=1 THEN
             CASE WHEN (b.initial_lactate_value IS NULL OR b.initial_lactate_value <= 2)
                        OR (b.initial_lactate_value > 2 AND COALESCE(b.repeat_lactate_6h,0)=1)
                  THEN 1 ELSE 0 END
           WHEN b.septic_shock=1 THEN
             CASE WHEN COALESCE(b.vasopressors_administered_6h,0)=1
                        AND (COALESCE(b.persistent_hypotension_6h,0)=1
                             OR (b.initial_lactate_value IS NOT NULL AND b.initial_lactate_value >= 4))
                  THEN 1 ELSE 0 END
           ELSE 0
         END AS six_ok
  FROM b
)
SELECT
  b.SUBJECT_ID, b.HADM_ID, b.age_at_admission,
  b.severe_sepsis, b.septic_shock, b.sepsis_time_zero,
  b.lactate_measured_3h, b.initial_lactate_value, b.blood_culture_3h, b.antibiotics_3h,
  b.fluids_administered_3h, b.repeat_lactate_6h, b.vasopressors_administered_6h, b.persistent_hypotension_6h,
  t.bundle_complete_3h,
  CASE WHEN t.bundle_complete_3h=1 THEN s.six_ok ELSE 0 END AS bundle_complete_6h,
  CASE WHEN t.bundle_complete_3h=1 AND s.six_ok=1 THEN 1 ELSE 0 END AS bundle_complete_overall
FROM b
JOIN threeh  t ON t.HADM_ID=b.HADM_ID
JOIN six_flag s ON s.HADM_ID=b.HADM_ID;
GO

