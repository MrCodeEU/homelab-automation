// Served by ziti-console-proxy as /zac/zac-autologin.js and loaded by ZAC's
// index.html (the proxy adds the script tag). It runs before ZAC starts: if
// the session ZAC kept in localStorage is gone or no longer valid, it logs
// in (the proxy logs in as the read-only identity for anyone Authelia let
// through) and stores the new session where ZAC looks for it, so ZAC opens
// on the dashboard instead of its login page. Synchronous requests on
// purpose: ZAC must not start before the session is stored.
(function () {
  var key = "ziti.settings";
  var origin = window.location.origin;
  var mgmt = "/edge/management/v1";

  function send(method, path, token) {
    var x = new XMLHttpRequest();
    x.open(method, origin + mgmt + path, false);
    x.setRequestHeader("content-type", "application/json");
    x.setRequestHeader("accept", "application/json");
    if (token) {
      x.setRequestHeader("zt-session", token);
    }
    x.send(method === "POST" ? "{}" : null);
    return x;
  }

  try {
    var settings = JSON.parse(localStorage.getItem(key) || "null") || {
      session: {},
      edgeControllers: []
    };
    var session = settings.session || {};
    if (session.id && send("GET", "/current-api-session", session.id).status === 200) {
      return;
    }
    var login = send("POST", "/authenticate?method=password");
    if (login.status !== 200) {
      return; // ZAC shows its own login page
    }
    var data = JSON.parse(login.responseText).data;
    settings.selectedEdgeController = origin;
    settings.edgeControllers = settings.edgeControllers || [];
    if (!settings.edgeControllers.some(function (c) { return c.url === origin; })) {
      settings.edgeControllers.push({ name: window.location.hostname, url: origin });
    }
    settings.session = {
      id: data.token,
      controllerDomain: origin,
      authorization: 100,
      expiresAt: data.expiresAt,
      expirationSeconds: data.expirationSeconds
    };
    localStorage.setItem(key, JSON.stringify(settings));
  } catch (e) {
    // Leave ZAC to its login page.
  }
})();
