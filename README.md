# SEP-1 Sepsis Bundle: SQL + Power BI (Synthetic Data)

This project implements the **SEP-1 sepsis bundle** logic in:

- **BigQuery SQL**
- **SQL Server T-SQL**

…and then visualizes performance in **Power BI** using **synthetic data only**.

The goal is **reproducible analytics**, not clinical guidance.

---

## Table of Contents

1. [Background: What is SEP-1?](#background-what-is-sep-1)
2. [What This Project Does](#what-this-project-does)
3. [Repository Structure](#repository-structure)
4. [How to Use the Power BI Report](#how-to-use-the-power-bi-report)
   - [Fastest Path (CSV only)](#fastest-path-csv-only)
   - [Using SQL Server](#using-sql-server)
5. [Power BI Pages](#power-bi-pages)
6. [Data Notes](#data-notes)
7. [Disclaimers](#disclaimers)

---

## Background: What is SEP-1?

**SEP-1** is a quality measure for early management of **severe sepsis** and **septic shock**.  
In plain language, it checks whether key care steps happened on time after **“sepsis time zero.”**

### 3-hour bundle

- Serum lactate measured  
- Blood cultures collected *before* antibiotics  
- Broad-spectrum antibiotics started  
- For septic shock: adequate fluids

### 6-hour bundle

- For severe sepsis: repeat lactate if initial value > 2 mmol/L  
- For septic shock:
  - Vasopressors if needed  
  - Evidence of perfusion-target workup  
    - (often satisfied by persistent hypotension or initial lactate ≥ 4)

This repo focuses on **logic and analytics** implementing these rules, not on clinical decision-making.

---

## What This Project Does

### 1. Cohort + Time Zero

- Identifies **suspected sepsis encounters**
- Computes **sepsis time zero** from the first qualifying events

### 2. Component Flags

Builds on-time indicators for each SEP-1 step, including:

- Lactate measurement
- Blood culture before antibiotics
- Antibiotics within 3 hours
- Adequate fluids for septic shock
- Repeat lactate when required
- Vasopressors path and perfusion target workup

### 3. Bundle Composites

- Derives **3-hour** and **6-hour** bundle pass flags
- Builds an **overall SEP-1 pass** flag that respects the relevant clinical path (severe sepsis vs septic shock)

### 4. BI-Ready Final View

- Exposes a **tidy, analytics-ready view** for Power BI
- One row per admission, with:
  - All component flags
  - Bundle composites
  - IDs and timestamps needed for QA/drill-down

---

## Repository Structure

### SQL

- `sql/sep1_ecqm_cohort_bundle.sql`  
  BigQuery SQL implementation.

- `sql/SEP-1_SQL_SERVER.sql`  
  SQL Server implementation.

- `sql/10_view_sep1_bundle_flags_final.sql`  
  Final view definition used by the Power BI report.

### Power BI

- `powerbi/sep1-report.pbit`  
  Power BI **template** with:
  - Data model
  - Measures
  - Visuals wired to the final view.

- *(Optional)* `powerbi/sep1-report-demo.pbix`  
  PBIX version that already contains synthetic demo data (if present).

### Data (Synthetic Only)

- `data/sep1_bundle_flags_final_sample.csv`  
  Synthetic snapshot of the final view for quick demos and offline use.

### Screenshots

- `screenshots/page1_overview.png`  
- `screenshots/page2_qa.png`  

Preview images of the main report pages.

### Demo / Seed Data (Optional)

- `sql/demo_data/*.sql`  
  Seeder scripts / patches used to generate synthetic demo rows (not required for using the logic itself).

---

## How to Use the Power BI Report

### Fastest Path (CSV only)

This option does **not** require a database.

1. Open:  
   `powerbi/sep1-report.pbit`
2. When prompted for data, point the **fact table** to:  
   `data/sep1_bundle_flags_final_sample.csv`
3. Load the model.  
   - All visuals and measures will render against the sample synthetic data.

---

### Using SQL Server

1. Create the final view in your database using:  
   `sql/10_view_sep1_bundle_flags_final.sql`

   This should create:

   ```sql
   [mimiciii_clinical].[sep1_bundle_flags_final]
