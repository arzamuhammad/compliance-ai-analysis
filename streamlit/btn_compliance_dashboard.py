"""
BTN Compliance AI Dashboard v2
Sidebar menu + multi-tab per UC + refresh button (claude-opus-4-7)
"""
import streamlit as st
import pandas as pd
import altair as alt
import time

# -------------------------------------------------------------------
st.set_page_config(page_title="BTN Compliance AI", page_icon="🏦",
                   layout="wide", initial_sidebar_state="expanded")

BTN_LIGHT_BLUE = "#5BA3D9"
BTN_BLUE       = "#0072BC"
BTN_DARK_BLUE  = "#003D7C"
BTN_RED        = "#E32726"
BTN_GOLD       = "#F2A900"
BTN_BG         = "#F5FAFE"

st.markdown(f"""
<style>
.main {{ background-color: {BTN_BG}; }}
[data-testid="stSidebar"] {{
    background: linear-gradient(180deg, {BTN_LIGHT_BLUE} 0%, {BTN_BLUE} 100%);
}}
[data-testid="stSidebar"] * {{ color: white !important; }}
.kpi-card {{
    background: white; border-left: 6px solid {BTN_BLUE};
    padding: 16px 18px; border-radius: 10px;
    box-shadow: 0 2px 6px rgba(0,0,0,0.08); margin-bottom: 8px;
}}
.kpi-card.red {{ border-left-color: {BTN_RED}; }}
.kpi-card.gold {{ border-left-color: {BTN_GOLD}; }}
.kpi-card.lightblue {{ border-left-color: {BTN_LIGHT_BLUE}; }}
.kpi-label {{ font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }}
.kpi-value {{ font-size: 26px; font-weight: 800; color: {BTN_DARK_BLUE}; margin: 4px 0; }}
.kpi-sub  {{ font-size: 11px; color: #888; }}
.section-title {{
    color: {BTN_DARK_BLUE}; font-weight: 800; font-size: 20px;
    border-bottom: 3px solid {BTN_BLUE}; padding-bottom: 6px; margin: 18px 0 12px 0;
}}
.sev-CRITICAL {{ color:{BTN_RED}; font-weight:700; }}
.sev-HIGH     {{ color:#FF7A00; font-weight:700; }}
.sev-MEDIUM   {{ color:{BTN_GOLD}; font-weight:700; }}
.sev-LOW      {{ color:{BTN_LIGHT_BLUE}; font-weight:700; }}
.findings-block {{
    background: white; padding: 14px 18px; border-radius: 10px;
    margin-bottom: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    border-left: 4px solid {BTN_BLUE};
}}
.recommendation-item {{
    background: white; padding: 12px 16px; border-radius: 8px;
    margin-bottom: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    border-left: 3px solid {BTN_GOLD};
}}
[data-testid="stSidebar"] [role="radiogroup"] label {{
    background: rgba(255,255,255,0.12); padding: 10px 14px; border-radius: 8px;
    margin-bottom: 6px; cursor: pointer; transition: background 0.2s;
    font-weight: 600; width: 100%;
}}
[data-testid="stSidebar"] [role="radiogroup"] label:hover {{ background: rgba(255,255,255,0.25); }}
[data-testid="stSidebar"] [role="radiogroup"] label:has(input:checked) {{
    background: white !important; border-left: 4px solid {BTN_RED};
}}
[data-testid="stSidebar"] [role="radiogroup"] label:has(input:checked) * {{ color: {BTN_DARK_BLUE} !important; }}
.stTabs [data-baseweb="tab-list"] button[aria-selected="true"] {{
    color: {BTN_DARK_BLUE}; border-bottom: 3px solid {BTN_RED};
}}
button[kind="primary"] {{
    background: {BTN_RED} !important; border: none !important;
    font-weight: 700 !important;
}}
</style>
""", unsafe_allow_html=True)

# -------------------------------------------------------------------
try:
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
    USING_SNOWPARK = True
except Exception:
    USING_SNOWPARK = False
    conn = st.connection("snowflake")

def run_query_nocache(sql: str) -> pd.DataFrame:
    if USING_SNOWPARK: return session.sql(sql).to_pandas()
    return conn.query(sql)

@st.cache_data(ttl=300)
def run_query(sql: str) -> pd.DataFrame:
    return run_query_nocache(sql)

def call_sp(sp_call: str):
    if USING_SNOWPARK:
        return session.sql(f"CALL {sp_call}").collect()[0][0]
    return conn.query(f"CALL {sp_call}").iloc[0,0]

DB = "BTN_COMPLIANCE_AI_DEMO"

# -------------------------------------------------------------------
# Sidebar
# -------------------------------------------------------------------
MENU_OPTIONS = [
    "📊 1. Summary",
    "🔐 2. UC1 - UU PDP",
    "📋 3. UC2 - Kebijakan Khusus",
    "🏛️ 4. UC3 - Peraturan BI",
    "⚖️ 5. UC4 - Kebijakan VS BI",
    "🔬 6. Adhoc Analytics",
]
with st.sidebar:
    st.markdown("# 🏦 BTN")
    st.markdown("### Compliance AI")
    st.markdown("Bank Tabungan Negara")
    st.markdown("---")
    st.markdown("### 📍 Navigasi")
    selected_menu = st.radio("Menu", MENU_OPTIONS, label_visibility="collapsed")
    st.markdown("---")
    st.markdown("**Powered by:** Snowflake Cortex AI")
    st.markdown("**Model:** `claude-opus-4-7`")
    st.markdown("**Database:** `BTN_COMPLIANCE_AI_DEMO`")

# Header
ch1, ch2 = st.columns([0.8, 0.2])
with ch1:
    st.markdown(f"<h1 style='color:{BTN_DARK_BLUE};margin-bottom:4px;'>🛡️ BTN Compliance AI Dashboard</h1>", unsafe_allow_html=True)
    st.markdown(f"<p style='color:#444;font-size:14px;'>Otomasi compliance analytics via Snowflake Cortex Claude Opus 4.7.</p>", unsafe_allow_html=True)
with ch2:
    st.markdown(f"<div style='text-align:right;'><span style='background:{BTN_RED};color:white;padding:6px 14px;border-radius:20px;font-weight:700;'>POC v2.0</span></div>", unsafe_allow_html=True)

