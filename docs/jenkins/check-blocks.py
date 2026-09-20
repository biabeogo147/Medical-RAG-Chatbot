"""Report blocks a step hands over that never reached the files it names.

    python3 docs/jenkins/check-blocks.py docs/jenkins/guide/3-pipeline.md 15 Dockerfile Jenkinsfile .dockerignore

Rule 5's grep finds a placeholder you forgot to fill. It cannot see a block you never pasted at all,
and that one stays silent until the cluster refuses the object, long after the push.

Check one step at a time, against the files in that step's table, right after doing it: later steps
edit earlier steps' blocks on purpose, so a block checked too late looks missing when it is not.

A block is skipped when it still carries a <placeholder> anywhere, because that one is yours to
fill in and rule 5 covers it. Skipped blocks are counted and named, so a skip never reads as a pass.
A step with no fenced block at all is reported as such, not as success: several steps hand their
changes over in prose, and this tool cannot check those.
"""
import io
import os
import re
import sys

# Every fence a step can hand over, including a bare one (.dockerignore uses it).
FENCE = re.compile(r'^```([a-z]*)$(.*?)^```$', re.S | re.M)
PROSE = ('bash', 'sh', 'console', 'text', 'diff', '')


def read(path):
    if not os.path.exists(path):
        raise SystemExit('no such file: %s (run from the repository root)' % path)
    return io.open(path, encoding='utf-8', newline='').read().replace('\r\n', '\n')


def step_text(guide, step):
    g = read(guide)
    start = g.find('## Step %d ' % step)
    if start < 0:
        raise SystemExit('step %d not found in %s' % (step, guide))
    nxt = g.find('## Step %d ' % (step + 1), start)
    end = nxt if nxt > 0 else g.find('\n## ', start + 1)
    return g[start:end if end > 0 else len(g)]


def main(argv):
    if len(argv) < 4:
        raise SystemExit(__doc__)
    guide = argv[1]
    try:
        step = int(argv[2])
    except ValueError:
        raise SystemExit('step must be a number, not %r' % argv[2])
    haystack = ''.join(read(t) for t in argv[3:])

    checked, skipped, missing = [], [], []
    for lang, block in FENCE.findall(step_text(guide, step)):
        block = block.strip('\n')
        first = block.split('\n')[0].strip()
        if lang in PROSE:
            continue
        if '<' in block and '>' in block:
            skipped.append(first)
            continue
        checked.append(first)
        if block not in haystack:
            missing.append(first)

    if not checked and not skipped:
        print('step %d: NO BLOCKS to check - this step hands its changes over in prose' % step)
        return 2

    for first in skipped:
        print('  skipped (has a placeholder, rule 5 covers it): ' + first[:66])
    if missing:
        print('step %d: %d of %d blocks MISSING' % (step, len(missing), len(checked)))
        for first in missing:
            print('  ' + first[:76])
        return 1
    print('step %d: all %d blocks present (%d skipped)' % (step, len(checked), len(skipped)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
