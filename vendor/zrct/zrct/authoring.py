"""Semantic action skeletons require a developer to supply the scenario's assertions."""
import json
from pathlib import Path


def skeleton(run, output):
    data = json.loads((Path(run) / 'manifest.json').read_text())
    lines = ['from zrct import TestCase', '', '', 'class RecordedWorkflow(TestCase):',
             '    def test_recorded_workflow(self):',
             '        app = self.context.fixture.launch()  # Adapt to the owning suite fixture.']
    for step in data['steps']:
        args = step.get('arguments', {})
        operation = step['name'].split(' ', 1)[0]
        target = args.get('target')
        if operation == 'click' and target:
            lines.append(f'        app.target({target!r}).click()')
        elif operation == 'type_text':
            lines.append(f'        app.type_text({args["text"]!r})')
        elif operation == 'press':
            lines.append(f'        app.press({args["text"]!r})')
        elif operation == 'scroll' and target:
            lines.append(f'        app.target({target!r}).scroll({args["dy"]!r}, dx={args.get("dx",0)!r}, modifiers={args.get("text", "")!r})')
        elif operation == 'drag' and target:
            lines.append(f'        app.target({target!r}).drag({args["dx"]!r}, {args["dy"]!r})')
        elif operation == 'resize':
            lines.append(f'        app.resize({args["width"]!r}, {args["height"]!r})')
    lines.append('        self.fail("Add UI expectations and independent fixture effect assertions")')
    output = Path(output)
    # Refuse to overwrite an authored scenario.
    with output.open('x') as stream:
        stream.write('\n'.join(lines) + '\n')
    return output.resolve()