# -------------------------------------------------------------------
# Data
# -------------------------------------------------------------------
@st.cache_data(ttl=600)
def load_all():
    return {
        "regs":  run_query_nocache(f"SELECT * FROM {DB}.COMPLIANCE_DOCS.REGULATIONS"),
        "cls":   run_query_nocache(f"SELECT * FROM {DB}.COMPLIANCE_RESULTS.AI_CLASSIFICATION"),
        "uc1":   run_query_nocache(f"SELECT * FROM {DB}.COMPLIANCE_RESULTS.GAP_ANALYSIS_UC1"),
        "tx":    run_query_nocache(f"SELECT * FROM {DB}.COMPLIANCE_RESULTS.GAP_ANALYSIS_TRANSACTIONS"),
        "uc4":   run_query_nocache(f"SELECT * FROM {DB}.COMPLIANCE_RESULTS.GAP_ANALYSIS_UC4"),
        "tables_summary": run_query_nocache(f"""
            SELECT TABLE_SCHEMA, TABLE_NAME, COUNT(*) AS N_COLS
            FROM {DB}.INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA IN ('CUSTOMER_DATA','TRANSACTION_DATA') GROUP BY 1,2 ORDER BY 1,2"""),
        "row_counts": run_query_nocache(f"""
            SELECT 'NASABAH' T, COUNT(*) C FROM {DB}.CUSTOMER_DATA.NASABAH
            UNION ALL SELECT 'REKENING', COUNT(*) FROM {DB}.CUSTOMER_DATA.REKENING
            UNION ALL SELECT 'KARTU_KREDIT', COUNT(*) FROM {DB}.CUSTOMER_DATA.KARTU_KREDIT
            UNION ALL SELECT 'LOAN_APPLICATION', COUNT(*) FROM {DB}.CUSTOMER_DATA.LOAN_APPLICATION
            UNION ALL SELECT 'TLHIST_TRANSAKSI', COUNT(*) FROM {DB}.TRANSACTION_DATA.TLHIST_TRANSAKSI
            UNION ALL SELECT 'GOAML_ODM_TRANSAKSI', COUNT(*) FROM {DB}.TRANSACTION_DATA.GOAML_ODM_TRANSAKSI
            UNION ALL SELECT 'RTGS_SKNBI_PAYMENT', COUNT(*) FROM {DB}.TRANSACTION_DATA.RTGS_SKNBI_PAYMENT"""),
    }

D = load_all()
df_regs, df_cls = D["regs"], D["cls"]
df_uc1, df_tx, df_uc4 = D["uc1"], D["tx"], D["uc4"]
df_tabs, df_rows = D["tables_summary"], D["row_counts"]
df_uc2 = df_tx[df_tx["REGULATION_SOURCE"] == "KEBIJAKAN_KHUSUS"]
df_uc3 = df_tx[df_tx["REGULATION_SOURCE"] == "BI_REGULATION"]

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
def kpi(label, value, sub="", color="blue"):
    st.markdown(f"""<div class='kpi-card {color}'>
      <div class='kpi-label'>{label}</div><div class='kpi-value'>{value}</div>
      <div class='kpi-sub'>{sub}</div></div>""", unsafe_allow_html=True)

def section(title):
    st.markdown(f"<div class='section-title'>{title}</div>", unsafe_allow_html=True)

def render_refresh_button(uc_label: str, sp_call: str):
    """Refresh button - calls stored procedure, then clears cache."""
    cc1, cc2, cc3 = st.columns([0.5, 0.25, 0.25])
    with cc3:
        if st.button(f"🔄 Refresh {uc_label}", key=f"refresh_{uc_label}", type="primary", use_container_width=True):
            with st.spinner(f"Menjalankan ulang AI gap analysis ({uc_label}) — claude-opus-4-7. Tunggu beberapa menit..."):
                try:
                    msg = call_sp(sp_call)
                    st.success(f"✅ {msg}")
                    st.cache_data.clear()
                    time.sleep(1.5)
                    st.rerun()
                except Exception as e:
                    st.error(f"Refresh gagal: {e}")

def severity_chart(df, col_name, title):
    sev_order = ["CRITICAL","HIGH","MEDIUM","LOW"]
    s = df.groupby(col_name).size().reset_index(name="N")
    return alt.Chart(s).mark_bar(cornerRadius=6).encode(
        x=alt.X(f"{col_name}:N", sort=sev_order, title="Severity"),
        y=alt.Y("N:Q", title="Count"),
        color=alt.Color(f"{col_name}:N",
            scale=alt.Scale(domain=sev_order, range=[BTN_RED,"#FF7A00",BTN_GOLD,BTN_LIGHT_BLUE]), legend=None),
        tooltip=[col_name,"N"]
    ).properties(height=240, title=title)

def render_violations_table(df_v, severity_col="FINDING_SEVERITY"):
    sev_order = ["CRITICAL","HIGH","MEDIUM","LOW"]
    for sev in sev_order:
        sub = df_v[df_v[severity_col] == sev]
        if len(sub) == 0: continue
        cls = f"sev-{sev}"
        st.markdown(f"<div class='findings-block'><span class='{cls}'>● {sev}</span> <b>({len(sub)} findings)</b></div>", unsafe_allow_html=True)
        cols_show = [c for c in ["TABLE_NAME","COLUMN_NAME","REG_ID","PASAL","REG_CATEGORY","VIOLATION_TYPE","FINDING","RECOMMENDATION"] if c in sub.columns]
        st.dataframe(
            sub[cols_show],
            use_container_width=True,
            hide_index=True,
            height=min(40+30*len(sub), 360),
            column_config={
                "FINDING": st.column_config.TextColumn("Finding", width="large"),
                "RECOMMENDATION": st.column_config.TextColumn("💡 Recommendation", width="large"),
            },
        )

# ===================================================================
# MENU 1: SUMMARY
# ===================================================================
if selected_menu == MENU_OPTIONS[0]:
    section("Executive Summary")
    total_tables    = len(df_tabs)
    total_columns   = int(df_tabs["N_COLS"].sum())
    total_rows      = int(df_rows["C"].sum())
    total_regs      = len(df_regs)

    c1,c2,c3,c4 = st.columns(4)
    with c1: kpi("Total Tabel", total_tables, "di 2 schema", "blue")
    with c2: kpi("Total Kolom", total_columns, "metadata yang dianalisa AI", "lightblue")
    with c3: kpi("Total Record", f"{total_rows:,}", "data sintesis & nasabah", "gold")
    with c4: kpi("Total Regulasi", total_regs, "diekstrak AI dari 6 dokumen", "red")
    st.write("")
    c1,c2,c3,c4 = st.columns(4)
    with c1: kpi("UC1 Violations", int(df_uc1["IS_VIOLATION"].sum()), "UU PDP vs nasabah", "red")
    with c2: kpi("UC2 Violations", int(df_uc2["IS_VIOLATION"].sum()), "Kebijakan vs transaksi", "red")
    with c3: kpi("UC3 Violations", int(df_uc3["IS_VIOLATION"].sum()), "BI vs transaksi", "red")
    with c4: kpi("UC4 Gaps", int((df_uc4["COVERAGE_QUALITY"] != "FULL").sum()), "BI rule belum di-cover", "red")

    st.write("")
    section("Komposisi Regulasi yang Diekstrak AI")
    a, b = st.columns([0.55, 0.45])
    with a:
        reg_src = df_regs.groupby("REGULATION_SOURCE").size().reset_index(name="N")
        reg_src["LABEL"] = reg_src["REGULATION_SOURCE"].replace({
            "UU_PDP":"UU Perlindungan Data","KEBIJAKAN_KHUSUS":"Kebijakan Khusus","BI_REGULATION":"Peraturan Bank Indonesia"})
        chart = alt.Chart(reg_src).mark_bar(cornerRadius=6).encode(
            x=alt.X("N:Q"), y=alt.Y("LABEL:N", sort="-x", title=""),
            color=alt.Color("REGULATION_SOURCE:N", scale=alt.Scale(
                domain=["UU_PDP","KEBIJAKAN_KHUSUS","BI_REGULATION"],
                range=[BTN_LIGHT_BLUE, BTN_GOLD, BTN_RED]), legend=None),
            tooltip=["LABEL","N"]).properties(height=180)
        st.altair_chart(chart, use_container_width=True)
    with b:
        cat = df_regs.groupby("CATEGORY").size().reset_index(name="N").sort_values("N", ascending=False).head(8)
        chart2 = alt.Chart(cat).mark_bar(cornerRadius=4, color=BTN_BLUE).encode(
            x="N:Q", y=alt.Y("CATEGORY:N", sort="-x")).properties(height=180)
        st.altair_chart(chart2, use_container_width=True)

    section("Klasifikasi Data oleh AI")
    a,b = st.columns(2)
    with a:
        cls_dist = df_cls.groupby("AI_CLASSIFICATION").size().reset_index(name="N")
        chart = alt.Chart(cls_dist).mark_arc(innerRadius=50).encode(
            theta="N:Q", color=alt.Color("AI_CLASSIFICATION:N", scale=alt.Scale(scheme="blues")),
            tooltip=["AI_CLASSIFICATION","N"]).properties(height=240, title="Distribusi Klasifikasi Kolom")
        st.altair_chart(chart, use_container_width=True)
    with b:
        st.altair_chart(severity_chart(df_cls, "AI_SENSITIVITY", "Sensitivity Distribution"), use_container_width=True)

    section("Tabel & Schema dalam Lingkup Audit")
    df_show = df_tabs.copy()
    df_show["ROWS"] = df_show["TABLE_NAME"].map(df_rows.set_index("T")["C"])
    df_show = df_show.rename(columns={"TABLE_SCHEMA":"Schema","TABLE_NAME":"Tabel","N_COLS":"Jumlah Kolom","ROWS":"Jumlah Record"})
    st.dataframe(df_show, use_container_width=True, hide_index=True)


