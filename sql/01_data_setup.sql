-- ============================================================================
-- 01_data_setup.sql
-- STEP 1: PONDASI / FOUNDATION — Skema database, tabel, & seed schema
-- ============================================================================
--
-- FUNGSI / TUJUAN:
--   Mendirikan "panggung" untuk seluruh pipeline compliance AI. Script ini
--   membuat semua tabel target yang nantinya akan di-AUDIT. Tanpa script
--   ini, tidak ada data sama sekali untuk diklasifikasi (script 03)
--   atau diaudit terhadap regulasi (script 04 / 05).
--
--   Filosofi: tabel-tabel di sini sengaja dibuat MIRIP dengan core
--   banking schema BTN (NASABAH, REKENING, KARTU_KREDIT,
--   LOAN_APPLICATION, TLHIST_TRANSAKSI, GOAML_ODM_TRANSAKSI,
--   RTGS_SKNBI_PAYMENT) supaya hasil AI klasifikasi & gap analysis
--   relevan dengan dunia nyata bank Indonesia (UU PDP, KYC/AML, BI-RTGS,
--   SKNBI).
--
-- INPUT:
--   - Tidak ada (script ini adalah titik awal pipeline)
--   - Optional: data CSV bisa di-load setelah tabel dibuat
--
-- ISI / KONTEN UTAMA:
--   A. CUSTOMER_DATA schema (target UC1 — UU PDP / Privacy)
--        * NASABAH           — master nasabah (NIK, NAMA, EMAIL, NPWP,
--                              ALAMAT, TANGGAL_LAHIR, NAMA_IBU_KANDUNG,
--                              PENDAPATAN_BULANAN, dll.) → kaya akan PII
--        * REKENING          — saldo, no rekening, tipe rekening
--        * KARTU_KREDIT      — NOMOR_KARTU, CVV, CREDIT_LIMIT
--                              (CVV sengaja ada untuk uji deteksi
--                              violation PCI-DSS / UU PDP)
--        * LOAN_APPLICATION  — pengajuan pinjaman + data penjamin
--
--   B. TRANSACTION_DATA schema (target UC2 & UC3 — internal policy &
--      regulator BI/OJK)
--        * TLHIST_TRANSAKSI    — core transaction history (debit/credit,
--                                channel ATM/MB/IB/Teller, IP, device)
--        * GOAML_ODM_TRANSAKSI — format pelaporan AML / goAML
--                                (untuk uji KYC, cross-border, SWIFT)
--        * RTGS_SKNBI_PAYMENT  — pembayaran lewat BI-RTGS / SKNBI
--                                (untuk uji settlement & operational risk)
--
-- KENAPA STRUKTUR INI?
--   Setiap kolom dipilih DENGAN NIAT supaya bisa mendemo violation:
--     - Field PII jelas (NIK, NPWP, NAMA_IBU_KANDUNG) → akan di-VIOLATION
--       oleh script 04/05 jika belum dipasang masking policy
--     - CVV di KARTU_KREDIT → akan ditandai CRITICAL (PCI-DSS / UU PDP
--       melarang penyimpanan CVV)
--     - KYC_VERIFIED & AML_SCREENING di RTGS_SKNBI_PAYMENT (Y/N) → bisa
--       sengaja diisi 'N' untuk men-trigger AML violation finding
--     - Cross-border fields (CCY, XRATE, SWIFT_LAWAN, CNTRY_CODE) →
--       relevan dengan regulasi BI tentang devisa & SWIFT
--
-- OUTPUT (objek yang dibuat):
--   - 4 tabel di schema CUSTOMER_DATA
--   - 3 tabel di schema TRANSACTION_DATA
--   - (Sintetis 10K rows / tabel transaksi di-load lewat GENERATOR
--     atau CSV PUT — lihat README "Step 1")
--
-- DEPENDENCY:
--   - Database BTN_COMPLIANCE_AI_DEMO sudah ada
--   - Schema CUSTOMER_DATA & TRANSACTION_DATA sudah ada
--   - Warehouse BTN_POC tersedia
--   - Role ACCOUNTADMIN (atau equivalent: CREATE TABLE privilege)
--
-- POSISI DI PIPELINE:
--   [01_data_setup] → 02_parse_documents → 03_ai_classification →
--   04_gap_analysis → 05_refresh_stored_procedures
--
-- HUBUNGAN DENGAN SCRIPT LAIN:
--   - Script 03 akan men-SCAN INFORMATION_SCHEMA atas tabel-tabel di
--     sini, lalu LLM akan memberi label PII / Financial / Sensitive
--     berdasarkan nama tabel + nama kolom + tipe data.
--   - Script 04 / 05 akan mengambil hasil label tersebut + isi pasal
--     regulasi (dari script 02), lalu memvonis kolom mana yang
--     compliant vs violation.
--   - Tabel di sini juga merupakan SUMBER VALUE-LEVEL AUDIT (script
--     03 tahap B) — AI sample 5 baris dari kolom CRITICAL/HIGH untuk
--     tahu apakah datanya plain-text atau hashed.
--
-- CATATAN PENTING:
--   - Tidak ada data nasabah ASLI di sini. Data sintetis di-generate
--     pakai TABLE(GENERATOR(...)) + UNIFORM (lihat README).
--   - Aman untuk di-recreate (semua statement pakai
--     CREATE OR REPLACE TABLE). Tapi awas: kalau script 03 / 04 sudah
--     pernah dijalankan, hasilnya jadi stale dan perlu di-refresh ulang.
-- ============================================================================
-- BTN Compliance AI POC - 01: Customer + Transaction tables with synthetic data
-- ============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE BTN_POC;
USE DATABASE BTN_COMPLIANCE_AI_DEMO;

