(() => {
  "use strict";

  const {
    cfg, rpc, signIn, saveTeacherSession, validTeacherSession,
    clearTeacherSession, formatDateTime, setMessage, setConnectionBadge, downloadText
  } = window.ModeProva;

  const $ = id => document.getElementById(id);
  let session = null;
  let dashboardData = null;
  let pollTimer = null;
  let resetTarget = null;
  let resumeTarget = null;

  function showLogin() {
    $("teacherLogin").classList.remove("hidden");
    $("teacherDashboard").classList.add("hidden");
    $("btnLogout").classList.add("hidden");
    if (pollTimer) clearInterval(pollTimer);
  }

  function showDashboard() {
    $("teacherLogin").classList.add("hidden");
    $("teacherDashboard").classList.remove("hidden");
    $("btnLogout").classList.remove("hidden");
  }

  async function teacherRpc(name, args = {}) {
    session = await validTeacherSession();
    if (!session) throw new Error("Sessão expirada.");
    return rpc(name, args, session.access_token);
  }

  async function login() {
    const email = $("teacherEmail").value.trim();
    const password = $("teacherPassword").value;
    if (!email || !password) {
      setMessage($("teacherLoginMessage"), "Informe e-mail e senha.", "warn");
      return;
    }
    $("btnTeacherLogin").disabled = true;
    try {
      const s = await signIn(email, password);
      saveTeacherSession(s);
      session = await validTeacherSession();
      setMessage($("teacherLoginMessage"), "", "info");
      showDashboard();
      await refreshDashboard();
      startPolling();
    } catch (err) {
      setMessage($("teacherLoginMessage"), "Falha no login. Verifique as credenciais.", "error");
    } finally {
      $("btnTeacherLogin").disabled = false;
    }
  }

  function statusLabel(status) {
    return {
      ready: "Preparada",
      in_progress: "Em andamento",
      submitted: "Finalizada",
      auto_submitted: "Encerrada automaticamente"
    }[status] || status;
  }

  function statusClass(status) {
    if (status === "in_progress") return "pill info";
    if (status === "submitted") return "pill ok";
    if (status === "auto_submitted") return "pill danger";
    return "pill";
  }

  async function refreshDashboard() {
    try {
      const data = await teacherRpc("teacher_dashboard", { p_exam_slug: cfg.examSlug });
      dashboardData = data;
      renderDashboard(data);
      $("dashboardMessage").textContent = `Atualizado em ${new Date().toLocaleTimeString("pt-BR")}.`;
    } catch (err) {
      if (String(err.message).includes("Sessão")) {
        clearTeacherSession();
        showLogin();
        return;
      }
      $("dashboardMessage").textContent = "Não foi possível atualizar o painel.";
    }
  }

  function renderDashboard(data) {
    $("teacherExamLabel").textContent = data.exam_title ? ` — ${data.exam_title}` : "";
    $("dashboardTitle").textContent = data.exam_title || "Avaliação";
    $("dashboardMeta").textContent =
      `${data.duration_minutes} min • limite de ${data.max_occurrences} ocorrência(s) • ${data.question_count} questão(ões)`;

    $("examTitleInput").value = data.exam_title || "";
    $("examDurationInput").value = data.duration_minutes ?? 50;
    $("examOccurrencesInput").value = data.max_occurrences ?? 3;
    $("examActiveInput").checked = !!data.is_active;
    $("examActiveBadge").textContent = data.is_active ? "Ativa" : "Inativa";
    $("examActiveBadge").className = data.is_active ? "pill ok" : "pill danger";

    const rows = data.attempts || [];
    $("statTotal").textContent = rows.length;
    $("statProgress").textContent = rows.filter(r => r.status === "in_progress").length;
    $("statFinished").textContent = rows.filter(r => ["submitted","auto_submitted"].includes(r.status)).length;
    $("statViolations").textContent = rows.filter(r => (r.occurrences || 0) > 0).length;

    const tbody = $("attemptsTable").querySelector("tbody");
    tbody.textContent = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");

      const tdName = document.createElement("td");
      tdName.textContent = r.student_name;

      const tdClass = document.createElement("td");
      tdClass.textContent = r.class_group || "—";

      const tdStatus = document.createElement("td");
      const pill = document.createElement("span");
      pill.className = statusClass(r.status);
      pill.textContent = statusLabel(r.status);
      tdStatus.appendChild(pill);

      const tdStart = document.createElement("td");
      tdStart.textContent = formatDateTime(r.started_at);

      const tdSubmit = document.createElement("td");
      tdSubmit.textContent = formatDateTime(r.submitted_at);

      const tdScore = document.createElement("td");
      tdScore.textContent = r.score === null || r.score === undefined
        ? "—"
        : `${Number(r.score).toFixed(1)} / ${Number(r.max_score).toFixed(1)}`;

      const tdOcc = document.createElement("td");
      tdOcc.textContent = String(r.occurrences || 0);

      const tdAction = document.createElement("td");
      tdAction.className = "row-actions";

      const btn = document.createElement("button");
      btn.className = "small secondary";
      btn.textContent = "Detalhes";
      btn.addEventListener("click", () => openDetail(r.attempt_id));

      if (r.status === "in_progress") {
        const resumeBtn = document.createElement("button");
        resumeBtn.className = "small secondary";
        resumeBtn.textContent = r.resume_allowed ? "Retomada liberada" : "Continuar de onde parou";
        resumeBtn.disabled = !!r.resume_allowed;
        resumeBtn.title = r.resume_allowed
          ? "O aluno já pode entrar novamente pelo nome para continuar."
          : "Preserva respostas e tempo já consumido, mas invalida a sessão anterior.";
        resumeBtn.addEventListener("click", () => openResumeAttempt(r));
        tdAction.appendChild(resumeBtn);
      }

      const retryBtn = document.createElement("button");
      retryBtn.className = "small danger";
      retryBtn.textContent = "Nova tentativa (do zero)";
      retryBtn.title = "Apaga a tentativa atual e permite que o aluno recomece do zero.";
      retryBtn.addEventListener("click", () => openResetAttempt(r));

      tdAction.append(btn, retryBtn);

      tr.append(tdName, tdClass, tdStatus, tdStart, tdSubmit, tdScore, tdOcc, tdAction);
      tbody.appendChild(tr);
    });
  }

  async function openDetail(attemptId) {
    try {
      const data = await teacherRpc("teacher_attempt_detail", { p_attempt_id: attemptId });
      $("detailStudent").textContent = data.student_name;
      $("detailMeta").textContent =
        `${data.class_group || "Sem turma"} • ${statusLabel(data.status)} • ocorrências: ${data.occurrences}`;

      const answers = $("detailAnswers");
      answers.textContent = "";
      (data.answers || []).forEach((a, idx) => {
        const box = document.createElement("div");
        box.className = "answer-detail";
        const h = document.createElement("strong");
        h.textContent = `${idx + 1}. ${a.stem}`;
        const p = document.createElement("p");
        if (a.type === "objective") {
          const chosen = a.answer?.value ?? "Sem resposta";
          p.textContent = `Resposta: ${chosen} • Gabarito: ${a.correct_answer ?? "—"}`;
        } else {
          p.textContent = `Resposta: ${a.answer?.text || "Sem resposta"}`;
        }
        box.append(h, p);
        answers.appendChild(box);
      });

      const evBody = $("detailEvents");
      evBody.textContent = "";
      (data.events || []).forEach(e => {
        const tr = document.createElement("tr");
        [formatDateTime(e.occurred_at), e.event_type, e.counted ? "Sim" : "Não", e.question_position || "—"]
          .forEach(v => {
            const td = document.createElement("td");
            td.textContent = String(v);
            tr.appendChild(td);
          });
        evBody.appendChild(tr);
      });

      $("detailModal").classList.remove("hidden");
    } catch {
      alert("Não foi possível carregar os detalhes.");
    }
  }

  async function saveExamSettings() {
    const title = $("examTitleInput").value.trim();
    const duration = Number($("examDurationInput").value);
    const maxOccurrences = Number($("examOccurrencesInput").value);
    const isActive = $("examActiveInput").checked;

    if (!title) {
      $("settingsMessage").textContent = "Informe um título para a avaliação.";
      return;
    }
    if (!Number.isInteger(duration) || duration < 5 || duration > 300) {
      $("settingsMessage").textContent = "A duração deve estar entre 5 e 300 minutos.";
      return;
    }
    if (!Number.isInteger(maxOccurrences) || maxOccurrences < 1 || maxOccurrences > 20) {
      $("settingsMessage").textContent = "O limite de ocorrências deve estar entre 1 e 20.";
      return;
    }

    $("btnSaveSettings").disabled = true;
    $("settingsMessage").textContent = "Salvando…";
    try {
      await teacherRpc("teacher_update_exam_settings", {
        p_exam_slug: cfg.examSlug,
        p_title: title,
        p_duration_minutes: duration,
        p_max_occurrences: maxOccurrences,
        p_is_active: isActive
      });
      $("settingsMessage").textContent = "Configurações salvas.";
      await refreshDashboard();
    } catch (err) {
      $("settingsMessage").textContent = "Não foi possível salvar as configurações.";
    } finally {
      $("btnSaveSettings").disabled = false;
    }
  }

  function openResumeAttempt(row) {
    resumeTarget = row;
    $("resumeAttemptText").textContent =
      `Liberar ${row.student_name} para continuar a tentativa atual de onde parou?`;
    $("resumeAttemptModal").classList.remove("hidden");
  }

  function closeResumeAttempt() {
    resumeTarget = null;
    $("resumeAttemptModal").classList.add("hidden");
  }

  async function confirmResumeAttempt() {
    if (!resumeTarget) return;
    const target = resumeTarget;
    $("btnConfirmResume").disabled = true;
    try {
      await teacherRpc("teacher_allow_resume_attempt", {
        p_attempt_id: target.attempt_id
      });
      closeResumeAttempt();
      await refreshDashboard();
      $("dashboardMessage").textContent =
        `Continuação liberada para ${target.student_name}. O aluno deve entrar novamente pelo nome.`;
    } catch (err) {
      $("resumeAttemptText").textContent =
        String(err.message).includes("Tempo encerrado")
          ? "O tempo original desta tentativa já terminou; não é possível retomá-la."
          : "Não foi possível liberar a continuação. Atualize o painel e tente novamente.";
    } finally {
      $("btnConfirmResume").disabled = false;
    }
  }

  function openResetAttempt(row) {
    resetTarget = row;
    $("resetAttemptText").textContent =
      `Deseja iniciar uma nova tentativa do zero para ${row.student_name}?`;
    $("resetAttemptModal").classList.remove("hidden");
  }

  function closeResetAttempt() {
    resetTarget = null;
    $("resetAttemptModal").classList.add("hidden");
  }

  async function confirmResetAttempt() {
    if (!resetTarget) return;
    const target = resetTarget;
    $("btnConfirmReset").disabled = true;
    try {
      await teacherRpc("teacher_reset_attempt", {
        p_attempt_id: target.attempt_id
      });
      closeResetAttempt();
      await refreshDashboard();
      $("dashboardMessage").textContent =
        `Nova tentativa do zero liberada para ${target.student_name}.`;
    } catch {
      $("resetAttemptText").textContent =
        "Não foi possível liberar a nova tentativa. Atualize o painel e tente novamente.";
    } finally {
      $("btnConfirmReset").disabled = false;
    }
  }

  function csvEscape(v) {
    const s = String(v ?? "");
    return `"${s.replaceAll('"', '""')}"`;
  }

  function exportCsv() {
    if (!dashboardData) return;
    const lines = [
      ["Estudante","Turma","Status","Inicio","Envio","Nota","Maximo","Ocorrencias"].map(csvEscape).join(",")
    ];
    for (const r of dashboardData.attempts || []) {
      lines.push([
        r.student_name, r.class_group, statusLabel(r.status),
        r.started_at || "", r.submitted_at || "", r.score ?? "", r.max_score ?? "", r.occurrences || 0
      ].map(csvEscape).join(","));
    }
    downloadText(`resultado-${cfg.examSlug}.csv`, "\ufeff" + lines.join("\n"), "text/csv;charset=utf-8");
  }

  function startPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(refreshDashboard, 5000);
  }

  async function boot() {
    setConnectionBadge($("teacherConnectionBadge"));
    $("btnTeacherLogin").addEventListener("click", login);
    $("teacherPassword").addEventListener("keydown", e => { if (e.key === "Enter") login(); });
    $("btnLogout").addEventListener("click", () => {
      clearTeacherSession();
      session = null;
      showLogin();
    });
    $("btnRefresh").addEventListener("click", refreshDashboard);
    $("btnExportCsv").addEventListener("click", exportCsv);
    $("btnSaveSettings").addEventListener("click", saveExamSettings);
    $("btnCancelResume").addEventListener("click", closeResumeAttempt);
    $("btnConfirmResume").addEventListener("click", confirmResumeAttempt);
    $("btnCancelReset").addEventListener("click", closeResetAttempt);
    $("btnConfirmReset").addEventListener("click", confirmResetAttempt);
    $("btnCloseDetail").addEventListener("click", () => $("detailModal").classList.add("hidden"));

    session = await validTeacherSession();
    if (session) {
      showDashboard();
      await refreshDashboard();
      startPolling();
    } else {
      showLogin();
    }
  }

  boot();
})();
