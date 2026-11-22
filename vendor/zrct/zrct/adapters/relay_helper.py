"""Private fixture worker. Reuses Zimbr's fixture implementation and byte assertions."""
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import sys
import time
import uuid
from contextlib import closing


def main():
    repository, evidence = map(Path, sys.argv[1:3])
    sys.path.insert(0, str(repository / "tests"))
    sys.path.insert(0, str(repository / "tools"))
    from attachment_sends import AttachmentSends
    from client_media_transport import png
    from fixture import add_message
    fixture = AttachmentSends()
    fixture.setUp()
    paths = [fixture.root / name for name in ("photo 👋.png", "empty.txt", "original.bin")]
    originals = [png(), b"", bytes(range(256)) * 1024]
    for path, content in zip(paths, originals):
        path.write_bytes(content)
    request_id = None
    def reply(value):
        envelope = dict(event="ready", data=value) if request_id is None else dict(id=request_id, result=value)
        print(json.dumps(envelope, ensure_ascii=False), flush=True)
    try:
        # Stable old content for visual baselines; certificate validity remains real time.
        with closing(sqlite3.connect(fixture.source)) as db:
            db.execute("UPDATE message SET date=?+ROWID", (790000000000000000,))
            db.commit()
        reply(dict(ready=True, args=fixture.tls.client_args(), paths=list(map(str, paths))))
        for line in sys.stdin:
            command = json.loads(line)
            request_id = command["id"]
            op = command["op"]
            try:
                if op == "sent_once":
                    rows = fixture.source_rows()
                    fixture.assertEqual(sum(row[0] == command["text"] for row in rows), 1)
                    with closing(sqlite3.connect(fixture.root / "data/relay.db")) as db:
                        records = [json.loads(r[0]) for r in db.execute("SELECT record FROM send_requests")]
                    fixture.assertEqual(len(records), 1)
                    if records[0]["state"] != "delivered":
                        reply(dict(ok=False, record=records[0]))
                        continue
                    reply(dict(ok=True, rows=len(rows), requests=len(records)))
                elif op == "stage":
                    fixture.assertEqual(fixture.source_rows(), [])
                    paths[0].unlink()
                    paths[1].write_bytes(b"No longer empty")
                    paths[2].write_bytes(b"Replaced after review")
                    reply(dict(ok=True))
                elif op == "verify_files":
                    rows = fixture.source_rows()
                    fixture.assertEqual([row[0] for row in rows], [command["text"], "", "", ""])
                    for row, content, path in zip(rows[1:], originals, paths):
                        fixture.assertEqual(row[1], path.name)
                        fixture.assertEqual(Path(row[2]).read_bytes(), content)
                    reply(dict(ok=True, original_bytes=True, attachments=3))
                elif op in ("history", "benchmark_history"):
                    benchmark = op == "benchmark_history"
                    count = command.get("count", 200)
                    if benchmark:
                        if not 1 <= count <= 20000:
                            raise ValueError("Benchmark history must contain 1..20000 messages")
                        fixture.stop()
                    with closing(sqlite3.connect(fixture.source)) as db:
                        for index in range(count):
                            add_message(db, f"Reading anchor {index:03d}", chat=1,
                                        date=790000000000000000 - 1000000 + index,
                                        **({"guid": str(uuid.UUID(int=index + 1))} if benchmark else {}))
                        if benchmark:
                            # Start on a different conversation so opening Alice measures
                            # its first history load, rather than an already-open view.
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
                        row = add_message(db, command["text"], chat=1)
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
                print(json.dumps(dict(id=request_id, error=str(error))), flush=True)
    finally:
        if fixture.proc:
            try:
                os.kill(fixture.proc.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        shutil.copyfile(fixture.root / "log", evidence / "relay.log")
        fixture.tearDown()


if __name__ == "__main__":
    main()