-- ============================================================================
-- USE CASE 1: Customer / PII tables (UU PDP scope)
-- ============================================================================
CREATE OR REPLACE TABLE CUSTOMER_DATA.NASABAH (
    CUSTOMER_ID VARCHAR(20),
    NAMA_LENGKAP VARCHAR(100),
    NIK VARCHAR(16),
    EMAIL VARCHAR(100),
    NO_TELEPON VARCHAR(20),
    ALAMAT VARCHAR(200),
    TANGGAL_LAHIR DATE,
    NAMA_IBU_KANDUNG VARCHAR(100),
    NPWP VARCHAR(20),
    PENDAPATAN_BULANAN NUMBER(15,2),
    STATUS_PERNIKAHAN VARCHAR(20),
    PEKERJAAN VARCHAR(50),
    CABANG VARCHAR(50),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CUSTOMER_DATA.REKENING (
    REKENING_ID VARCHAR(20),
    CUSTOMER_ID VARCHAR(20),
    NO_REKENING VARCHAR(20),
    TIPE_REKENING VARCHAR(30),
    SALDO NUMBER(18,2),
    MATA_UANG VARCHAR(5),
    TANGGAL_BUKA DATE,
    STATUS VARCHAR(10),
    CABANG VARCHAR(50),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CUSTOMER_DATA.KARTU_KREDIT (
    CARD_ID VARCHAR(20),
    CUSTOMER_ID VARCHAR(20),
    NOMOR_KARTU VARCHAR(19),
    NAMA_DI_KARTU VARCHAR(100),
    TANGGAL_KADALUARSA VARCHAR(7),
    CVV VARCHAR(4),
    CREDIT_LIMIT NUMBER(15,2),
    OUTSTANDING_BALANCE NUMBER(15,2),
    STATUS VARCHAR(10),
    TIPE_KARTU VARCHAR(20),
    CABANG VARCHAR(50),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CUSTOMER_DATA.LOAN_APPLICATION (
    APPLICATION_ID VARCHAR(20),
    CUSTOMER_ID VARCHAR(20),
    TIPE_PINJAMAN VARCHAR(30),
    JUMLAH_PINJAMAN NUMBER(18,2),
    TENOR_BULAN NUMBER(5,0),
    SUKU_BUNGA NUMBER(5,2),
    PENDAPATAN_PEMOHON NUMBER(15,2),
    CREDIT_SCORE NUMBER(5,0),
    NAMA_PENJAMIN VARCHAR(100),
    NIK_PENJAMIN VARCHAR(16),
    STATUS_APPROVAL VARCHAR(20),
    CATATAN_INTERNAL VARCHAR(500),
    TANGGAL_PENGAJUAN DATE,
    CABANG VARCHAR(50),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================================
-- USE CASE 2-3: Transaction tables (10K rows each)
-- ============================================================================
CREATE OR REPLACE TABLE TRANSACTION_DATA.TLHIST_TRANSAKSI (
    TRX_ID VARCHAR(20),                  -- TLBID
    TRX_DATE TIMESTAMP_NTZ,
    CIF VARCHAR(20),
    NO_REKENING VARCHAR(25),
    REF_NUMBER VARCHAR(40),
    DEBIT_CREDIT VARCHAR(1),             -- D or C
    AMOUNT NUMBER(20,2),
    CURRENCY VARCHAR(5),
    XRATE NUMBER(15,5),
    IDR_AMOUNT NUMBER(20,2),
    TX_CODE VARCHAR(10),
    TX_LOCATION VARCHAR(50),
    TX_REMARK VARCHAR(200),
    TELLER_ID VARCHAR(20),
    AUTH_BY VARCHAR(20),
    CABANG VARCHAR(50),
    POST_DATE DATE,
    TX_MODE VARCHAR(20),                  -- ATM, MB, IB, TLR
    CHANNEL VARCHAR(20),
    NAMA_PENGIRIM VARCHAR(100),
    NAMA_PENERIMA VARCHAR(100),
    REK_LAWAN VARCHAR(25),
    BANK_LAWAN VARCHAR(50),
    NIK_PENGIRIM VARCHAR(16),
    NPWP_PENGIRIM VARCHAR(20),
    IP_ADDRESS VARCHAR(15),
    DEVICE_ID VARCHAR(50),
    STATUS VARCHAR(20),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE TRANSACTION_DATA.GOAML_ODM_TRANSAKSI (
    TX_ID VARCHAR(20),
    TX_DATE DATE,
    CIF VARCHAR(20),
    ACC_NO VARCHAR(25),
    REF_NUM VARCHAR(40),
    DC VARCHAR(1),
    ORIG_AMT NUMBER(20,2),
    CCY VARCHAR(5),
    XRATE NUMBER(15,5),
    IDR_AMT NUMBER(20,2),
    TX_CODE VARCHAR(10),
    SRC_DATA VARCHAR(20),
    TX_LOC VARCHAR(50),
    TX_REMARK VARCHAR(300),
    TX_NUM VARCHAR(40),
    CNTRY_CODE VARCHAR(5),
    TELLER VARCHAR(20),
    POST_DATE DATE,
    TX_MODE VARCHAR(10),
    CIF_LAWAN VARCHAR(20),
    ACC_LAWAN VARCHAR(25),
    BANK_LAWAN VARCHAR(80),
    SWIFT_LAWAN VARCHAR(20),
    CNTRY_LAWAN VARCHAR(5),
    NAMA_LAWAN_INDV VARCHAR(100),
    NAMA_LAWAN_CORP VARCHAR(100),
    BIZ_DATE DATE,
    NIK_NASABAH VARCHAR(16),              -- KYC indicator
    NPWP_NASABAH VARCHAR(20),
    ADDR_LAWAN VARCHAR(200),
    TX_STATUS VARCHAR(10),
    CABANG VARCHAR(50),
    ACTIVE NUMBER(1),
    CREATED_BY VARCHAR(30),
    CREATED_DT DATE
);

-- 3rd transaction table: BI-RTGS / SKNBI payments
CREATE OR REPLACE TABLE TRANSACTION_DATA.RTGS_SKNBI_PAYMENT (
    PAYMENT_ID VARCHAR(20),
    PAYMENT_DATE TIMESTAMP_NTZ,
    SETTLEMENT_TYPE VARCHAR(10),          -- RTGS or SKNBI
    AMOUNT NUMBER(20,2),
    CURRENCY VARCHAR(5),
    SENDER_BANK VARCHAR(50),
    SENDER_BANK_CODE VARCHAR(10),
    SENDER_ACC VARCHAR(25),
    SENDER_NAME VARCHAR(100),
    SENDER_NIK VARCHAR(16),
    SENDER_NPWP VARCHAR(20),
    SENDER_ADDR VARCHAR(200),
    BENEFICIARY_BANK VARCHAR(50),
    BENEFICIARY_BANK_CODE VARCHAR(10),
    BENEFICIARY_ACC VARCHAR(25),
    BENEFICIARY_NAME VARCHAR(100),
    BENEFICIARY_NIK VARCHAR(16),
    PURPOSE_CODE VARCHAR(10),
    PURPOSE_DESC VARCHAR(200),
    REMITTANCE_INFO VARCHAR(500),
    REF_NUMBER VARCHAR(40),
    BIC_SENDER VARCHAR(15),
    BIC_BENEFICIARY VARCHAR(15),
    SETTLEMENT_STATUS VARCHAR(20),
    SETTLEMENT_TIME TIMESTAMP_NTZ,
    CABANG VARCHAR(50),
    OPERATOR_ID VARCHAR(20),
    APPROVAL_LEVEL VARCHAR(10),
    KYC_VERIFIED VARCHAR(1),              -- Y/N (intentional violations)
    AML_SCREENING VARCHAR(1),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
