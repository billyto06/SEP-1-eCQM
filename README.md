SEP-1 Sepsis Bundle: SQL + Power BI (Synthetic Data)

This project implements the SEP-1 sepsis bundle in both BigQuery SQL and SQL Server T-SQL, then visualizes performance in Power BI using synthetic data.

What is SEP-1

SEP-1 is a quality measure for the early management of severe sepsis and septic shock. In plain terms, it checks whether key care steps happened on time after “sepsis time zero.”

3-hour bundle:

Serum lactate measured

Blood cultures collected before antibiotics

Broad-spectrum antibiotics started

For septic shock: adequate fluids

6-hour bundle:

For severe sepsis: repeat lactate if the initial value was greater than 2 mmol/L

For septic shock: vasopressors if needed and evidence of perfusion target workup (often satisfied by persistent hypotension or initial lactate greater than or equal to 4)

This repo focuses on logic and reproducible analytics rather than clinical guidance.

What my code does

Cohort and time zero: Finds suspected sepsis encounters and calculates sepsis time zero from first qualifying events.

Component flags: Derives on-time indicators for each SEP-1 step (lactate, culture before antibiotics, antibiotics within 3 hours, fluids for shock, repeat lactate logic, vasopressors path).

Bundle composites: Builds 3-hour and 6-hour pass flags and an overall pass flag that respects the clinical paths.

BI-ready view: Exposes a tidy final view for Power BI with one row per admission plus all component flags and composites.

What is included

sql/sep1_ecqm_cohort_bundle.sql — BigQuery SQL version

sql/SEP-1_SQL_SERVER.sql — SQL Server version

sql/10_view_sep1_bundle_flags_final.sql — the exact view consumed by the report

powerbi/sep1-report.pbit — Power BI template with model, measures, and visuals

data/sep1_bundle_flags_final_sample.csv — synthetic snapshot of the final view for quick demos

screenshots/page1_overview.png, screenshots/page2_qa.png — report previews

Optional items you might see:

powerbi/sep1-report-demo.pbix — a PBIX that already contains synthetic data

sql/demo_data/*.sql — seeders or patches used only to generate synthetic demo rows

How to open the report

Fastest (no database needed)

Open powerbi/sep1-report.pbit

When prompted for data, point the fact table to data/sep1_bundle_flags_final_sample.csv

The visuals and measures will render on the sample

Using SQL Server

Create the final view using sql/10_view_sep1_bundle_flags_final.sql in your database

In Power BI, open powerbi/sep1-report.pbit and enter your Server and Database

Load the view [mimiciii_clinical].[sep1_bundle_flags_final]

Example query used by the report:

SELECT *
FROM [mimiciii_clinical].[sep1_bundle_flags_final];

Pages in the Power BI report

Page 1: Overview — admissions by month, component tiles, overall bundle rate, and a combo chart that shows volume next to performance

Page 2: QA and drill — patient-level table with green/red flags and component KPIs for quick troubleshooting

Data notes

The report uses synthetic data only.

During development I validated logic using the MIMIC-III schema and event patterns. The original MIMIC-III data is not included here for privacy and licensing reasons.

The BigQuery and SQL Server scripts are written to run independently. You can adopt either platform.

Disclaimers

This is an analytics demo. It is not clinical advice.

SEP-1 rules evolve. Always review against your organization’s current measure specification.
