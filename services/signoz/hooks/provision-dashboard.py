#!/usr/bin/env python3
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone


TITLE = "Homelab Overview"


def attr(key, typ="tag", data_type="string", is_column=False):
    return {
        "dataType": data_type,
        "id": f"{key}--{data_type}--{typ}--{str(is_column).lower()}",
        "isColumn": is_column,
        "isJSON": False,
        "key": key,
        "type": typ,
    }


def metric_attr(name, metric_type="Gauge"):
    return {
        "dataType": "float64",
        "id": f"{name}--float64--{metric_type}--true",
        "isColumn": True,
        "isJSON": False,
        "key": name,
        "type": metric_type,
    }


def query(metric, query_name="A", expression="A", group_by=None, legend="{{host.name}}",
          reduce_to="avg", disabled=False):
    group_by = group_by or ["host.name"]
    return {
        "aggregateAttribute": metric_attr(metric),
        "aggregateOperator": "avg",
        "dataSource": "metrics",
        "disabled": disabled,
        "expression": expression,
        "filters": {"items": [], "op": "AND"},
        "functions": [],
        "groupBy": [attr(item) for item in group_by],
        "having": [],
        "legend": legend,
        "limit": None,
        "orderBy": [],
        "queryName": query_name,
        "reduceTo": reduce_to,
        "spaceAggregation": "avg",
        "stepInterval": 60,
        "timeAggregation": "avg",
    }


def empty_attr():
    return {
        "dataType": "",
        "id": "------false",
        "isColumn": False,
        "isJSON": False,
        "key": "",
        "type": "",
    }


def filter_item(key, op, value, typ="tag", data_type="string", is_column=False):
    return {
        "id": uuid.uuid4().hex[:8],
        "key": attr(key, typ=typ, data_type=data_type, is_column=is_column),
        "op": op,
        "value": value,
    }


def log_query(query_name="A", operator="count", group_by=None, filters=None,
              legend="", order_by=None, reduce_to="sum"):
    return {
        "aggregateAttribute": empty_attr(),
        "aggregateOperator": operator,
        "dataSource": "logs",
        "disabled": False,
        "expression": query_name,
        "filters": {"items": filters or [], "op": "AND"},
        "functions": [],
        "groupBy": [attr(item) for item in (group_by or [])],
        "having": [],
        "legend": legend,
        "limit": None,
        "orderBy": order_by or [],
        "queryName": query_name,
        "reduceTo": reduce_to,
        "spaceAggregation": "sum",
        "stepInterval": 60,
        "timeAggregation": "rate",
    }


def base_widget(title, panel_type, unit="none"):
    return {
        "description": "",
        "fillSpans": False,
        "id": str(uuid.uuid4()),
        "isStacked": False,
        "nullZeroValues": "zero",
        "opacity": "1",
        "panelTypes": panel_type,
        "query": {
            "builder": {"queryData": [], "queryFormulas": []},
            "clickhouse_sql": [{"disabled": False, "legend": "", "name": "A", "query": ""}],
            "id": str(uuid.uuid4()),
            "promql": [{"disabled": False, "legend": "", "name": "A", "query": ""}],
            "queryType": "builder",
        },
        "selectedLogFields": [
            {"dataType": "string", "name": "body", "type": ""},
            {"dataType": "string", "name": "timestamp", "type": ""},
            {"dataType": "string", "name": "log.source", "type": "tag"},
            {"dataType": "string", "name": "log.file.name", "type": "tag"},
        ],
        "selectedTracesFields": [
            attr("serviceName", is_column=True),
            attr("name", is_column=True),
            attr("durationNano", data_type="float64", is_column=True),
            attr("httpMethod", is_column=True),
            attr("responseStatusCode", is_column=True),
        ],
        "softMax": 0,
        "softMin": 0,
        "thresholds": [],
        "timePreferance": "GLOBAL_TIME",
        "title": title,
        "yAxisUnit": unit,
    }


def graph(title, metric, x, y, w, h, group_by, legend, unit="none"):
    widget = base_widget(title, "graph", unit)
    widget["query"]["builder"]["queryData"] = [query(metric, group_by=group_by, legend=legend)]
    return widget, {"h": h, "i": widget["id"], "w": w, "x": x, "y": y}


