"""Private local state, exclusive lock, and DST-aware daily idempotency."""
from contextlib import contextmanager
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import tempfile
from zoneinfo import ZoneInfo

DEFAULT_ZONE = 'America/Los_Angeles'


def due(now, previous_date='', timezone=DEFAULT_ZONE, hour=8):
    local = now.astimezone(ZoneInfo(timezone))
    return local.hour >= hour and local.date().isoformat() != previous_date


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.daybreak-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def locked(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'run.lock').open('a') as lock:
        os.chmod(directory / 'run.lock', 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another Daybreak run is active') from None
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def load_json(path, default):
    try:
        with Path(path).open() as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def save_report(directory, report, keep=30):
    directory = Path(directory)
    name = datetime.now().strftime('%Y%m%dT%H%M%S') + '-' + str(os.getpid()) + '.json'
    write_json(directory / 'runs' / name, report)
    write_json(directory / 'latest.json', report)
    files = sorted((directory / 'runs').glob('*.json'))
    for old in files[:-keep]:
        old.unlink()