# ===================================================================
# Generic UC renderer with tabs
# ===================================================================
def render_uc_tabs(df_full, uc_title, uc_subtitle, refresh_label, sp_call,
                   tables_in_scope, uc_focus_columns=None):
    section(uc_title)
    st.markdown(f"<p style='color:#555;'>{uc_subtitle}</p>", unsafe_allow_html=True)
    render_refresh_button(refresh_label, sp_call)
    st.caption(f"💡 Klik **Refresh {refresh_label}** untuk menjalankan ulang analisis AI (claude-opus-4-7). "
               "Gunakan setelah Anda mengubah data tabel atau kebijakan agar dashboard merefleksikan kondisi terbaru.")

    # KPIs
    df_v = df_full[df_full["IS_VIOLATION"]]
    n_total = len(df_full); n_viol = len(df_v)
    n_crit = int((df_v["FINDING_SEVERITY"] == "CRITICAL").sum())
    tables_aff = df_v["TABLE_NAME"].nunique()
    cols_aff = df_v[["TABLE_NAME","COLUMN_NAME"]].drop_duplicates().shape[0]
    score = (1 - n_viol/max(n_total,1))*100

    c1,c2,c3,c4,c5 = st.columns(5)
    with c1: kpi("Compliance Score", f"{score:.1f}%", "100% = full compliant", "blue")
    with c2: kpi("Total Pemeriksaan", n_total, "AI analysis pairs", "lightblue")
    with c3: kpi("Total Pelanggaran", n_viol, f"{(n_viol/max(n_total,1)*100):.1f}%", "red")
    with c4: kpi("Critical", n_crit, "perlu remediasi cepat", "red")
    with c5: kpi("Kolom Terdampak", cols_aff, "unique columns", "gold")

    # Tabs
    t1, t2, t3, t4, t5 = st.tabs([
        "📊 Overview", "📁 Per-Tabel", "📜 Per-Regulasi",
        "🤖 AI Classification", "💡 Recommendations",
    ])

    # --------- TAB OVERVIEW ---------
    with t1:
        if n_viol == 0:
            st.success("Tidak ada pelanggaran terdeteksi.")
        else:
            a,b = st.columns(2)
            with a:
                st.altair_chart(severity_chart(df_v, "FINDING_SEVERITY", "Pelanggaran per Severity"), use_container_width=True)
            with b:
                bt = df_v.groupby("TABLE_NAME").size().reset_index(name="N").sort_values("N")
                chart = alt.Chart(bt).mark_bar(cornerRadius=4, color=BTN_BLUE).encode(
                    x="N:Q", y=alt.Y("TABLE_NAME:N", sort="-x"),
                    tooltip=["TABLE_NAME","N"]).properties(height=240, title="Pelanggaran per Tabel")
                st.altair_chart(chart, use_container_width=True)
            a,b = st.columns(2)
            with a:
                vt = df_v.groupby("VIOLATION_TYPE").size().reset_index(name="N").sort_values("N")
                chart = alt.Chart(vt).mark_bar(cornerRadius=4, color=BTN_GOLD).encode(
                    x="N:Q", y=alt.Y("VIOLATION_TYPE:N", sort="-x"),
                    tooltip=["VIOLATION_TYPE","N"]).properties(height=260, title="Pelanggaran per Tipe")
                st.altair_chart(chart, use_container_width=True)
            with b:
                if "REG_CATEGORY" in df_v.columns:
                    cat = df_v.groupby("REG_CATEGORY").size().reset_index(name="N").sort_values("N")
                    chart = alt.Chart(cat).mark_bar(cornerRadius=4, color=BTN_LIGHT_BLUE).encode(
                        x="N:Q", y=alt.Y("REG_CATEGORY:N", sort="-x"),
                        tooltip=["REG_CATEGORY","N"]).properties(height=260, title="Pelanggaran per Kategori Regulasi")
                    st.altair_chart(chart, use_container_width=True)

    # --------- TAB PER-TABEL ---------
    with t2:
        st.markdown("**Pilih Tabel untuk melihat detail temuan:**")
        tables_avail = sorted(df_full["TABLE_NAME"].dropna().unique().tolist())
        sel_tbl = st.selectbox("Tabel:", tables_avail, key=f"tbl_{refresh_label}")
        df_t = df_full[df_full["TABLE_NAME"] == sel_tbl]
        df_tv = df_t[df_t["IS_VIOLATION"]]
        score_t = (1 - len(df_tv)/max(len(df_t),1))*100
        c1,c2,c3,c4,c5 = st.columns(5)
        with c1: kpi("Compliance Score", f"{score_t:.1f}%", sel_tbl, "blue")
        with c2: kpi("Total Checks", len(df_t), "", "lightblue")
        with c3: kpi("Violations", len(df_tv), "", "red")
        with c4: kpi("Critical", int((df_tv["FINDING_SEVERITY"]=='CRITICAL').sum()), "", "red")
        with c5: kpi("High", int((df_tv["FINDING_SEVERITY"]=='HIGH').sum()), "", "gold")
        st.markdown(f"### Detailed Findings - `{sel_tbl}`")
        if len(df_tv) == 0:
            st.success("Tabel ini compliant.")
        else:
            render_violations_table(df_tv)

    # --------- TAB PER-REGULASI ---------
    with t3:
        st.markdown("**Compliance per Regulasi**")
        per_reg = df_full.groupby(["REG_ID","REG_TITLE","REG_CATEGORY","REG_SEVERITY"]).agg(
            TOTAL_CHECKS=("IS_VIOLATION","size"),
            VIOLATION_COUNT=("IS_VIOLATION","sum")).reset_index()
        per_reg["COMPLIANT_COUNT"] = per_reg["TOTAL_CHECKS"] - per_reg["VIOLATION_COUNT"]
        per_reg["SCORE_PCT"] = (per_reg["COMPLIANT_COUNT"]/per_reg["TOTAL_CHECKS"]*100).round(1)
        per_reg = per_reg.sort_values("VIOLATION_COUNT", ascending=False)
        st.dataframe(per_reg.rename(columns={
            "REG_ID":"Reg ID","REG_TITLE":"Regulation Title","REG_CATEGORY":"Category",
            "REG_SEVERITY":"Severity","TOTAL_CHECKS":"Total Checks","VIOLATION_COUNT":"Violations",
            "COMPLIANT_COUNT":"Compliant","SCORE_PCT":"Score %"}),
            use_container_width=True, hide_index=True,
            column_config={"Score %": st.column_config.ProgressColumn(format="%.1f%%", min_value=0, max_value=100)})

        st.markdown("---")
        st.markdown("**Pilih Regulasi untuk Detail:**")
        if len(per_reg) > 0:
            opt = (per_reg["REG_ID"] + " — " + per_reg["REG_TITLE"]).tolist()
            sel = st.selectbox("Regulasi:", opt, key=f"reg_{refresh_label}")
            sel_id = sel.split(" — ")[0]
            r = df_regs[df_regs["REG_ID"] == sel_id]
            if not r.empty:
                rr = r.iloc[0]
                cA, cB = st.columns([0.35, 0.65])
                with cA:
                    st.markdown(f"<div class='findings-block'><span class='sev-{rr['SEVERITY']}'>{rr['SEVERITY']}</span><br><b>{rr['REGULATION_NAME']}</b><br>Pasal: <code>{rr['PASAL']}</code><br>Kategori: <code>{rr['CATEGORY']}</code></div>", unsafe_allow_html=True)
                with cB:
                    st.markdown(f"<div class='findings-block'><b>Isi Peraturan:</b><br><span style='color:#444'>{rr['CONTENT']}</span></div>", unsafe_allow_html=True)
            df_rv = df_full[(df_full["REG_ID"]==sel_id) & (df_full["IS_VIOLATION"])]
            st.markdown(f"### Violations - {sel_id}")
            cols_show = [c for c in ["TABLE_NAME","COLUMN_NAME","VIOLATION_TYPE","FINDING_SEVERITY","FINDING","RECOMMENDATION"] if c in df_rv.columns]
            st.dataframe(df_rv[cols_show], use_container_width=True, hide_index=True)

    # --------- TAB AI CLASSIFICATION ---------
    with t4:
        st.markdown(f"### 🤖 AI-Powered Data Classification")
        st.caption(f"Klasifikasi otomatis menggunakan **Snowflake Cortex** (`claude-opus-4-7`)")
        cls_subset = df_cls[df_cls["TABLE_NAME"].isin(tables_in_scope)]
        c1,c2,c3 = st.columns(3)
        with c1: kpi("Total Columns Scanned", len(cls_subset), "", "blue")
        with c2: kpi("Needs Masking", int(cls_subset["NEEDS_MASKING"].sum()), "", "red")
        with c3: kpi("Contains PII", int(cls_subset["CONTAINS_PII"].sum()), "", "gold")
        flt = st.selectbox("Filter by Table:", ["ALL"] + sorted(cls_subset["TABLE_NAME"].unique().tolist()), key=f"flt_{refresh_label}")
        d_show = cls_subset if flt == "ALL" else cls_subset[cls_subset["TABLE_NAME"]==flt]
        st.dataframe(d_show[["TABLE_NAME","COLUMN_NAME","DATA_TYPE","AI_CLASSIFICATION","AI_SENSITIVITY","NEEDS_MASKING","CONTAINS_PII","RISK_LEVEL","AI_REASON"]],
                     use_container_width=True, hide_index=True, height=350)
        a,b = st.columns(2)
        with a:
            cd = d_show.groupby("AI_CLASSIFICATION").size().reset_index(name="N")
            chart = alt.Chart(cd).mark_bar(color=BTN_BLUE, cornerRadius=4).encode(
                x=alt.X("AI_CLASSIFICATION:N", title="Classification"),
                y=alt.Y("N:Q", title="Count")).properties(height=300, title="Classification Distribution")
            st.altair_chart(chart, use_container_width=True)
        with b:
            st.altair_chart(severity_chart(d_show, "RISK_LEVEL", "Risk Level Distribution"), use_container_width=True)

    # --------- TAB RECOMMENDATIONS ---------
    with t5:
        st.markdown("### 💡 Recommendations")
        df_v = df_full[df_full["IS_VIOLATION"]]
        if len(df_v) == 0:
            st.success("Tidak ada rekomendasi karena tidak ada pelanggaran.")
        else:
            sev_filter = st.multiselect("Filter Severity:", ["CRITICAL","HIGH","MEDIUM","LOW"],
                                         default=["CRITICAL","HIGH"], key=f"sev_{refresh_label}")
            df_v = df_v[df_v["FINDING_SEVERITY"].isin(sev_filter)]
            for _, row in df_v.head(60).iterrows():
                col = row.get("COLUMN_NAME","")
                tbl = row.get("TABLE_NAME","")
                st.markdown(f"""<div class='recommendation-item'>
                <span class='sev-{row['FINDING_SEVERITY']}'>● {row['FINDING_SEVERITY']}</span>
                <b>[{row['REG_ID']}] {tbl}.{col}</b> — {row['REG_TITLE']}<br>
                <span style='color:#555;'>{row.get('RECOMMENDATION','')}</span></div>""",
                unsafe_allow_html=True)