def log_graph(title, x, y, w, h, filters=None, group_by=None, legend="", panel_type="graph"):
    widget = base_widget(title, panel_type)
    widget["query"]["builder"]["queryData"] = [
        log_query(filters=filters, group_by=group_by, legend=legend)
    ]
    return widget, {"h": h, "i": widget["id"], "w": w, "x": x, "y": y}


def log_list(title, x, y, w, h, filters=None):
    widget = base_widget(title, "list")
    widget["query"]["builder"]["queryData"] = [
        log_query(
            operator="noop",
            filters=filters,
            order_by=[{"columnName": "timestamp", "order": "desc"}],
            reduce_to="avg",
        )
    ]
    return widget, {"h": h, "i": widget["id"], "w": w, "x": x, "y": y}


def container_table(x, y, w, h):
    widget = base_widget("Container Inventory and Usage", "table")
    group_by = ["host.name", "container.name", "container.image.name"]
    widget["query"]["builder"]["queryData"] = [
        query("container.cpu.utilization", "A", "A", group_by, "CPU %", "max", True),
        query("container.memory.percent", "B", "B", group_by, "Memory %", "max", True),
        query("container.memory.usage.total", "C", "C", group_by, "Memory MB", "max", True),
    ]
    widget["query"]["builder"]["queryFormulas"] = [
        {"disabled": False, "expression": "A", "legend": "CPU %", "queryName": "F1"},
        {"disabled": False, "expression": "B", "legend": "Memory %", "queryName": "F2"},
        {"disabled": False, "expression": "C/1024/1024", "legend": "Memory MB", "queryName": "F3"},
    ]
    return widget, {"h": h, "i": widget["id"], "w": w, "x": x, "y": y}


def dashboard():
    widgets = []
    layout = []
    for args in [
        ("Host Load Average 1m", "system.cpu.load_average.1m", 0, 0, 3, 4,
         ["host.name"], "{{host.name}}", "none"),
        ("Host Memory Usage", "system.memory.usage", 3, 0, 3, 4,
         ["host.name", "state"], "{{host.name}} {{state}}", "bytes"),
        ("Filesystem Usage", "system.filesystem.usage", 6, 0, 3, 4,
         ["host.name", "mountpoint", "state"], "{{host.name}} {{mountpoint}} {{state}}", "bytes"),
        ("Network IO", "system.network.io", 9, 0, 3, 4,
         ["host.name", "device", "direction"], "{{host.name}} {{device}} {{direction}}", "binBps"),
        ("Container CPU", "container.cpu.utilization", 0, 4, 6, 5,
         ["host.name", "container.name"], "{{host.name}} {{container.name}}", "percentunit"),
        ("Container Memory %", "container.memory.percent", 6, 4, 6, 5,
         ["host.name", "container.name"], "{{host.name}} {{container.name}}", "percentunit"),
    ]:
        widget, item = graph(*args)
        widgets.append(widget)
        layout.append(item)
    widget, item = container_table(0, 9, 12, 6)
    widgets.append(widget)
    layout.append(item)

    caddy = [filter_item("log.source", "=", "caddy")]
    fail2ban = [filter_item("log.source", "=", "fail2ban")]
    caddy_4xx = caddy + [filter_item("body", "contains", '"status":4', typ="", is_column=True)]
    caddy_5xx = caddy + [filter_item("body", "contains", '"status":5', typ="", is_column=True)]
    fail2ban_bans = fail2ban + [
        filter_item("body", "contains", "Ban", typ="", is_column=True),
    ]

    for widget, item in [
        log_graph("Caddy Requests by Log File", 0, 15, 6, 5, caddy, ["log.file.name"], "{{log.file.name}}"),
        log_graph("Caddy 4xx Responses", 6, 15, 3, 5, caddy_4xx, ["log.file.name"], "{{log.file.name}}", "bar"),
        log_graph("Caddy 5xx Responses", 9, 15, 3, 5, caddy_5xx, ["log.file.name"], "{{log.file.name}}", "bar"),
        log_graph("Fail2ban Events", 0, 20, 4, 5, fail2ban, ["log.file.name"], "{{log.file.name}}", "bar"),
        log_graph("Fail2ban Ban Activity", 4, 20, 4, 5, fail2ban_bans, ["log.file.name"], "{{log.file.name}}", "bar"),
        log_graph("All Logs by Source", 8, 20, 4, 5, [], ["log.source"], "{{log.source}}", "bar"),
        log_list("Recent Caddy Access Logs", 0, 25, 6, 7, caddy),
        log_list("Recent Fail2ban Logs", 6, 25, 6, 7, fail2ban),
    ]:
        widgets.append(widget)
        layout.append(item)

    return {
        "title": TITLE,
        "description": "Homelab operations dashboard for host resources, Docker usage, Caddy access logs, and fail2ban activity.",
        "name": "homelab-overview",
        "tags": ["homelab", "infrastructure", "docker"],
        "version": "v5",
        "variables": {},
        "widgets": widgets,
        "layout": layout,
        "uploadedGrafana": False,
    }


