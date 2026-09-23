CREATE TABLE IF NOT EXISTS relay_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL,epoch TEXT NOT NULL,sequence INTEGER NOT NULL,pruned_through INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY,source TEXT UNIQUE NOT NULL,source_row INTEGER NOT NULL,route TEXT NOT NULL,service TEXT NOT NULL,content TEXT NOT NULL,record TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS participants(conversation_id TEXT NOT NULL REFERENCES conversations(id),address TEXT NOT NULL,PRIMARY KEY(conversation_id,address));
CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,source TEXT UNIQUE NOT NULL,source_row INTEGER NOT NULL,conversation_id TEXT NOT NULL REFERENCES conversations(id),date_ns INTEGER NOT NULL,direction TEXT NOT NULL,text TEXT NOT NULL,status TEXT NOT NULL,content TEXT NOT NULL,record TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS message_history ON messages(conversation_id,date_ns DESC,id DESC);
CREATE INDEX IF NOT EXISTS message_source_row ON messages(source_row);
CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY,type TEXT NOT NULL,record TEXT NOT NULL,origin TEXT NOT NULL,created_ms INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS send_requests(id TEXT PRIMARY KEY,epoch TEXT NOT NULL,payload TEXT NOT NULL,record TEXT NOT NULL,state TEXT NOT NULL,mode TEXT NOT NULL,route TEXT NOT NULL,accepted_ms INTEGER NOT NULL,dispatch_ms INTEGER,source_floor INTEGER,message_id TEXT);
CREATE INDEX IF NOT EXISTS request_state ON send_requests(state);
CREATE TABLE IF NOT EXISTS ingestion_progress(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS pending_source(source_row INTEGER PRIMARY KEY,attempt_ms INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS reconcile_chats(conversation_id TEXT PRIMARY KEY,after_row INTEGER NOT NULL DEFAULT 0);

CREATE TABLE IF NOT EXISTS send_observations(request_id TEXT PRIMARY KEY REFERENCES send_requests(id),attempt_ms INTEGER NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS request_message ON send_requests(message_id) WHERE message_id IS NOT NULL;
