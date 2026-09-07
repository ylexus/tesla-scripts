"""Drive an interactive script through a pty, answering prompts as they appear.

The script's prompts (browser [Y/n], the paste prompt, the verify [Y/n]) only
appear when stdin is a terminal, so piping input past them does not exercise
them. This waits for each prompt and then types the next reply.

    REPLIES='n<US>tesla://...<US>n' python3 drive-pty.py bash script.sh

Replies are separated by \x1f, because a shell cannot put \x00 in an
environment variable. Captured output is written to stdout.
"""
import os
import pty
import re
import select
import sys
import time

PROMPT = re.compile(r'(\[Y/n\]|bare code\):)\s*$')
TIMEOUT = float(os.environ.get('PTY_TIMEOUT', '30'))


def main():
    cmd = sys.argv[1:]
    if not cmd:
        print('usage: drive-pty.py COMMAND [ARGS...]', file=sys.stderr)
        return 2
    replies = os.environ.get('REPLIES', '')
    replies = replies.split('\x1f') if replies else []

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
        os._exit(1)

    buf, out, i = b'', b'', 0
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.4)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            out += chunk
        if i < len(replies) and PROMPT.search(buf.decode('utf8', 'replace')):
            time.sleep(0.15)
            os.write(fd, replies[i].encode() + b'\n')
            i += 1
            buf = b''

    os.close(fd)
    try:
        _, status = os.waitpid(pid, 0)
    except OSError:
        status = 0
    sys.stdout.write(out.decode('utf8', 'replace'))
    return os.waitstatus_to_exitcode(status) if hasattr(os, 'waitstatus_to_exitcode') else 0


if __name__ == '__main__':
    sys.exit(main())