# ===================================================================
# MENU 2: UC1 - UU PDP
# ===================================================================
if selected_menu == MENU_OPTIONS[1]:
    render_uc_tabs(
        df_uc1,
        "🔐 Use Case 1: UU Perlindungan Data Pribadi vs Data Nasabah",
        "AI memeriksa kolom PII (NIK, NPWP, nama, email, alamat, dll) di tabel customer terhadap UU Perlindungan Data Perbankan.",
        "UC1", "BTN_COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_REFRESH_UC1()",
        tables_in_scope=["NASABAH","REKENING","KARTU_KREDIT","LOAN_APPLICATION"],
    )
    section("Pelanggaran per Cabang BTN")
    cabang_q = run_query(f"""
      WITH base AS (
        SELECT 'NASABAH' T, CABANG, COUNT(*) C FROM {DB}.CUSTOMER_DATA.NASABAH GROUP BY CABANG
        UNION ALL SELECT 'REKENING', CABANG, COUNT(*) FROM {DB}.CUSTOMER_DATA.REKENING GROUP BY CABANG
        UNION ALL SELECT 'KARTU_KREDIT', CABANG, COUNT(*) FROM {DB}.CUSTOMER_DATA.KARTU_KREDIT GROUP BY CABANG
        UNION ALL SELECT 'LOAN_APPLICATION', CABANG, COUNT(*) FROM {DB}.CUSTOMER_DATA.LOAN_APPLICATION GROUP BY CABANG
      ) SELECT CABANG, SUM(C) AS RECORDS FROM base GROUP BY CABANG ORDER BY RECORDS DESC""")
    n_v_cols = df_uc1[df_uc1["IS_VIOLATION"]][["TABLE_NAME","COLUMN_NAME"]].drop_duplicates().shape[0]
    cabang_q["EST_AFFECTED_FIELDS"] = cabang_q["RECORDS"] * n_v_cols
    chart = alt.Chart(cabang_q).mark_bar(color=BTN_BLUE, cornerRadius=4).encode(
        x="EST_AFFECTED_FIELDS:Q", y=alt.Y("CABANG:N", sort="-x"),
        tooltip=["CABANG","RECORDS","EST_AFFECTED_FIELDS"]
    ).properties(height=300, title="Estimasi Field Sensitif Belum Sesuai per Cabang (records × kolom-violation)")
    st.altair_chart(chart, use_container_width=True)

