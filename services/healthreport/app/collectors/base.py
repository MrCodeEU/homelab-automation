"""Collector plumbing.

Every collector is a callable taking (config, rules) and returning a
CollectorResult. A collector that raises is recorded as an error rather than
killing the run - a broken collector is itself something the report must say
out loud, which is what `collector_health` in main.py turns into observations.
"""

import time
from typing import Callable, Dict

import requests

from ..model import CollectorResult

REGISTRY: Dict[str, Callable] = {}


def collector(name: str):
    def wrap(fn):
        REGISTRY[name] = fn
        fn.collector_name = name
        return fn
    return wrap


def run_collector(name: str, fn, config, rules) -> CollectorResult:
    started = time.time()
    try:
        result = fn(config, rules)
        result.name = name
        result.duration_s = time.time() - started
        return result
    except requests.exceptions.RequestException as exc:
        return CollectorResult(
            name=name,
            status="unavailable",
            error="%s: %s" % (type(exc).__name__, exc),
            duration_s=time.time() - started,
        )
    except Exception as exc:
        return CollectorResult(
            name=name,
            status="error",
            error="%s: %s" % (type(exc).__name__, exc),
            duration_s=time.time() - started,
        )


def http_get(url, timeout=20, **kwargs):
    response = requests.get(url, timeout=timeout, **kwargs)
    response.raise_for_status()
    return response
