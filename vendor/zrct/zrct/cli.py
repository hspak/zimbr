import argparse
import json
from pathlib import Path
import sys

from .artifacts import render_report
from .driver import App
from .environment import doctor
from .errors import ZrctError
from .runner import run, select, worker


def positive(value):
    number = float(value)
    if not 0 < number <= 3600:
        raise argparse.ArgumentTypeError("must be between 0 and 3600")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(prog="zrct")
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("doctor")
    check.add_argument("--json", action="store_true")
    launch = commands.add_parser("run")
    launch.add_argument("suite", type=Path)
    launch.add_argument("--output", default="artifacts")
    launch.add_argument("--repeat", type=int, default=1)
    launch.add_argument("--jobs", type=int, help="concurrent isolated scenarios (default: up to 4; 1 when paused)")
    launch.add_argument("--no-build", action="store_true")
    launch.add_argument("--repository", type=Path, help="application checkout root")
    launch.add_argument("--executable", type=Path, help="built application artifact")
    launch.add_argument("--record", action="store_true")
    launch.add_argument("--pause", type=positive, default=0)
    launch.add_argument("--json", action="store_true")
    bench = commands.add_parser("bench", help="measure an explicit benchmark suite serially")
    bench.add_argument("suite", type=Path)
    bench.add_argument("--output", default="artifacts")
    bench.add_argument("--repeat", type=int, default=20, help="measured repetitions after warmup")
    bench.add_argument("--warmup", type=int, default=3, help="discarded full-scenario repetitions")
    bench.add_argument("--no-build", action="store_true")
    bench.add_argument("--repository", type=Path)
    bench.add_argument("--executable", type=Path)
    bench.add_argument("--json", action="store_true")
    for command in (launch, bench):
        command.add_argument("--executable-sha256", help="require this prepared executable identity (with --no-build)")
        selection = command.add_mutually_exclusive_group()
        selection.add_argument("--filter", default="", help="scenario name substring")
        selection.add_argument("--case", action="append", default=[], help="exact Class.test_name; repeat to select multiple")
        selection.add_argument("--rerun-failed", type=Path, help="previous result.json or run directory")
        command.add_argument("--list", action="store_true", help="list selected scenarios without starting fixtures")
    comparison = commands.add_parser("compare", help="diagnostic benchmark comparison; no performance gate")
    comparison.add_argument("baseline", type=Path)
    comparison.add_argument("candidate", type=Path)
    comparison.add_argument("--output", type=Path)
    inspect = commands.add_parser("inspect")
    inspect.add_argument("--session", required=True)
    for name in ("id", "role", "text", "within"):
        inspect.add_argument("--" + name)
    inspect.add_argument("--text-contains", help="label substring; --text matches the complete label")
    inspect.add_argument("--full", action="store_true")
    inspect.add_argument("--json", action="store_true")
    action = commands.add_parser("act")
    action.add_argument("--session", required=True)
    action.add_argument("operation", choices=("click", "press", "type_text", "scroll", "drag", "resize", "screenshot", "close", "overlay", "drop"))
    action.add_argument("arguments", nargs="*")
    action.add_argument("--json", action="store_true")
    report = commands.add_parser("report")
    report.add_argument("run", type=Path)
    baseline = commands.add_parser("baseline")
    baseline.add_argument("actual", type=Path)
    baseline.add_argument("expected", type=Path)
    baseline.add_argument("--accept", action="store_true", required=True)
    frame = commands.add_parser("frame")
    frame.add_argument("recording", type=Path)
    frame.add_argument("--at", type=float, required=True)
    frame.add_argument("--output", type=Path, required=True)
    skeleton_parser = commands.add_parser("skeleton")
    skeleton_parser.add_argument("run", type=Path)
    skeleton_parser.add_argument("--output", type=Path, required=True)
    internal = commands.add_parser("_worker", help=argparse.SUPPRESS)
    internal.add_argument("suite")
    internal.add_argument("name")
    internal.add_argument("root")
    internal.add_argument("--repository", type=Path)
    internal.add_argument("--executable", type=Path)
    internal.add_argument("--metadata", type=Path)
    internal.add_argument("--record", action="store_true")
    internal.add_argument("--benchmark", action="store_true")
    internal.add_argument("--pause", type=float, default=0)
    args = parser.parse_args(argv)
    try:
        if args.command == "doctor":
            result = doctor()
            if args.json:
                print(json.dumps(result))
            else:
                for check in result["checks"]:
                    print(f"{'OK' if check['ok'] else 'MISSING'} {check['name']}: {check['version'] or check['remedy']}")
            return 0 if result["ok"] else 2
        if args.command == "compare":
            from .benchmark import compare, render_comparison
            from .artifacts import atomic_json
            result = compare(args.baseline, args.candidate)
            if args.output:
                atomic_json(args.output, result)
                render_comparison(result, args.output.with_suffix(".html"))
            print(json.dumps(result, ensure_ascii=False))
            return 0
        if args.command in ("run", "bench"):
            if args.list:
                from .suite import load_suite
                _, tests = load_suite(args.suite, repository=args.repository, executable=args.executable)
                names = select(tests, filter=args.filter, cases=args.case, rerun_failed=args.rerun_failed)
                print(json.dumps(names) if args.json else "\n".join(names))
                return 0
            if not 1 <= args.repeat <= 1000:
                parser.error("--repeat must be between 1 and 1000")
            if getattr(args, "jobs", None) is not None and not 1 <= args.jobs <= 64:
                parser.error("--jobs must be between 1 and 64")
            result = run(args.suite, filter=args.filter, cases=args.case, rerun_failed=args.rerun_failed,
                         output=args.output, repeat=args.repeat,
                         no_build=args.no_build, record=getattr(args, "record", False), pause=getattr(args, "pause", 0),
                         repository=args.repository, executable=args.executable, jobs=getattr(args, "jobs", None),
                         benchmark=args.command == "bench", warmup=getattr(args, "warmup", 0),
                         executable_sha256=args.executable_sha256)
            if args.json:
                print(json.dumps(result, ensure_ascii=False))
            else:
                print(f"{result['status']}: {result['run']}/result.json")
                for scenario in result["results"]:
                    print(f"  {scenario['scenario']}: {scenario['status']} {scenario.get('error', '')}")
            return 0 if result["status"] == "passed" else 1
        if args.command == "_worker":
            return worker(args.suite, args.name, args.root, args.record, args.pause,
                          repository=args.repository, executable=args.executable, metadata_path=args.metadata, benchmark=args.benchmark)
        if args.command == "report":
            if (args.run / "benchmark.json").exists():
                from .benchmark import render
                render(json.loads((args.run / "benchmark.json").read_text()), args.run / "benchmark.html")
                print(args.run / "benchmark.html")
            roots = [args.run] if (args.run / "manifest.json").exists() else sorted(p.parent for p in args.run.glob("*/manifest.json"))
            if not roots:
                raise ZrctError("No manifest found")
            for root in roots:
                print(render_report(root))
            return 0
        if args.command == "baseline":
            from .visual import update_baseline
            print(update_baseline(args.actual, args.expected))
            return 0
        if args.command == "frame":
            from .recording import extract_frame
            print(extract_frame(args.recording, args.at, args.output))
            return 0
        if args.command == "skeleton":
            from .authoring import skeleton
            print(skeleton(args.run, args.output))
            return 0
        session = Path(args.session)
        socket = json.loads(session.read_text())["socket"] if session.is_file() else args.session
        app = App(socket)
        if args.command == "inspect":
            targets = app.inspect(id=args.id, role=args.role, text=args.text, text_contains=args.text_contains, within=args.within)
            result = app.last if args.full else dict(frame_id=app.last["frame_id"], targets=targets[:100], total=len(targets))
        else:
            values = args.arguments
            if args.operation == "click":
                result = app.target(values[0]).click()
            elif args.operation == "drop":
                result = app.target(values[0]).drop(values[1:])
            elif args.operation in ("type_text", "press", "overlay"):
                result = app.act(args.operation, text=" ".join(values))
            elif args.operation == "scroll":
                result = app.target(values[0]).scroll(float(values[1]), float(values[2]) if len(values) > 2 else 0)
            elif args.operation == "drag":
                result = app.target(values[0]).drag(float(values[1]), float(values[2]))
            elif args.operation == "resize":
                result = app.resize(int(values[0]), int(values[1]))
            elif args.operation == "screenshot":
                result = dict(path=str(app.screenshot(values[0])))
            else:
                result = app.close()
        print(json.dumps(result, ensure_ascii=False, indent=None if args.json else 2))
        return 0
    except (ZrctError, OSError, ValueError, IndexError) as error:
        result = dict(status=getattr(error, "category", "infrastructure_failure"), error=str(error),
                      details=getattr(error, "details", {}))
        print(json.dumps(result), file=sys.stdout if getattr(args, "json", False) else sys.stderr)
        return 2
