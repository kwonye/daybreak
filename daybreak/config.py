from fnmatch import fnmatchcase
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

def validate(config):
    if not isinstance(config, dict):
        raise ValueError('Configuration must be a JSON object')
    if not isinstance(config.get('apps', {}), dict):
        raise ValueError('apps must be an object')
    exclude = config.get('exclude', [])
    if not isinstance(exclude, list) or not all(isinstance(x, str) for x in exclude):
        raise ValueError('exclude must be a list of bundle IDs')
    whitelist = config.get('whitelist', [])
    if not isinstance(whitelist, list) or not all(isinstance(x, str) and x for x in whitelist):
        raise ValueError('whitelist must be a list of bundle IDs or patterns')
    for key in ('restart_unmanaged', 'restart_current'):
        if key in config and type(config[key]) is not bool:
            raise ValueError(f'{key} must be a boolean')
    hour = config.get('hour', 8)
    if type(hour) is not int or not 0 <= hour <= 23:
        raise ValueError('hour must be an integer from 0 through 23')
    timeout = config.get('quit_timeout_seconds', 60)
    if type(timeout) not in (int, float) or not 1 <= timeout <= 600:
        raise ValueError('quit_timeout_seconds must be between 1 and 600')
    try:
        ZoneInfo(config.get('timezone', 'America/Los_Angeles'))
    except (ZoneInfoNotFoundError, TypeError, ValueError):
        raise ValueError('timezone must be a valid IANA timezone') from None
    if 'sparkle_cli' in config and not isinstance(config['sparkle_cli'], str):
        raise ValueError('sparkle_cli must be a path string')
    for bundle_id, spec in config.get('apps', {}).items():
        if not isinstance(bundle_id, str) or not isinstance(spec, dict):
            raise ValueError('Every apps entry must be a bundle ID mapped to an object')
        for key in ('allow_workload_interruption',):
            if key in spec and type(spec[key]) is not bool:
                raise ValueError(f'{bundle_id}.{key} must be a boolean')
        for key in ('backend', 'executable', 'cask'):
            if key in spec and not isinstance(spec[key], str):
                raise ValueError(f'{bundle_id}.{key} must be a string')
    return config


def whitelisted(bundle_id, config):
    """True if bundle_id matches any whitelist (or legacy exclude) entry: exact ID or case-sensitive glob."""
    return any(fnmatchcase(bundle_id, p) for p in (*config.get('whitelist', []), *config.get('exclude', [])))