# ===================================================================
# MENU 3: UC2
# ===================================================================
if selected_menu == MENU_OPTIONS[2]:
    render_uc_tabs(
        df_uc2,
        "📋 Use Case 2: Kebijakan Khusus Perusahaan vs Data Transaksi",
        "AI memeriksa apakah 3 tabel transaksi sudah comply dengan Kebijakan Khusus Bank BTN (SKNBI 2022 + Juklak BI-RTGS).",
        "UC2", "BTN_COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_REFRESH_TX_GAP('KEBIJAKAN_KHUSUS')",
        tables_in_scope=["TLHIST_TRANSAKSI","GOAML_ODM_TRANSAKSI","RTGS_SKNBI_PAYMENT"],
    )

# ===================================================================
# MENU 4: UC3
# ===================================================================
if selected_menu == MENU_OPTIONS[3]:
    render_uc_tabs(
        df_uc3,
        "🏛️ Use Case 3: Peraturan Bank Indonesia vs Data Transaksi",
        "AI memeriksa data 3 tabel transaksi terhadap PBI 6/8/2004, PBI 7/18/2005, PADG 08/2024.",
        "UC3", "BTN_COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_REFRESH_TX_GAP('BI_REGULATION')",
        tables_in_scope=["TLHIST_TRANSAKSI","GOAML_ODM_TRANSAKSI","RTGS_SKNBI_PAYMENT"],
    )

# ===================================================================
# MENU 5: UC4
# ===================================================================
if selected_menu == MENU_OPTIONS[4]:
    section("⚖️ Use Case 4: Kebijakan Khusus vs Peraturan Bank Indonesia")
    st.markdown("Audit AI mengevaluasi apakah Kebijakan Khusus Bank BTN sudah mencakup seluruh aturan Bank Indonesia.")
    render_refresh_button("UC4", "BTN_COMPLIANCE_AI_DEMO.COMPLIANCE_RESULTS.SP_REFRESH_UC4()")
    st.caption("💡 Klik **Refresh UC4** untuk re-run analisis cross-coverage dengan claude-opus-4-7.")

    n_total = len(df_uc4)
    n_full = int((df_uc4["COVERAGE_QUALITY"]=="FULL").sum())
    n_partial = int((df_uc4["COVERAGE_QUALITY"]=="PARTIAL").sum())
    n_none = int((df_uc4["COVERAGE_QUALITY"]=="NONE").sum())
    coverage_pct = (n_full + 0.5*n_partial)/max(n_total,1)*100

    c1,c2,c3,c4,c5 = st.columns(5)
    with c1: kpi("Total Aturan BI", n_total, "diperiksa AI", "blue")
    with c2: kpi("Full Coverage", n_full, "tercakup penuh", "lightblue")
    with c3: kpi("Partial", n_partial, "kurang lengkap", "gold")
    with c4: kpi("None", n_none, "tidak ada di kebijakan", "red")
    with c5: kpi("Coverage Score", f"{coverage_pct:.1f}%", "weighted (full=1, partial=0.5)", "blue")

    t1, t2, t3 = st.tabs(["📊 Overview","🔍 Detail Gap","💡 Rekomendasi"])
    with t1:
        a,b = st.columns(2)
        with a:
            cov = pd.DataFrame({"Coverage":["FULL","PARTIAL","NONE"], "N":[n_full, n_partial, n_none]})
            chart = alt.Chart(cov).mark_arc(innerRadius=60).encode(
                theta="N:Q", color=alt.Color("Coverage:N", scale=alt.Scale(
                    domain=["FULL","PARTIAL","NONE"], range=[BTN_LIGHT_BLUE, BTN_GOLD, BTN_RED])),
                tooltip=["Coverage","N"]).properties(height=280, title="Coverage Kebijakan Khusus terhadap BI")
            st.altair_chart(chart, use_container_width=True)
        with b:
            gap = df_uc4[df_uc4["COVERAGE_QUALITY"]!="FULL"].groupby("BI_CATEGORY").size().reset_index(name="N").sort_values("N")
            chart = alt.Chart(gap).mark_bar(color=BTN_RED, cornerRadius=4).encode(
                x="N:Q", y=alt.Y("BI_CATEGORY:N", sort="-x")).properties(height=280, title="Gap per Kategori Aturan BI")
            st.altair_chart(chart, use_container_width=True)

    with t2:
        df_gap = df_uc4[df_uc4["COVERAGE_QUALITY"]!="FULL"][["BI_REG_ID","BI_PASAL","BI_CATEGORY","BI_TITLE","BI_SEVERITY","COVERAGE_QUALITY","MATCHING_KEB_ID","GAP_FINDING","RECOMMENDATION"]]
        st.dataframe(df_gap, use_container_width=True, hide_index=True)

    with t3:
        sev_f = st.multiselect("Filter BI Severity:", ["CRITICAL","HIGH","MEDIUM","LOW"], default=["CRITICAL","HIGH"], key="uc4_sev")
        df_show = df_uc4[(df_uc4["COVERAGE_QUALITY"]!="FULL") & (df_uc4["BI_SEVERITY"].isin(sev_f))]
        for _, r in df_show.head(50).iterrows():
            st.markdown(f"""<div class='recommendation-item'>
            <span class='sev-{r['BI_SEVERITY']}'>● {r['BI_SEVERITY']}</span>
            <b>[{r['BI_REG_ID']}] Pasal {r['BI_PASAL']}</b> — {r['BI_TITLE']}<br>
            <i>Coverage: {r['COVERAGE_QUALITY']}</i> | Match: <code>{r['MATCHING_KEB_ID']}</code><br>
            <b>Gap:</b> {r['GAP_FINDING']}<br>
            <b>Rekomendasi:</b> <span style='color:#555;'>{r['RECOMMENDATION']}</span></div>""",
            unsafe_allow_html=True)

