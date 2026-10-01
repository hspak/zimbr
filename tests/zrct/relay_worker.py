"""Private fixture worker. Reuses Zimbr's fixture implementation and byte assertions."""
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import sys
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
    def reply(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)
    try:
        # Stable old content for visual baselines; certificate validity remains real time.
        with closing(sqlite3.connect(fixture.source)) as db:
            db.execute("UPDATE message SET date=?+ROWID", (790000000000000000,))
            db.commit()
        reply(dict(ready=True, args=fixture.tls.client_args(), paths=list(map(str, paths))))
        for line in sys.stdin:
            command = json.loads(line)
            op = command["op"]
            try:
                if op == "sends":
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
                elif op == "history":
                    with closing(sqlite3.connect(fixture.source)) as db:
                        for index in range(command.get("count", 200)):
                            add_message(db, f"Reading anchor {index:03d}", chat=1,
                                        date=790000000000000000 - 1000000 + index)
                        db.commit()
                    reply(dict(ok=True))
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
            except Exception as error:
                reply(dict(ok=False, assertion=str(error)))
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
