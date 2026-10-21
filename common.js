(() => {
  "use strict";

  const cfg = window.APP_CONFIG || {};

  function assertConfigured() {
    if (!cfg.supabaseUrl || !cfg.supabaseAnonKey ||
        cfg.supabaseUrl.includes("COLE_AQUI") ||
        cfg.supabaseAnonKey.includes("COLE_AQUI")) {
      throw new Error("Aplicação ainda não configurada. Edite assets/config.js.");
    }
  }

  function baseHeaders(token) {
    const bearer = token || cfg.supabaseAnonKey;
    return {
      "Content-Type": "application/json",
      "apikey": cfg.supabaseAnonKey,
      "Authorization": `Bearer ${bearer}`
    };
  }

  async function rpc(name, args = {}, token = null) {
    assertConfigured();
    const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: baseHeaders(token),
      body: JSON.stringify(args)
    });
    const bodyText = await res.text();
    let data = null;
    if (bodyText) {
      try { data = JSON.parse(bodyText); }
      catch { data = bodyText; }
    }
    if (!res.ok) {
      const msg = data?.message || data?.error_description || data?.hint || bodyText || `HTTP ${res.status}`;
      const err = new Error(msg);
      err.status = res.status;
      throw err;
    }
    return data;
  }

  async function signIn(email, password) {
    assertConfigured();
    const res = await fetch(`${cfg.supabaseUrl}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": cfg.supabaseAnonKey
      },
      body: JSON.stringify({ email, password })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error_description || data.msg || "Falha no login.");
    return data;
  }

  function saveTeacherSession(session) {
    localStorage.setItem("modoProvaTeacherSession", JSON.stringify({
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_at: Date.now() + (session.expires_in || 3600) * 1000
    }));
  }

  function getTeacherSession() {
    try {
      const s = JSON.parse(localStorage.getItem("modoProvaTeacherSession") || "null");
      if (!s?.access_token) return null;
      return s;
    } catch {
      return null;
    }
  }

  function clearTeacherSession() {
    localStorage.removeItem("modoProvaTeacherSession");
  }

  async function refreshTeacherSession(refreshToken) {
    assertConfigured();
    const res = await fetch(`${cfg.supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": cfg.supabaseAnonKey
      },
      body: JSON.stringify({ refresh_token: refreshToken })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error_description || "Sessão expirada.");
    saveTeacherSession(data);
    return getTeacherSession();
  }

  async function validTeacherSession() {
    let s = getTeacherSession();
    if (!s) return null;
    if (s.expires_at - Date.now() < 60_000 && s.refresh_token) {
      try { s = await refreshTeacherSession(s.refresh_token); }
      catch { clearTeacherSession(); return null; }
    }
    return s;
  }

  function formatDateTime(value) {
    if (!value) return "—";
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return "—";
    return new Intl.DateTimeFormat("pt-BR", {
      dateStyle: "short", timeStyle: "medium"
    }).format(d);
  }

  function setMessage(el, text, kind = "info") {
    el.textContent = text || "";
    el.className = `message ${kind}`;
    if (!text) el.classList.add("hidden");
  }

  function setConnectionBadge(el) {
    const update = () => {
      const online = navigator.onLine;
      el.textContent = online ? "Online" : "Sem conexão";
      el.className = `badge ${online ? "ok" : "warn"}`;
    };
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    update();
  }

  function downloadText(filename, text, mime = "text/plain;charset=utf-8") {
    const blob = new Blob([text], { type: mime });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  window.ModeProva = {
    cfg, rpc, signIn, saveTeacherSession, getTeacherSession, clearTeacherSession,
    validTeacherSession, formatDateTime, setMessage, setConnectionBadge, downloadText
  };
})();
