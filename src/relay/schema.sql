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

-- Enrichment migrations are additive: epoch and send identities are retained.
CREATE TABLE IF NOT EXISTS identities(id TEXT PRIMARY KEY,service TEXT NOT NULL,address TEXT NOT NULL,content TEXT NOT NULL,record TEXT NOT NULL,UNIQUE(service,address));
CREATE TABLE IF NOT EXISTS contact_mappings(identity_id TEXT PRIMARY KEY REFERENCES identities(id),contact_id TEXT,source_version TEXT NOT NULL,normalization_version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS identity_work(identity_id TEXT PRIMARY KEY REFERENCES identities(id),generation INTEGER NOT NULL DEFAULT 1,attempt_ms INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS enrichment_sections(message_id TEXT NOT NULL REFERENCES messages(id),section TEXT NOT NULL,content TEXT NOT NULL,PRIMARY KEY(message_id,section));
CREATE TABLE IF NOT EXISTS enrichment_items(message_id TEXT NOT NULL REFERENCES messages(id),section TEXT NOT NULL,position INTEGER NOT NULL,record TEXT NOT NULL,PRIMARY KEY(message_id,section,position));
CREATE TABLE IF NOT EXISTS asset_sources(id TEXT PRIMARY KEY,kind TEXT NOT NULL,source_key TEXT NOT NULL,path TEXT NOT NULL,version TEXT NOT NULL,fingerprint TEXT NOT NULL DEFAULT '',check_ms INTEGER NOT NULL DEFAULT 0,attempts INTEGER NOT NULL DEFAULT 0,UNIQUE(kind,source_key));
CREATE TABLE IF NOT EXISTS asset_representations(asset_id TEXT NOT NULL REFERENCES asset_sources(id),version TEXT NOT NULL,variant TEXT NOT NULL,record TEXT NOT NULL,etag TEXT,file_name TEXT,bytes INTEGER NOT NULL DEFAULT 0,last_access_ms INTEGER NOT NULL DEFAULT 0,requested INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(asset_id,version,variant));
CREATE TABLE IF NOT EXISTS asset_owners(asset_id TEXT NOT NULL REFERENCES asset_sources(id),kind TEXT NOT NULL,owner_id TEXT NOT NULL,PRIMARY KEY(asset_id,kind,owner_id));
CREATE INDEX IF NOT EXISTS asset_owner_lookup ON asset_owners(kind,owner_id);
CREATE TABLE IF NOT EXISTS asset_work(asset_id TEXT NOT NULL REFERENCES asset_sources(id),version TEXT NOT NULL,variant TEXT NOT NULL,attempt_ms INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(asset_id,version,variant));
CREATE TABLE IF NOT EXISTS asset_blobs(asset_id TEXT PRIMARY KEY REFERENCES asset_sources(id),bytes BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS reaction_sources(source TEXT PRIMARY KEY,source_row INTEGER NOT NULL,conversation_id TEXT NOT NULL REFERENCES conversations(id),target_guid TEXT,date_ns INTEGER NOT NULL,observation TEXT NOT NULL,retired INTEGER NOT NULL DEFAULT 0,check_ms INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS reaction_target ON reaction_sources(conversation_id,target_guid);
CREATE INDEX IF NOT EXISTS reaction_check ON reaction_sources(retired,check_ms);
CREATE TABLE IF NOT EXISTS reaction_work(conversation_id TEXT NOT NULL,target_guid TEXT NOT NULL,attempt_ms INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(conversation_id,target_guid));
CREATE TABLE IF NOT EXISTS ordinary_anchors(source_row INTEGER PRIMARY KEY,source TEXT NOT NULL UNIQUE);
