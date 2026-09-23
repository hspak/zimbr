"""Synthetic Messages schema; never opens a user's real database."""
import sqlite3
import time
import uuid

SCHEMA = '''
CREATE TABLE zimbr_fixture(key TEXT PRIMARY KEY,value TEXT);
INSERT INTO zimbr_fixture VALUES('synthetic','yes');
CREATE TABLE chat(ROWID INTEGER PRIMARY KEY,guid TEXT,service_name TEXT,display_name TEXT);
CREATE TABLE handle(ROWID INTEGER PRIMARY KEY,id TEXT,service TEXT);
CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER,PRIMARY KEY(chat_id,message_id));
CREATE TABLE message(ROWID INTEGER PRIMARY KEY,guid TEXT,date INTEGER,handle_id INTEGER DEFAULT 1,is_from_me INTEGER DEFAULT 0,service TEXT DEFAULT 'iMessage',text TEXT,attributedBody BLOB,is_delivered INTEGER DEFAULT 0,date_delivered INTEGER DEFAULT 0,error INTEGER DEFAULT 0,is_sent INTEGER DEFAULT 0,is_finished INTEGER DEFAULT 1,associated_message_type INTEGER DEFAULT 0,item_type INTEGER DEFAULT 0,is_system_message INTEGER DEFAULT 0,balloon_bundle_id TEXT);
CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY,guid TEXT,transfer_name TEXT,mime_type TEXT,total_bytes INTEGER);
CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
INSERT INTO handle VALUES(1,'alice@example.invalid','iMessage'),(2,'bob@example.invalid','iMessage'),(3,'+14155550123','SMS');
INSERT INTO chat VALUES(1,'iMessage;-;alice@example.invalid','iMessage',''),(2,'iMessage;+;group-fixture','iMessage','Fixture group'),(3,'SMS;-;+14155550123','SMS',''),(4,'iMessage;-;empty@example.invalid','iMessage','Empty');
INSERT INTO chat_handle_join VALUES(1,1),(2,1),(2,2),(3,3);
'''

def apple_ns():
    return int((time.time()-978307200)*1_000_000_000)

def add_message(db, text='hello', chat=1, date=None, **fields):
    values = dict(guid=str(uuid.uuid4()), date=apple_ns() if date is None else date, text=text)
    values.update(fields)
    row = db.execute('INSERT INTO message('+','.join(values)+') VALUES('+','.join('?' for _ in values)+')', tuple(values.values())).lastrowid
    if chat is not None:
        db.execute('INSERT INTO chat_message_join VALUES(?,?)',(chat,row))
    return row

def create(path, count=240):
    db=sqlite3.connect(path)
    db.executescript(SCHEMA)
    for i in range(count):
        add_message(db, 'Historical %d\n👩‍💻 e\u0301'%i, chat=1 if i%2 else 2, date=apple_ns()-86400*10**9+i)
    add_message(db,None,chat=2,attributedBody=b'unsupported archive')
    add_message(db,'reaction',chat=2,associated_message_type=2001)
    add_message(db,None,chat=2,item_type=1)
    mid=add_message(db,None,chat=1)
    db.execute("INSERT INTO attachment VALUES(1,'private-fixture-guid','image.png','image/png',1024)")
    db.execute('INSERT INTO message_attachment_join VALUES(?,1)',(mid,))
    db.commit();db.close()

if __name__=='__main__':
    import sys
    create(sys.argv[1])