# ===================================================================
# MENU 6: ADHOC ANALYTICS
# ===================================================================
if selected_menu == MENU_OPTIONS[5]:
    section("🔬 Adhoc Compliance Analytics")
    st.markdown("Pilih tabel mana saja di account ini, pilih regulasi, lalu jalankan analisis AI compliance secara on-the-fly dengan **Snowflake Cortex (claude-opus-4-7)**.")

    REG_LABELS = {
        "UU_PDP": "UU Perlindungan Data Pribadi",
        "KEBIJAKAN_KHUSUS": "Kebijakan Khusus Perusahaan",
        "BI_REGULATION": "Peraturan Bank Indonesia",
    }

    @st.cache_data(ttl=600)
    def list_databases():
        try:
            df = run_query_nocache(
                "SELECT DATABASE_NAME FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES "
                "ORDER BY DATABASE_NAME")
            return df["DATABASE_NAME"].dropna().astype(str).tolist()
        except Exception:
            df = run_query_nocache("SHOW DATABASES")
            cols = list(df.columns)
            name_col = next((c for c in cols if str(c).strip('"').lower() == "name"), cols[1] if len(cols) > 1 else cols[0])
            return sorted(df[name_col].dropna().astype(str).tolist())

    @st.cache_data(ttl=300)
    def list_schemas(db):
        try:
            df = run_query_nocache(
                f'SELECT SCHEMA_NAME FROM "{db}".INFORMATION_SCHEMA.SCHEMATA '
                f"WHERE SCHEMA_NAME NOT IN ('INFORMATION_SCHEMA') ORDER BY SCHEMA_NAME")
            return df["SCHEMA_NAME"].tolist()
        except Exception:
            return []

    @st.cache_data(ttl=300)
    def list_tables(db, sch):
        try:
            df = run_query_nocache(
                f'SELECT TABLE_NAME, TABLE_TYPE, ROW_COUNT FROM "{db}".INFORMATION_SCHEMA.TABLES '
                f"WHERE TABLE_SCHEMA='{sch}' ORDER BY TABLE_NAME")
            return df
        except Exception:
            return pd.DataFrame(columns=["TABLE_NAME","TABLE_TYPE","ROW_COUNT"])

    @st.cache_data(ttl=300)
    def get_columns(db, sch, tbl):
        try:
            df = run_query_nocache(
                f'SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COMMENT '
                f'FROM "{db}".INFORMATION_SCHEMA.COLUMNS '
                f"WHERE TABLE_SCHEMA='{sch}' AND TABLE_NAME='{tbl}' ORDER BY ORDINAL_POSITION")
            return df
        except Exception:
            return pd.DataFrame(columns=["COLUMN_NAME","DATA_TYPE","IS_NULLABLE","COMMENT"])

    # ---- Step 1: Pick table ----
    st.markdown("### Step 1 — Pilih Tabel")
    cdb, csc, ctb = st.columns(3)
    with cdb:
        dbs = list_databases()
        sel_db = st.selectbox("Database:", dbs,
                              index=(dbs.index(DB) if DB in dbs else 0),
                              key="adhoc_db")
    with csc:
        schemas = list_schemas(sel_db)
        sel_sc = st.selectbox("Schema:", schemas, key="adhoc_sc") if schemas else None
    with ctb:
        df_tabs_adh = list_tables(sel_db, sel_sc) if sel_sc else pd.DataFrame()
        if not df_tabs_adh.empty:
            sel_tb = st.selectbox("Table:", df_tabs_adh["TABLE_NAME"].tolist(), key="adhoc_tb")
        else:
            sel_tb = None
            st.info("Tidak ada tabel di schema ini.")

    if not (sel_db and sel_sc and sel_tb):
        st.stop()

    fqn = f'"{sel_db}"."{sel_sc}"."{sel_tb}"'
    df_cols_adh = get_columns(sel_db, sel_sc, sel_tb)

    # Preview
    a, b = st.columns([0.55, 0.45])
    with a:
        st.markdown(f"**Tabel terpilih:** `{fqn}`")
        st.caption(f"{len(df_cols_adh)} kolom")
        st.dataframe(df_cols_adh, use_container_width=True, hide_index=True, height=240)
    with b:
        try:
            sample = run_query_nocache(f"SELECT * FROM {fqn} LIMIT 5")
            st.markdown("**Sample 5 baris:**")
            st.dataframe(sample, use_container_width=True, hide_index=True, height=240)
        except Exception as e:
            st.warning(f"Tidak bisa preview data: {e}")

    # ---- Step 2: Pick regulation ----
    st.markdown("### Step 2 — Pilih Regulasi")
    sel_reg = st.radio("Regulation Source:",
                       options=list(REG_LABELS.keys()),
                       format_func=lambda x: f"{x} — {REG_LABELS[x]}",
                       horizontal=True, key="adhoc_reg")
    n_rules = int(df_regs[df_regs["REGULATION_SOURCE"] == sel_reg].shape[0])
    st.caption(f"{n_rules} aturan akan diuji terhadap tabel ini.")

    # ---- Step 3: Analyze ----
    st.markdown("### Step 3 — Jalankan Analisis")
    cb1, cb2, cb3 = st.columns([0.6, 0.2, 0.2])
    with cb3:
        run_now = st.button("🔬 Analisa Sekarang", key="adhoc_run", type="primary", use_container_width=True)

    if not run_now:
        st.info("Klik **Analisa Sekarang** untuk menjalankan AI gap analysis (claude-opus-4-7).")
        st.stop()

    # Build column descriptor
    col_desc = "\n".join([
        f"- {r['COLUMN_NAME']} ({r['DATA_TYPE']})" + (f" — {r['COMMENT']}" if r.get('COMMENT') else "")
        for _, r in df_cols_adh.iterrows()
    ])

    # Pull rules for selected regulation
    df_rules = df_regs[df_regs["REGULATION_SOURCE"] == sel_reg][
        ["REG_ID","PASAL","CATEGORY","REGULATION_NAME","SEVERITY","CONTENT"]
    ].copy()
    rule_text = "\n".join([
        f"[{r['REG_ID']}] Pasal {r['PASAL']} | {r['CATEGORY']} | Severity={r['SEVERITY']} | "
        f"{r['REGULATION_NAME']}: {r['CONTENT']}"
        for _, r in df_rules.iterrows()
    ])

    prompt = f"""You are a senior banking compliance auditor. Analyze the table schema below for compliance with the listed regulations.

TABLE: {fqn}
COLUMNS:
{col_desc}

REGULATIONS ({sel_reg} - {REG_LABELS[sel_reg]}):
{rule_text}

Return ONLY a JSON array of the TOP 25 most material findings (no prose, no markdown fence) with this schema:
[{{
  "column_name": "<column>",
  "reg_id": "<REG_ID from the list>",
  "pasal": "<PASAL>",
  "reg_category": "<CATEGORY>",
  "regulation_title": "<REGULATION_NAME>",
  "is_violation": true|false,
  "severity": "CRITICAL|HIGH|MEDIUM|LOW",
  "violation_type": "<short label, e.g. ENCRYPTION_MISSING, RETENTION_UNDEFINED>",
  "finding": "<one sentence finding in plain English>",
  "recommendation": "<one sentence concrete remediation action>"
}}]

Be strict. Mark is_violation=true when the column likely violates the rule given typical bank schemas (plain-text PII, missing masking, no encryption hint, sensitive identifiers without retention). Keep each finding/recommendation under 30 words.
"""

    # Escape for SQL string
    safe_prompt = prompt.replace("\\", "\\\\").replace("'", "''")

    sql = f"""
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
      'claude-opus-4-7',
      ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('role','user','content','{safe_prompt}')),
      OBJECT_CONSTRUCT('max_tokens', 8000, 'temperature', 0)
    ) AS RESULT
    """

    with st.spinner("⏳ Menjalankan AI gap analysis dengan claude-opus-4-7 …"):
        try:
            res = run_query_nocache(sql)
        except Exception as e:
            st.error(f"AI call gagal: {e}")
            st.stop()

    raw = res.iloc[0, 0]
    if raw is None or str(raw).strip() == "":
        st.error("Model tidak mengembalikan response. Coba ulangi.")
        st.stop()

    import json, re
    txt = str(raw).strip()
    # When using ARRAY_CONSTRUCT/OBJECT_CONSTRUCT form, response is a JSON object
    try:
        outer = json.loads(txt)
        if isinstance(outer, dict) and "choices" in outer:
            txt = outer["choices"][0].get("messages") or outer["choices"][0].get("message", {}).get("content", "")
    except Exception:
        pass
    txt = str(txt).strip()
    # strip ```json ... ``` fences if present
    txt = re.sub(r"^```(?:json)?\s*", "", txt)
    txt = re.sub(r"\s*```\s*$", "", txt)
    # find first JSON array if model added prose
    m = re.search(r"\[.*\]", txt, re.DOTALL)
    if m:
        txt = m.group(0)

    try:
        data = json.loads(txt)
        df_find = pd.DataFrame(data)
    except Exception as e:
        st.error(f"Gagal parse hasil AI: {e}")
        st.code(str(raw)[:2000])
        st.stop()

    if df_find.empty:
        st.success("🎉 AI tidak menemukan pelanggaran. Tabel ini compliant terhadap regulasi yang dipilih.")
        st.stop()

    # Normalize columns
    df_find["IS_VIOLATION"]    = df_find.get("is_violation", True).astype(bool)
    df_find["FINDING_SEVERITY"] = df_find.get("severity", "MEDIUM").astype(str).str.upper()
    df_find["VIOLATION_TYPE"]   = df_find.get("violation_type", "")
    df_find["FINDING"]          = df_find.get("finding", "")
    df_find["RECOMMENDATION"]   = df_find.get("recommendation", "")
    df_find["REG_ID"]           = df_find.get("reg_id", "")
    df_find["PASAL"]            = df_find.get("pasal", "")
    df_find["REG_CATEGORY"]     = df_find.get("reg_category", "")
    df_find["REG_TITLE"]        = df_find.get("regulation_title", "")
    df_find["COLUMN_NAME"]      = df_find.get("column_name", "")
    df_find["TABLE_NAME"]       = sel_tb
    df_find["DATABASE_NAME"]    = sel_db
    df_find["SCHEMA_NAME"]      = sel_sc
    df_find["REG_SOURCE"]       = sel_reg
    df_find["ANALYZED_AT"]      = pd.Timestamp.now()

    # ---- Persist to temp table in Snowflake ----
    persist_cols = ["DATABASE_NAME","SCHEMA_NAME","TABLE_NAME","COLUMN_NAME","REG_SOURCE",
                    "REG_ID","PASAL","REG_CATEGORY","REG_TITLE","IS_VIOLATION",
                    "FINDING_SEVERITY","VIOLATION_TYPE","FINDING","RECOMMENDATION","ANALYZED_AT"]
    df_persist = df_find[persist_cols].copy()
    try:
        if USING_SNOWPARK:
            session.sql(f"""CREATE TABLE IF NOT EXISTS {DB}.COMPLIANCE_RESULTS.ADHOC_FINDINGS (
                DATABASE_NAME STRING, SCHEMA_NAME STRING, TABLE_NAME STRING, COLUMN_NAME STRING,
                REG_SOURCE STRING, REG_ID STRING, PASAL STRING, REG_CATEGORY STRING, REG_TITLE STRING,
                IS_VIOLATION BOOLEAN, FINDING_SEVERITY STRING, VIOLATION_TYPE STRING,
                FINDING STRING, RECOMMENDATION STRING, ANALYZED_AT TIMESTAMP_NTZ)""").collect()
            session.sql(f"DELETE FROM {DB}.COMPLIANCE_RESULTS.ADHOC_FINDINGS "
                        f"WHERE DATABASE_NAME='{sel_db}' AND SCHEMA_NAME='{sel_sc}' "
                        f"AND TABLE_NAME='{sel_tb}' AND REG_SOURCE='{sel_reg}'").collect()
            session.write_pandas(df_persist, "ADHOC_FINDINGS",
                                 database=DB, schema="COMPLIANCE_RESULTS", auto_create_table=False)
            persisted = True
        else:
            persisted = False
    except Exception as e:
        st.caption(f"⚠️ Tidak bisa persist ke table (continuing): {e}")
        persisted = False

    n_total  = len(df_find)
    df_v     = df_find[df_find["IS_VIOLATION"]].copy()
    n_viol   = len(df_v)
    n_crit   = int((df_v["FINDING_SEVERITY"] == "CRITICAL").sum())
    n_high   = int((df_v["FINDING_SEVERITY"] == "HIGH").sum())
    n_med    = int((df_v["FINDING_SEVERITY"] == "MEDIUM").sum())
    n_low    = int((df_v["FINDING_SEVERITY"] == "LOW").sum())
    cols_aff = df_v["COLUMN_NAME"].nunique()
    score    = (1 - n_viol / max(n_total, 1)) * 100

    # ----------- MANAGER VIEW -----------
    if persisted:
        st.success(f"✅ Analisis selesai. Hasil disimpan di `{DB}.COMPLIANCE_RESULTS.ADHOC_FINDINGS`.")

    # Hero score banner
    if score >= 80:
        sc_color = "#1B9E4B"; sc_label = "GOOD"
    elif score >= 50:
        sc_color = BTN_GOLD; sc_label = "NEEDS ATTENTION"
    else:
        sc_color = BTN_RED; sc_label = "CRITICAL"

    st.markdown(f"""
    <div style='background:linear-gradient(90deg,{BTN_DARK_BLUE} 0%,{BTN_BLUE} 100%);
                padding:24px 32px;border-radius:14px;color:white;margin:18px 0;'>
      <div style='display:flex;justify-content:space-between;align-items:center;'>
        <div>
          <div style='font-size:13px;opacity:.85;letter-spacing:1px;'>COMPLIANCE SCORE — {REG_LABELS[sel_reg]}</div>
          <div style='font-size:14px;opacity:.7;margin-top:2px;'>{fqn}</div>
        </div>
        <div style='text-align:right;'>
          <div style='font-size:54px;font-weight:800;line-height:1;'>{score:.0f}<span style='font-size:24px;'>%</span></div>
          <div style='background:{sc_color};display:inline-block;padding:4px 12px;border-radius:14px;
                      font-size:12px;font-weight:700;margin-top:6px;'>{sc_label}</div>
        </div>
      </div>
    </div>
    """, unsafe_allow_html=True)

    # KPI tiles
    c1, c2, c3, c4, c5 = st.columns(5)
    with c1: kpi("Total Findings", n_total, "AI analysis", "blue")
    with c2: kpi("Violations", n_viol, f"{(n_viol/max(n_total,1)*100):.0f}% dari total", "red")
    with c3: kpi("Critical", n_crit, "remediasi segera", "red")
    with c4: kpi("High", n_high, "prioritas tinggi", "gold")
    with c5: kpi("Kolom Terdampak", cols_aff, "unique columns", "lightblue")

    # Tabs (manager-friendly, no raw JSON)
    t1, t2, t3, t4 = st.tabs([
        "📊 Executive Overview", "🚨 Violations Detail",
        "💡 Recommended Actions", "📋 Findings Table",
    ])

    # ---- TAB 1: Executive Overview ----
    with t1:
        if n_viol == 0:
            st.success("Tidak ada pelanggaran terdeteksi.")
        else:
            a, b = st.columns(2)
            with a:
                st.altair_chart(severity_chart(df_v, "FINDING_SEVERITY",
                                "Distribusi Severity"), use_container_width=True)
            with b:
                vt = df_v.groupby("VIOLATION_TYPE").size().reset_index(name="N").sort_values("N")
                chart = alt.Chart(vt).mark_bar(cornerRadius=4, color=BTN_GOLD).encode(
                    x="N:Q", y=alt.Y("VIOLATION_TYPE:N", sort="-x"),
                    tooltip=["VIOLATION_TYPE","N"]
                ).properties(height=260, title="Tipe Pelanggaran")
                st.altair_chart(chart, use_container_width=True)

            st.markdown("#### Pelanggaran per Regulasi")
            per_reg = df_v.groupby(["REG_ID","REG_TITLE","REG_CATEGORY"]).agg(
                VIOLATIONS=("IS_VIOLATION","size"),
                CRITICAL=("FINDING_SEVERITY", lambda s: (s=="CRITICAL").sum()),
                HIGH=("FINDING_SEVERITY", lambda s: (s=="HIGH").sum()),
            ).reset_index().sort_values("VIOLATIONS", ascending=False)
            st.dataframe(per_reg.rename(columns={
                "REG_ID":"Reg ID","REG_TITLE":"Regulation","REG_CATEGORY":"Category",
                "VIOLATIONS":"Total","CRITICAL":"Critical","HIGH":"High"}),
                use_container_width=True, hide_index=True)

    # ---- TAB 2: Violations Detail (severity-grouped cards) ----
    with t2:
        if n_viol == 0:
            st.success("Tidak ada pelanggaran.")
        else:
            sev_palette = {"CRITICAL": BTN_RED, "HIGH": "#FF7A00", "MEDIUM": BTN_GOLD, "LOW": BTN_LIGHT_BLUE}
            for sev in ["CRITICAL","HIGH","MEDIUM","LOW"]:
                sub = df_v[df_v["FINDING_SEVERITY"] == sev]
                if sub.empty: continue
                st.markdown(
                    f"<h4 style='color:{sev_palette[sev]};margin-top:18px;'>"
                    f"● {sev} <span style='color:#666;font-weight:400;font-size:14px;'>"
                    f"({len(sub)} findings)</span></h4>", unsafe_allow_html=True)
                for _, row in sub.iterrows():
                    st.markdown(f"""
                    <div style='background:white;border-left:5px solid {sev_palette[sev]};
                                padding:14px 18px;border-radius:8px;margin-bottom:10px;
                                box-shadow:0 1px 4px rgba(0,0,0,0.06);'>
                      <div style='display:flex;justify-content:space-between;align-items:flex-start;'>
                        <div>
                          <span style='background:{BTN_DARK_BLUE};color:white;padding:2px 8px;
                                       border-radius:10px;font-size:11px;font-weight:700;'>{row['REG_ID']}</span>
                          <span style='color:#888;font-size:12px;margin-left:6px;'>Pasal {row['PASAL']} • {row['REG_CATEGORY']}</span>
                          <div style='font-weight:700;color:{BTN_DARK_BLUE};margin-top:4px;font-size:15px;'>
                            {row['TABLE_NAME']}.<span style='color:{BTN_BLUE};'>{row['COLUMN_NAME']}</span>
                          </div>
                          <div style='color:#666;font-size:12px;font-style:italic;'>{row['REG_TITLE']}</div>
                        </div>
                        <span style='background:{sev_palette[sev]};color:white;padding:3px 10px;
                                     border-radius:10px;font-size:11px;font-weight:700;'>{row['VIOLATION_TYPE']}</span>
                      </div>
                      <div style='margin-top:10px;color:#333;'><b>Finding:</b> {row['FINDING']}</div>
                      <div style='margin-top:6px;color:#1B9E4B;'><b>✓ Recommendation:</b> {row['RECOMMENDATION']}</div>
                    </div>""", unsafe_allow_html=True)

    # ---- TAB 3: Recommended Actions ----
    with t3:
        if n_viol == 0:
            st.success("Tidak ada rekomendasi.")
        else:
            st.markdown("**Top Priority Actions** — disusun berdasarkan severity.")
            ranked = df_v.copy()
            sev_rank = {"CRITICAL":0,"HIGH":1,"MEDIUM":2,"LOW":3}
            ranked["RNK"] = ranked["FINDING_SEVERITY"].map(sev_rank)
            ranked = ranked.sort_values(["RNK","REG_ID"]).head(15)
            for i, (_, row) in enumerate(ranked.iterrows(), 1):
                sev_palette = {"CRITICAL": BTN_RED, "HIGH": "#FF7A00", "MEDIUM": BTN_GOLD, "LOW": BTN_LIGHT_BLUE}
                clr = sev_palette.get(row["FINDING_SEVERITY"], BTN_BLUE)
                st.markdown(f"""
                <div style='background:white;padding:14px 18px;border-radius:8px;
                            margin-bottom:8px;display:flex;align-items:flex-start;gap:14px;
                            box-shadow:0 1px 4px rgba(0,0,0,0.06);'>
                  <div style='background:{clr};color:white;font-weight:800;font-size:16px;
                              width:34px;height:34px;border-radius:50%;display:flex;
                              align-items:center;justify-content:center;flex-shrink:0;'>{i}</div>
                  <div style='flex:1;'>
                    <div style='font-weight:700;color:{BTN_DARK_BLUE};'>
                      {row['TABLE_NAME']}.{row['COLUMN_NAME']}
                      <span style='color:{clr};font-size:12px;margin-left:8px;'>● {row['FINDING_SEVERITY']}</span>
                      <span style='color:#888;font-size:12px;'> • {row['REG_ID']}</span>
                    </div>
                    <div style='color:#333;margin-top:4px;'>{row['RECOMMENDATION']}</div>
                  </div>
                </div>""", unsafe_allow_html=True)

    # ---- TAB 4: Findings Table ----
    with t4:
        st.markdown("Hasil lengkap (juga tersedia di table `COMPLIANCE_RESULTS.ADHOC_FINDINGS`).")
        show_cols = ["TABLE_NAME","COLUMN_NAME","REG_ID","PASAL","REG_CATEGORY",
                     "FINDING_SEVERITY","VIOLATION_TYPE","FINDING","RECOMMENDATION"]
        st.dataframe(df_find[show_cols], use_container_width=True, hide_index=True, height=420)
        st.download_button("⬇️ Download CSV",
                           df_find[show_cols].to_csv(index=False).encode("utf-8"),
                           file_name=f"adhoc_{sel_tb}_{sel_reg}.csv",
                           mime="text/csv")


# Footer
st.markdown("---")
st.markdown(f"<p style='text-align:center;color:#888;font-size:12px;'>BTN Compliance AI POC v2.0 • Snowflake Cortex (claude-opus-4-7) • {pd.Timestamp.now().strftime('%Y-%m-%d')}</p>", unsafe_allow_html=True)
