import re, sys, glob, os
BIG = {'time_event','telephony_call','telephony_call_tag','crm_call','crm_record','crm_contact','crm_task','email_message','ingest_event','audit_log','call_link','message','message_delivery','form_submission','crm_association','workday','roster_entry'}
rows_out = []
for path in sorted(glob.glob('/home/user/cma/local-records/5.3-database/plans/*.txt')):
    name = os.path.basename(path)[:-4]
    txt = open(path, errors='replace').read()
    # the measured pass is everything after the second "-- measured pass" marker is not echoed; split on the second BEGIN
    parts = txt.split('\nBEGIN\n')
    measured = parts[-1] if len(parts) >= 3 else txt
    # top-level statements are logged with "Query Text: select ..." at depth 0: take the LOG block whose Query Text starts with our select (not a nested plpgsql statement)
    blocks = re.split(r'\n(?=psql:\S+ LOG:  duration: )', measured)
    top = None; nested = []
    for b in blocks:
        m = re.match(r'psql:\S+ LOG:  duration: ([0-9.]+) ms  plan:\nQuery Text: (.*)', b, re.S)
        if not m: continue
        dur = float(m.group(1)); qt = m.group(2).split('\n',1)[0].strip()
        if qt.lower().startswith('select') and ('cma.' in qt) and ('set_config' not in qt) and (top is None or dur > top[0]):
            # candidate top-level: the one that is our page call (largest duration among top-level selects)
            top = (dur, qt, b)
        else:
            nested.append((dur, qt, b))
    rowsm = re.findall(r'^\((\d+) rows?\)', measured, re.M)
    rows = rowsm[-1] if rowsm else '?'
    buf = ''
    seqs = []
    if top:
        bm = re.search(r'^  Buffers: (shared[^\n]*)', top[2], re.M)
        buf = bm.group(1) if bm else ''
    # big-table seq scans and their actual rows, anywhere in the measured pass
    for sm in re.finditer(r'Seq Scan on (?:cma\.)?([a-z_]+)[^\n]*\(actual time=([0-9.]+)\.\.([0-9.]+) rows=(\d+) loops=(\d+)\)', measured):
        t = sm.group(1)
        if t in BIG:
            seqs.append(f"{t}:rows={sm.group(4)}x{sm.group(5)}")
    # heaviest nested statement
    heavy = max(nested, key=lambda x: x[0]) if nested else None
    rows_out.append((name, top[0] if top else None, rows, buf, ','.join(sorted(set(seqs)))[:160], (f"{heavy[0]:.1f}ms: {heavy[1][:90]}" if heavy else '')))
with open('/home/user/cma/local-records/5.3-database/plans-summary.txt', 'w') as f:
    f.write("function\ttop_ms\trows\tbuffers\tbig_table_seq_scans\theaviest_nested\n")
    for r in rows_out:
        f.write("\t".join([r[0], f"{r[1]:.1f}" if r[1] is not None else '?', str(r[2]), r[3], r[4], r[5]]) + "\n")
for r in sorted(rows_out, key=lambda x: -(x[1] or 0)):
    print(f"{r[0]:<26} {('%.1f' % r[1]) if r[1] is not None else '?':>9} ms  rows={r[2]:<6} {r[3][:60]:<60} seq={r[4][:90]}")
