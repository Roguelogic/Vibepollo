(() => {
  "use strict";

  const dict = {
    ko: {
      subtitle: "macOS 원격 페어링 콘솔",
      logout: "로그아웃",
      setupTitle: "관리자 계정 설정",
      setupDesc: "원격 웹 페어링 콘솔을 보호할 계정을 생성하세요.",
      username: "사용자 이름",
      password: "비밀번호",
      confirmPassword: "비밀번호 확인",
      createAccount: "계정 생성",
      loginTitle: "로그인",
      loginDesc: "Vibepollo 관리자 계정으로 로그인하세요.",
      signIn: "로그인",
      pinTitle: "기기 페어링 (PIN)",
      pinDesc: "Moonlight / VoidLink 클라이언트에 표시된 4자리 PIN을 입력하세요.",
      pinLabel: "4자리 PIN",
      deviceName: "기기 이름",
      pairDevice: "페어링 완료",
      clientsTitle: "페어링된 기기",
      refresh: "새로고침",
      clientsEmpty: "페어링된 기기가 없습니다.",
      unpair: "페어링 해제",
      hostTitle: "호스트 관리",
      nativeHint: "상세 디스플레이·화질·입력 설정은 Mac의 Vibepollo 네이티브 설정 창(⌘,)에서 관리할 수 있습니다.",
      restartHost: "호스트 재시작",
      pinOk: "기기가 성공적으로 페어링되었습니다.",
      pinFail: "대기 중인 페어링 요청이 없거나 PIN이 일치하지 않습니다.",
      unpairOk: "기기 페어링을 해제했습니다.",
      unpairConfirm: "이 기기의 페어링을 해제할까요?",
      restartConfirm: "Vibepollo 호스트를 재시작할까요?",
      restartOk: "호스트 재시작을 요청했습니다.",
      setupOk: "관리자 계정이 생성되었습니다. 로그인해 주세요.",
      passMismatch: "비밀번호가 일치하지 않습니다.",
      loginFail: "로그인에 실패했습니다. 계정 정보를 확인하세요.",
      reqFail: "요청을 처리하지 못했습니다.",
    },
    en: {
      subtitle: "macOS Remote Pairing Console",
      logout: "Sign Out",
      setupTitle: "Create Admin Account",
      setupDesc: "Set credentials to protect the remote web pairing console.",
      username: "Username",
      password: "Password",
      confirmPassword: "Confirm Password",
      createAccount: "Create Account",
      loginTitle: "Sign In",
      loginDesc: "Sign in with your Vibepollo administrator credentials.",
      signIn: "Sign In",
      pinTitle: "Pair Device (PIN)",
      pinDesc: "Enter the 4-digit PIN shown in Moonlight or VoidLink.",
      pinLabel: "4-Digit PIN",
      deviceName: "Device Name",
      pairDevice: "Pair Device",
      clientsTitle: "Paired Devices",
      refresh: "Refresh",
      clientsEmpty: "No paired devices yet.",
      unpair: "Unpair",
      hostTitle: "Host Controls",
      nativeHint: "For full display, video, and input configuration, open Vibepollo Settings (⌘,) on your Mac.",
      restartHost: "Restart Host",
      pinOk: "Device paired successfully.",
      pinFail: "No pending pairing request matched that PIN.",
      unpairOk: "Device unpaired.",
      unpairConfirm: "Unpair this device?",
      restartConfirm: "Restart the Vibepollo host now?",
      restartOk: "Host restart requested.",
      setupOk: "Account created. Please sign in.",
      passMismatch: "Passwords do not match.",
      loginFail: "Sign in failed. Check your credentials.",
      reqFail: "Request failed.",
    },
  };

  let lang = (navigator.language || "").toLowerCase().startsWith("ko") ? "ko" : "en";
  let csrfToken = "";

  const $ = (id) => document.getElementById(id);
  const t = (key) => (dict[lang] && dict[lang][key]) || dict.en[key] || key;

  function applyLocale() {
    document.documentElement.lang = lang;
    $("lang-toggle").textContent = lang === "ko" ? "EN" : "KO";
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      el.textContent = t(el.dataset.i18n);
    });
  }

  function showBanner(message, isError = false) {
    const el = $("banner");
    el.textContent = message;
    el.className = `banner ${isError ? "err" : "ok"}`;
  }

  function clearBanner() {
    $("banner").className = "banner hidden";
  }

  function showView(name) {
    $("view-setup").classList.toggle("hidden", name !== "setup");
    $("view-login").classList.toggle("hidden", name !== "login");
    $("view-console").classList.toggle("hidden", name !== "console");
    $("logout-btn").classList.toggle("hidden", name !== "console");
  }

  async function ensureCsrfToken() {
    if (csrfToken) return csrfToken;
    const res = await fetch("/api/csrf-token", { credentials: "same-origin" });
    if (res.ok) {
      const data = await res.json();
      if (data && typeof data.csrf_token === "string") {
        csrfToken = data.csrf_token;
      }
    }
    return csrfToken;
  }

  async function apiPost(path, payload) {
    const token = await ensureCsrfToken();
    const headers = { "Content-Type": "application/json" };
    if (token) headers["X-CSRF-Token"] = token;
    const res = await fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers,
      body: JSON.stringify(payload || {}),
    });
    let data = {};
    try {
      data = await res.json();
    } catch (_) {
      // non-JSON response
    }
    return { ok: res.ok, status: res.status, data };
  }

  async function loadClients() {
    const res = await fetch("/api/clients/list", { credentials: "same-origin", cache: "no-store" });
    if (!res.ok) return;
    const data = await res.json();
    const list = $("clients-list");
    list.textContent = "";
    const certs = Array.isArray(data.named_certs) ? data.named_certs : [];
    $("clients-empty").classList.toggle("hidden", certs.length > 0);

    certs.forEach((client) => {
      const li = document.createElement("li");
      li.className = "list-item";

      const info = document.createElement("div");
      const name = document.createElement("div");
      name.className = "client-name";
      name.textContent = client.name || "Unnamed";
      const uuid = document.createElement("div");
      uuid.className = "client-uuid";
      uuid.textContent = client.uuid || "";
      info.append(name, uuid);

      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "btn btn-danger";
      btn.textContent = t("unpair");
      btn.addEventListener("click", async () => {
        if (!window.confirm(t("unpairConfirm"))) return;
        const r = await apiPost("/api/clients/unpair", { uuid: client.uuid });
        if (r.ok && r.data && r.data.status) {
          showBanner(t("unpairOk"));
          await loadClients();
        } else {
          showBanner((r.data && r.data.error) || t("reqFail"), true);
        }
      });

      li.append(info, btn);
      list.appendChild(li);
    });
  }

  async function loadHostMeta() {
    const res = await fetch("/api/config", { credentials: "same-origin", cache: "no-store" });
    if (!res.ok) return;
    const data = await res.json();
    const parts = [];
    if (data.sunshine_name) parts.push(data.sunshine_name);
    if (data.version) parts.push(`v${data.version}`);
    if (parts.length > 0) {
      $("host-meta").textContent = parts.join(" · ");
    }
  }

  async function refreshAuth() {
    const res = await fetch("/api/auth/status", { credentials: "same-origin", cache: "no-store" });
    if (!res.ok) {
      showView("login");
      return;
    }
    const status = await res.json();
    if (!status.credentials_configured) {
      showView("setup");
      return;
    }
    if (status.login_required) {
      showView("login");
      return;
    }
    showView("console");
    await Promise.all([ensureCsrfToken(), loadHostMeta(), loadClients()]);
  }

  $("lang-toggle").addEventListener("click", () => {
    lang = lang === "ko" ? "en" : "ko";
    applyLocale();
    if (!$("view-console").classList.contains("hidden")) {
      loadClients();
    }
  });

  $("setup-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    clearBanner();
    const newUsername = $("setup-user").value.trim();
    const newPassword = $("setup-pass").value;
    const confirmNewPassword = $("setup-confirm").value;
    if (newPassword !== confirmNewPassword) {
      showBanner(t("passMismatch"), true);
      return;
    }
    const r = await apiPost("/api/password", {
      currentUsername: "",
      currentPassword: "",
      newUsername,
      newPassword,
      confirmNewPassword,
    });
    if (r.ok && r.data && r.data.status) {
      showBanner(t("setupOk"));
      csrfToken = "";
      await refreshAuth();
    } else {
      showBanner((r.data && r.data.error) || t("reqFail"), true);
    }
  });

  $("login-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    clearBanner();
    const username = $("login-user").value.trim();
    const password = $("login-pass").value;
    const r = await apiPost("/api/auth/login", { username, password, remember_me: true });
    if (r.ok && r.data && r.data.status) {
      $("login-pass").value = "";
      csrfToken = "";
      await refreshAuth();
    } else {
      showBanner((r.data && r.data.error) || t("loginFail"), true);
    }
  });

  $("pin-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    clearBanner();
    const pin = $("pin-code").value.trim();
    const name = $("pin-name").value.trim();
    const r = await apiPost("/api/pin", { pin, name });
    if (r.ok && r.data && r.data.status) {
      $("pin-code").value = "";
      showBanner(t("pinOk"));
      await loadClients();
    } else {
      showBanner((r.data && r.data.error) || t("pinFail"), true);
    }
  });

  $("refresh-clients").addEventListener("click", () => {
    clearBanner();
    loadClients();
  });

  $("restart-btn").addEventListener("click", async () => {
    if (!window.confirm(t("restartConfirm"))) return;
    clearBanner();
    const r = await apiPost("/api/restart", {});
    if (r.ok) {
      showBanner(t("restartOk"));
    } else {
      showBanner((r.data && r.data.error) || t("reqFail"), true);
    }
  });

  $("logout-btn").addEventListener("click", async () => {
    clearBanner();
    await apiPost("/api/auth/logout", {});
    csrfToken = "";
    await refreshAuth();
  });

  applyLocale();
  refreshAuth();
})();
