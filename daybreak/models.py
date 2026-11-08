from dataclasses import dataclass, field, asdict
from typing import Any

PROTECTED_PREFIXES = ('com.openai.', 'org.sparkle-project.Sparkle.', 'com.google.GoogleUpdater', 'io.tailscale.')

@dataclass(frozen=True)
class App:
    bundle_id: str
    name: str
    path: str
    version: str
    build: str
    pids: tuple[int, ...]
    launches: tuple[float, ...] = ()
    executable: str = ''
    fingerprint: str = ''
    hints: tuple[str, ...] = ()
    stale: bool = False

    def to_dict(self):
        return asdict(self)

@dataclass
class Check:
    state: str  # available, current, unknown
    target: str = ''
    detail: str = ''

@dataclass
class Result:
    bundle_id: str
    name: str
    status: str
    backend: str = ''
    before: str = ''
    after: str = ''
    detail: str = ''
    old_pids: list[int] = field(default_factory=list)
    new_pids: list[int] = field(default_factory=list)
    verification: str = ''

    def to_dict(self):
        return asdict(self)


def protected(app: App) -> bool:
    return (app.bundle_id.startswith(PROTECTED_PREFIXES)
            or app.path.startswith(('/System/', '/usr/', '/Library/Apple/'))
            or '/Contents/' in app.path)
