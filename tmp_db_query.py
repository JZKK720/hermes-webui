import sqlite3, json, os
conn = sqlite3.connect('/home/hermeswebui/.hermes/state.db')
conn.row_factory = sqlite3.Row
cur = conn.cursor()

# The id column is likely the session identifier
cur.execute("SELECT id, title, model, started_at, ended_at, message_count, handoff_state FROM sessions ORDER BY started_at DESC LIMIT 10")
rows = cur.fetchall()
print("Recent sessions (last 10):")
for r in rows:
    print(f"  id={r['id']} title={r['title']!r} model={r['model']} started={r['started_at']} ended={r['ended_at']} msgs={r['message_count']} handoff={r['handoff_state']}")

# Also try to match 1914fc8dd5b0
cur.execute("SELECT id, title FROM sessions WHERE id LIKE '%1914fc8dd5b0%' OR id='1914fc8dd5b0'")
match = cur.fetchall()
print("\nDirect ID match:", [(r['id'], r['title']) for r in match])

# Check the webui directory
webui_dir = '/home/hermeswebui/.hermes/webui'
if os.path.exists(webui_dir):
    print("\nWebUI dir contents:", os.listdir(webui_dir))
    for f in os.listdir(webui_dir):
        fp = os.path.join(webui_dir, f)
        if f.endswith('.db'):
            try:
                wconn = sqlite3.connect(fp)
                wcur = wconn.cursor()
                wcur.execute("SELECT name FROM sqlite_master WHERE type='table'")
                tables = [r[0] for r in wcur.fetchall()]
                print(f"  {f} tables: {tables}")
                wconn.close()
            except Exception as e:
                print(f"  {f} error: {e}")

conn.close()
