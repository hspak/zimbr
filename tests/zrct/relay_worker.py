"""Private fixture worker. Reuses Zimbr's fixture implementation and byte assertions."""
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import sys
import time
import threading
import uuid
from contextlib import closing


def main():
    repository, evidence = map(Path, sys.argv[1:3])
    sys.path.insert(0, str(repository / "tests"))
    sys.path.insert(0, str(repository / "tools"))
    from attachment_sends import AttachmentSends
    from client_media_transport import png
    from fixture import add_message
    from relay_faults import Faults
    fixture = AttachmentSends()
    fixture.setUp()
    paths = [fixture.root / name for name in ("photo 👋.png", "empty.txt", "original.bin")]
    originals = [png(), b"", bytes(range(256)) * 1024]
    for path, content in zip(paths, originals):
        path.write_bytes(content)
    output_lock = threading.Lock()
    faults = None
    def write(value):
        with output_lock:
            print(json.dumps(value, ensure_ascii=False), flush=True)
    def publish(event, data):
        write(dict(event=event, data=data))
    def reply(value):
        write(dict(id=command["id"], result=value))
    try:
        # Stable old content for visual baselines; certificate validity remains real time.
        with closing(sqlite3.connect(fixture.source)) as db:
            db.execute("UPDATE message SET date=?+ROWID", (790000000000000000,))
            db.commit()
        publish("ready", dict(args=fixture.tls.client_args(), paths=list(map(str, paths))))
        for line in sys.stdin:
            command = json.loads(line)
            op = command["op"]
            try:
                if op == "fault":
                    if faults is None:
                        faults = Faults(fixture, publish)
                    faults.set(command["mode"])
                    reply(dict(ok=True, args=fixture.tls.client_args(port=faults.server.server_port)))
                elif op == "faults":
                    reply(faults.snapshot())
                elif op == "status":
                    reply(dict(ok=True, **fixture.get("/v1/status")))
                elif op == "rich_content":
                    fixture.stop()
                    attachments = fixture.source.with_suffix(".db.attachments")
                    attachments.mkdir(mode=0o700, exist_ok=True)
                    guid = str(uuid.UUID(int=2000000))
                    with closing(sqlite3.connect(fixture.source)) as db:
                        db.executescript("ALTER TABLE message ADD COLUMN associated_message_guid TEXT; "
                                         "ALTER TABLE message ADD COLUMN associated_message_emoji TEXT;")
                        row = add_message(db, "Photos and reactions 👋", guid=guid)
                        for index in range(2):
                            path = attachments / f"photo-{index}"
                            path.write_bytes(b"ZIMBR-IMAGE fixture")
                            db.execute("INSERT INTO attachment VALUES(?,?,?,?,?,?)",
                                       (100 + index, str(uuid.UUID(int=2000001 + index)),
                                        f"photo-{index}.heic", "image/heic", 19, str(path)))
                            db.execute("INSERT INTO message_attachment_join VALUES(?,?)", (row, 100 + index))
                        add_message(db, "Reaction fixture", associated_message_type=2001,
                                    associated_message_guid="p:0/" + guid, handle_id=1)
                        add_message(db, "Reaction fixture", associated_message_type=2001,
                                    associated_message_guid="p:0/" + guid, handle_id=2, is_from_me=1)
                        fixture.before = db.execute("SELECT max(ROWID) FROM message").fetchone()[0]
                        db.commit()
                    fixture.start()
                    reply(dict(ok=True, text="Photos and reactions 👋"))
                elif op == "remove_self_reaction":
                    with closing(sqlite3.connect(fixture.source)) as db:
                        removed = db.execute("DELETE FROM message WHERE is_from_me=1 AND associated_message_type=2001").rowcount
                        db.commit()
                    fixture.assertEqual(removed, 1)
                    reply(dict(ok=True, removed=removed))
                elif op == "sends":
                    with closing(sqlite3.connect(fixture.source)) as db:
                        rows = [dict(text=text, chat=chat) for text, chat in db.execute(
                            "SELECT m.text,j.chat_id FROM message m "
                            "JOIN chat_message_join j ON j.message_id=m.ROWID "
                            "WHERE m.ROWID>? AND m.is_from_me=1 ORDER BY m.ROWID", (fixture.before,))]
                    with closing(sqlite3.connect(fixture.root / "data/relay.db")) as db:
                        records = [json.loads(r[0]) for r in db.execute("SELECT record FROM send_requests")]
                    reply(dict(ok=True, rows=rows, requests=records))
                elif op == "stage":
                    fixture.assertEqual(fixture.source_rows(), [])
                    paths[0].unlink()
                    paths[1].write_bytes(b"No longer empty")
                    paths[2].write_bytes(b"Replaced after review")
                    reply(dict(ok=True))
                elif op == "verify_files":
                    rows = fixture.source_rows()
                    indices = command["indices"]
                    caption = [command["text"]] if command["text"] else []
                    fixture.assertEqual([row[0] for row in rows], caption + [""] * len(indices))
                    for row, index in zip(rows[len(caption):], indices):
                        content, path = originals[index], paths[index]
                        fixture.assertEqual(row[1], path.name)
                        fixture.assertEqual(Path(row[2]).read_bytes(), content)
                    reply(dict(ok=True, original_bytes=True, attachments=len(indices)))
                elif op in ("history", "benchmark_history"):
                    benchmark = op == "benchmark_history"
                    count = command.get("count", 200)
                    if not 1 <= count <= 20000:
                        raise ValueError("history count must be between 1 and 20000")
                    if benchmark:
                        fixture.stop()
                    with closing(sqlite3.connect(fixture.source)) as db:
                        for index in range(count):
                            add_message(db, f"Reading anchor {index:03d}", chat=1,
                                        date=790000000000000000 - 1000000 + index,
                                        **({"guid": str(uuid.UUID(int=index + 1))} if benchmark else {}))
                        if benchmark:
                            add_message(db, "Benchmark initial conversation", chat=2,
                                        date=790000001000000000, guid=str(uuid.UUID(int=1000000)))
                        expected = db.execute("SELECT count(*) FROM message").fetchone()[0]
                        db.commit()
                    if benchmark:
                        fixture.start()
                        deadline = time.monotonic() + 45
                        while True:
                            with closing(sqlite3.connect(f"file:{fixture.root / 'data/relay.db'}?mode=ro", uri=True)) as db:
                                indexed = db.execute("SELECT count(*) FROM messages").fetchone()[0]
                            if indexed == expected:
                                break
                            if fixture.proc.poll() is not None or time.monotonic() >= deadline:
                                raise RuntimeError(f"Relay indexed {indexed}/{expected} fixture messages")
                            time.sleep(.05)
                    reply(dict(ok=True, source_messages=expected, indexed_messages=indexed if benchmark else None))
                elif op == "receive":
                    with closing(sqlite3.connect(fixture.source)) as db:
                        row = add_message(db, command["text"], chat=command.get("chat", 1))
                        db.commit()
                    reply(dict(ok=True, source_row=row))
                elif op == "pause":
                    os.kill(fixture.proc.pid, signal.SIGSTOP)
                    reply(dict(ok=True))
                elif op == "resume":
                    os.kill(fixture.proc.pid, signal.SIGCONT)
                    reply(dict(ok=True))
                elif op == "close":
                    reply(dict(ok=True))
                    break
                else:
                    raise ValueError(f"Unknown fixture operation {op}")
            except AssertionError as error:
                reply(dict(ok=False, assertion=str(error)))
            except Exception as error:
                write(dict(id=command["id"], error=str(error)))
    finally:
        if faults:
            faults.close()
        if fixture.proc:
            try:
                os.kill(fixture.proc.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        shutil.copyfile(fixture.root / "log", evidence / "relay.log")
        fixture.tearDown()


if __name__ == "__main__":
    main()
