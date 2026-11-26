// CONFIGURAÇÃO DO MODO PROVA
// Use somente a chave pública (publishable) no cliente.
// Presets criados no painel utilizam o parâmetro ?exame=preset-<uuid>.
const MODOPROVA_QUERY = new URLSearchParams(window.location.search);
const MODOPROVA_LEGACY = {
  simulado: "simulado-4bim-1b-2026",
  prova: "prova-4bim-1b-2026"
};
const MODOPROVA_CUSTOM = MODOPROVA_QUERY.get("exame");
window.APP_CONFIG = {
  supabaseUrl: "https://lqfchjfyftfopgzdwggi.supabase.co",
  supabasePublishableKey: "sb_publishable_bmpIRHQSvcGrU6QV62rYvA_w0rec269",
  // URLs malformadas não podem recair silenciosamente na avaliação antiga.
  examSlug: MODOPROVA_QUERY.has("exame")
    ? (/^preset-[0-9a-f]{32}$/.test(MODOPROVA_CUSTOM || "")
      ? MODOPROVA_CUSTOM : "preset-invalido")
    : MODOPROVA_LEGACY[MODOPROVA_QUERY.get("avaliacao")] || "4bim-1b-2026",
  appTitle: "Modo Prova — Técnico em Informática"
};
