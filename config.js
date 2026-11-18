// CONFIGURAÇÃO DO MODO PROVA
// No Supabase, abra o diálogo Connect ou Settings > API Keys.
// Use a Project URL e a PUBLISHABLE KEY (sb_publishable_...).
// Nunca coloque secret key/service_role neste arquivo.
window.APP_CONFIG = {
  supabaseUrl: "https://lqfchjfyftfopgzdwggi.supabase.co",
  supabasePublishableKey: "sb_publishable_bmpIRHQSvcGrU6QV62rYvA_w0rec269",
  // A URL escolhe apenas avaliações cadastradas explicitamente; nunca aceita slugs arbitrários.
  examSlug: ({ simulado: "simulado-4bim-1b-2026", prova: "prova-4bim-1b-2026" })[
    new URLSearchParams(window.location.search).get("avaliacao")
  ] || "4bim-1b-2026",
  appTitle: "Modo Prova — Técnico em Informática"
};