def request_json(method, url, api_key, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("SIGNOZ-API-KEY", api_key)
    with urllib.request.urlopen(req, timeout=30) as response:
        body = response.read().decode()
        return json.loads(body) if body else {}


def provision_via_api(data):
    api_key = os.getenv("SIGNOZ_API_KEY", "").strip()
    if not api_key:
        return False
    base_url = os.getenv("SIGNOZ_URL", "http://127.0.0.1:8080").rstrip("/")
    dashboards = request_json("GET", f"{base_url}/api/v1/dashboards", api_key)
    items = dashboards.get("data", dashboards)
    if isinstance(items, dict):
        items = items.get("data", items.get("dashboards", []))
    existing_id = None
    for item in items or []:
        item_data = item.get("data", {})
        if item.get("name") == TITLE or item_data.get("title") == TITLE:
            existing_id = item.get("id")
            break
    if existing_id:
        request_json("PUT", f"{base_url}/api/v1/dashboards/{existing_id}", api_key,
                     {"id": existing_id, "data": data})
        print(f"CHANGED SigNoz dashboard updated via API: {TITLE}")
    else:
        request_json("POST", f"{base_url}/api/v1/dashboards", api_key, data)
        print(f"CHANGED SigNoz dashboard created via API: {TITLE}")
    return True


def sqlite_path():
    candidates = [
        os.getenv("SIGNOZ_SQLITE_PATH", ""),
        "/var/lib/docker/volumes/signoz-sqlite/_data/signoz.db",
        "/opt/signoz/signoz.db",
    ]
    for path in candidates:
        if path and os.path.exists(path):
            return path
    raise FileNotFoundError("SigNoz SQLite DB not found and SIGNOZ_API_KEY is not configured")


def provision_via_sqlite(data):
    path = sqlite_path()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f+00:00")
    con = sqlite3.connect(path, timeout=30)
    con.execute("PRAGMA busy_timeout=30000")
    org_id = con.execute("SELECT id FROM organizations LIMIT 1").fetchone()[0]
    user = con.execute("SELECT email FROM users WHERE org_id = ? LIMIT 1", (org_id,)).fetchone()
    actor = user[0] if user else "automation@localhost"
    existing_id = None
    for row_id, raw in con.execute("SELECT id, data FROM dashboard WHERE org_id = ?", (org_id,)):
        try:
            if json.loads(raw).get("title") == TITLE:
                existing_id = row_id
                break
        except json.JSONDecodeError:
            continue
    raw = json.dumps(data, separators=(",", ":"))
    if existing_id:
        con.execute(
            "UPDATE dashboard SET updated_at = ?, updated_by = ?, data = ? WHERE id = ?",
            (now, actor, raw, existing_id),
        )
        print(f"CHANGED SigNoz dashboard updated via SQLite fallback: {TITLE}")
    else:
        con.execute(
            "INSERT INTO dashboard (id, created_at, updated_at, created_by, updated_by, data, locked, org_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (str(uuid.uuid4()), now, now, actor, actor, raw, False, org_id),
        )
        print(f"CHANGED SigNoz dashboard created via SQLite fallback: {TITLE}")
    con.commit()
    con.close()


def main():
    data = dashboard()
    try:
        if provision_via_api(data):
            return
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"SigNoz API provisioning failed: HTTP {exc.code} {exc.read().decode()}") from exc
    provision_via_sqlite(data)
    time.sleep(1)


if __name__ == "__main__":
    main()
