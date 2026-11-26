# Modo Prova Web — Ubuntu / Navegador

Aplicação 100% web para avaliações em laboratório. Não exige instalação no computador do aluno.

## O que esta versão faz

- acesso por código individual;
- funciona em Firefox/Chrome/Chromium no Ubuntu;
- tela cheia;
- cronômetro;
- questões em ordem individualizada por tentativa;
- uma questão por vez;
- salvamento automático;
- cache local quando a internet oscila;
- sincronização quando a conexão retorna;
- bloqueio de copiar/colar, menu de contexto e alguns atalhos;
- detecção de saída de aba/tela cheia;
- registro central de ocorrências;
- encerramento automático ao atingir o limite;
- correção automática de questões objetivas;
- painel web do professor;
- exportação CSV;
- nenhum programa precisa ser instalado no laboratório.

## Limitação técnica importante

Uma página web **não consegue impedir o Ubuntu de executar Alt+Tab, abrir outro programa ou usar outro dispositivo**.
Ela consegue detectar a perda de visibilidade/tela cheia e registrar a ocorrência.

Por isso, a segurança depende da combinação:

1. aplicação web;
2. questões/alternativas variadas;
3. tempo de prova;
4. fiscalização;
5. regras claras;
6. registro de eventos.

## Arquivos

- `index.html` — prova do aluno
- `professor.html` — painel do professor
- `assets/config.js` — configuração do Supabase e da prova
- `assets/student.js` — lógica da prova
- `assets/professor.js` — painel
- `assets/styles.css` — interface
- `supabase/schema.sql` — banco e funções
- `supabase/sample_data.sql` — dados de teste
- `supabase/student_import_template.csv` — modelo de lista de estudantes

## 1. Criar o banco no Supabase

1. Crie um projeto em https://supabase.com
2. Abra **SQL Editor**.
3. Execute todo o conteúdo de `supabase/schema.sql`.
4. Execute `supabase/sample_data.sql`.
5. Em **Authentication > Users**, crie o usuário do professor com e-mail e senha.
   - O painel aceita qualquer usuário autenticado do projeto.
   - Não crie contas para os alunos: eles entram por código.

## 2. Configurar a aplicação

No Supabase, acesse **Project Settings > API**.

Copie:
- Project URL
- `anon` public key

Edite `assets/config.js`:

```js
window.APP_CONFIG = {
  supabaseUrl: "https://SEU-PROJETO.supabase.co",
  supabaseAnonKey: "SUA_CHAVE_ANON",
  examSlug: "4bim-1b-2026",
  appTitle: "Modo Prova — Técnico em Informática"
};
```

A chave `anon` pode aparecer no navegador. Ela não é uma senha administrativa.
O esquema bloqueia acesso direto às tabelas e usa funções controladas.

**Nunca coloque `service_role` no site.**

## 3. Testar antes de publicar

Você pode abrir `index.html` diretamente para testar a interface, mas as chamadas ao banco dependem de conexão.

Para um teste mais fiel, publique a pasta inteira em um serviço de hospedagem estática com HTTPS.

Opções comuns:
- GitHub Pages
- Netlify
- Cloudflare Pages
- Vercel (site estático)

O aluno acessará apenas uma URL, por exemplo:

`https://sua-prova.exemplo/`

O professor acessará:

`https://sua-prova.exemplo/professor.html`

## 4. Teste de demonstração

Os códigos criados por `sample_data.sql` são:

- `1B-A001`
- `1B-A002`
- `1B-A003`

Apague/substitua esses registros antes da prova real.

## 5. Cadastrar os estudantes

Cada estudante precisa de:

- `access_code`
- `name`
- `class_group`

Exemplo SQL:

```sql
insert into public.students(access_code,name,class_group) values
('1B-0001','Nome do estudante','1º INF'),
('1B-0002','Outro estudante','1º INF');
```

Não use CPF, matrícula oficial ou outro identificador sensível como código.
Prefira códigos aleatórios ou internos à avaliação.

## 6. Cadastrar questões

Cada questão pertence a uma prova.

Questão objetiva:

```sql
insert into public.questions(
  exam_id,position,type,stem,options,correct_answer,points
)
select
  id, 1, 'objective',
  'Enunciado da questão',
  '[{"key":"A","text":"Alternativa A"},{"key":"B","text":"Alternativa B"}]'::jsonb,
  'B',
  1
from public.exams
where slug='4bim-1b-2026';
```

Questão aberta:

```sql
insert into public.questions(
  exam_id,position,type,stem,options,correct_answer,points
)
select
  id, 2, 'open',
  'Explique...',
  '[]'::jsonb,
  null,
  0
from public.exams
where slug='4bim-1b-2026';
```

Nesta versão, questões abertas aparecem no painel, mas não recebem nota automática.

## 7. Configurar duração e ocorrências

```sql
update public.exams
set duration_minutes = 50,
    max_occurrences = 3,
    is_active = true
where slug = '4bim-1b-2026';
```

Para abrir/fechar por horário:

```sql
update public.exams
set opens_at  = '2026-12-15 07:00:00-03',
    closes_at = '2026-12-15 12:00:00-03'
where slug = '4bim-1b-2026';
```

## 8. Como funciona uma ocorrência

Enquanto a prova está ativa, são observados principalmente:

- aba fica oculta (`visibilitychange`);
- saída do modo tela cheia.

Eventos que acontecem praticamente juntos são deduplicados para evitar que uma única troca de aba conte duas vezes.

Exemplo:
- 1ª ocorrência: registra e avisa;
- 2ª ocorrência: registra e avisa;
- 3ª ocorrência: encerra automaticamente, se `max_occurrences = 3`.

O painel permite ver o horário e a questão em que o evento ocorreu.

## 9. Internet instável

Cada resposta é:
1. guardada no navegador;
2. enviada ao Supabase.

Se a conexão cair, a aplicação mantém a resposta localmente e tenta sincronizar quando a internet voltar.

Antes de usar em prova real, teste no laboratório:
- acesso ao domínio do site;
- acesso a `*.supabase.co`;
- tela cheia no navegador;
- estabilidade do Wi-Fi/rede cabeada;
- relógio dos computadores.

## 10. Recomendações para aplicação real

Faça uma simulação curta com a turma antes da avaliação oficial.

Sugestão:
- 5 questões de treinamento;
- 10 minutos;
- aluno aprende a entrar, responder, voltar e finalizar;
- demonstrar o que acontece quando sai da aba.

Isso reduz ocorrências acidentais no dia da prova.

## 11. Reiniciar tentativa de um aluno

A versão MVP permite uma tentativa por estudante/prova.

Para apagar uma tentativa de teste:

```sql
delete from public.attempts
where id = 'UUID_DA_TENTATIVA';
```

As respostas e os eventos são removidos automaticamente (`ON DELETE CASCADE`).

## 12. Próximas evoluções possíveis

- editor de provas no próprio painel;
- importação de estudantes por CSV;
- banco de questões;
- sorteio de N questões de um banco maior;
- pontuação manual para questões abertas;
- liberação individual de nova tentativa;
- geração de relatório PDF;
- múltiplas turmas e disciplinas;
- histórico de avaliações.


## Atualização — Avaliação bimestral e simulado contextualizados (novembro/2026)

- Executar `migration_005_editor_objetivo_simulado.sql` e, depois, `migration_006_questoes_enem.sql` no Supabase correspondente à **aplicação de provas**. A migração 006 acrescenta cinco alternativas (A–E) e justificativas às questões e preserva a função antiga para compatibilidade com clientes já carregados.
- As avaliações do quarto bimestre são **independentes** da prova de demonstração original. Os slugs são `simulado-4bim-1b-2026` e `prova-4bim-1b-2026`.
- A aplicação usa `?avaliacao=simulado` ou `?avaliacao=prova` ao final da URL de `index.html`; o painel `professor.html` aceita os mesmos parâmetros. Sem parâmetro, continua abrindo a avaliação original `4bim-1b-2026`.
- As novas avaliações são inicialmente criadas **inativas**, para revisão pedagógica e definição das janelas de aplicação. A prova não revela gabarito ao aluno; o simulado libera correção comentada somente após a finalização.
- As perguntas são originais, com textos-base, interpretação, situação-problema e cinco alternativas. Os 40 enunciados e respectivos gabaritos foram cadastrados diretamente no Supabase e não são publicados no repositório público.


### Ajuste da prova por orientação da escola — 18/11/2026

- **Prova bimestral:** 40 questões objetivas contextualizadas, com cinco alternativas e 10 questões por área (Lógica de Programação; HTML/CSS; Arquitetura e Manutenção; Planejamento de Carreira e IA).
- **Simulado:** mantém 20 questões; o banco é independente da prova.
- **Tempo provisório da prova:** 120 minutos para acomodar os enunciados interpretativos; confirmar com a coordenação escolar antes de ativar.
- **Pontuação:** 1 ponto por questão (40 pontos brutos); revisar a conversão para a nota oficial conforme o critério da escola.
- **Segurança:** prova e simulado permanecem inativos e seus enunciados e gabaritos são armazenados somente no Supabase, não neste repositório público.


## Simulado de revisão — 1º de dezembro de 2026

O **Modo Simulado** usa a mesma interface da prova, com banco de questões e tentativas independentes.

- **Aluno:** `https://wes-snk.github.io/aplicacao_modo_prova/?avaliacao=simulado`
- **Professor:** `https://wes-snk.github.io/aplicacao_modo_prova/professor.html?avaliacao=simulado`
- **20 questões objetivas**, com quatro alternativas (A–D), uma por página.
- **Distribuição:** 5 de Lógica, 5 de HTML/CSS, 5 de Arquitetura e Manutenção e 5 de Planejamento de Carreira/IA.
- **Duração:** 120 minutos, com limite de 4 ocorrências, conforme as configurações mais recentes do professor; ambas podem ser ajustadas antes de haver tentativas.
- **Correção pedagógica:** somente após a finalização, com pontuação total, percentual de acertos, gabaritos, justificativas e resumo por disciplina.
- **Controle de aplicação:** simulado permanece **desativado** até revisão e liberação pelo professor para 01/12/2026. A data no título **não ativa automaticamente** a aplicação.
- **Sigilo:** não incluir enunciados, alternativas, gabaritos ou tokens de estudantes no repositório público. Os dados avaliativos são mantidos no Supabase.

O módulo simulado não altera o banco da prova de 40 questões em 03/12/2026.


## Banco reutilizável de questões e controle de tempo — novembro/2026

Migração: `migration_007_banco_questoes_tempo.sql` (já aplicada ao projeto de provas, não ao CulturaFlow).

### Banco de questões

- A seção **Banco de questões**, no painel autenticado do professor, permite **pesquisar por palavras**, **filtrar por disciplina**, **visualizar enunciado/gabarito**, **cadastrar questões próprias** e **adicionar cópias a qualquer avaliação editável**.
- A biblioteca foi inicializada com **65 questões objetivas existentes**: 15 por cada uma das quatro áreas e 5 questões anteriores na categoria Geral.
- Os itens permanecem na biblioteca mesmo que sejam removidos das avaliações. O gatilho de auditoria registra também o conteúdo **antes e depois** de edições, como versões independentes, sem sobrescrever os registros anteriores.
- Os bancos de aplicação e o banco reutilizável têm finalidades distintas: a **prova/simulado** contém suas próprias cópias e tentativas; a **biblioteca** guarda as versões para usos futuros.
- Questões com quatro alternativas (A–D) ou cinco (A–E) são preservadas e podem ser reutilizadas nas avaliações atuais.
- Se já houver uma tentativa registrada, a composição daquela avaliação permanece bloqueada, mas ainda é possível cadastrar novas questões diretamente no banco.
- O banco contém enunciados, alternativas, gabaritos e justificativas **somente no Supabase**. Não publicar dados de questões no GitHub; as funções de consulta/reutilização exigem uma sessão autenticada e não disponibilizam SELECT direto nas tabelas.

### Tempo de aplicação

No painel, **Configurações da avaliação > Duração da avaliação**, escolher:

- 30, 45, **60**, **90**, **120**, 180 ou 240 minutos;
- **Sem limite de tempo** (duração NULL, sem cronômetro e sem encerramento automático por prazo);
- **Outro tempo**, entre 5 e 300 minutos.

O aluno recebe a duração correta nas regras iniciais; quando não existe limite, o cronômetro fica oculto. A detecção de ocorrências e a finalização manual continuam funcionando. Depois que uma avaliação receber tentativas, sua duração e seu modo ficam bloqueados para preservar as condições de aplicação.

### Precauções

- Os bancos atuais das avaliações foram preservados. A alteração de duração só é feita quando o professor clica em **Salvar configurações**; as alterações não salvas não são descartadas pela atualização automática.
- A publicação de código e a aplicação da migração **não ativam** o simulado nem a prova, que permanecem inativos até revisão final.
- Os testes de inclusão e ausência de prazo foram realizados dentro de transações revertidas, sem gerar tentativas ou acrescentar questões às avaliações reais.
- Antes da aplicação com a turma, realizar a homologação funcional no navegador e confirmar o tempo disponível com a escola.


## Questões contextualizadas com leitura e dificuldade — novembro/2026

A migração `migration_008_quatro_alternativas_dificuldade.sql` foi aplicada ao Supabase da aplicação Modo Prova.

### Padrão pedagógico

- Questões autorais, com texto-base e comando interpretativo ou problema aplicado, inspiradas **na estrutura de questões do ENEM**, sem copiar trechos protegidos de provas ou atribuir fontes inexistentes.
- O editor e o banco agora permitem **4 alternativas (A–D)**, novo padrão, ou **5 alternativas (A–E)** para preservar a compatibilidade.
- Campo de dificuldade: **Fácil**, **Média** e **Difícil**; questões anteriores permanecem sem classificação, pois não foram reavaliadas retroativamente.
- Filtros por disciplina, texto e nível de dificuldade; contagem por nível no painel das questões ativas da avaliação.
- Uma questão selecionada do banco mantém seu nível de dificuldade ao ser copiada para uma avaliação.

### Primeiro conjunto de revisão

Foram incluídas **20 questões autorais** no banco, com distribuição:

| Área | Fácil | Média | Difícil | Total |
| --- | ---: | ---: | ---: | ---: |
| Lógica de Programação | 2 | 2 | 1 | 5 |
| HTML/CSS | 2 | 2 | 1 | 5 |
| Arquitetura e Manutenção | 2 | 2 | 1 | 5 |
| Planejamento de Carreira e IA | 2 | 3 | 0 | 5 |
| **Total** | **8** | **9** | **3** | **20** |

O novo conjunto tem cinco gabaritos em cada letra A, B, C e D, questões com justificativa e textos-base próprios. Os 65 itens anteriores foram mantidos, totalizando **85 questões** no banco.

Na criação desse primeiro lote, as questões ficaram apenas no banco para revisão. A seleção definitiva do simulado de 01/12/2026 é documentada na seção de preparação final abaixo. A prova oficial permanece com suas 40 questões, sem alterações, e continua inativa.

### Orientação de uso

Acesse `professor.html?avaliacao=simulado`, entre com a conta de professor, procure no Banco de questões por **“Questões autorais — estilo ENEM (revisão 2026)”**, utilize os filtros de disciplina e dificuldade e pré-visualize as alternativas. Ao decidir quais itens serão usados, utilize **Adicionar à avaliação**. A seleção copia o item; a biblioteca permanece intacta.

**Cuidado:** não publicar enunciados e gabaritos no repositório público; o conjunto reside exclusivamente no Supabase. Testes de inclusão e edição realizados em transações revertidas não alteraram as avaliações existentes.


## Segundo lote de questões contextualizadas — novembro/2026

O banco permanente recebeu **mais 20 questões originais** em estilo interpretativo e contextualizado, classificadas pela origem `Questões autorais — estilo ENEM (revisão 2026, lote 2)`. Os enunciados e gabaritos permanecem exclusivamente no Supabase, não neste repositório público.

| Disciplina | Fáceis | Médias | Difíceis | Total |
| --- | ---: | ---: | ---: | ---: |
| Lógica de Programação | 2 | 2 | 1 | 5 |
| HTML/CSS | 2 | 2 | 1 | 5 |
| Arquitetura e Manutenção | 2 | 3 | 0 | 5 |
| Planejamento de Carreira e IA | 2 | 2 | 1 | 5 |
| **Total** | **8** | **9** | **3** | **20** |

Os assuntos complementam o primeiro lote: tipagem e identificadores, sequenciamento e planilhas, conversão numérica e decisões; navegação, semântica e correções de HTML/CSS; recursos on-board e off-board, fonte de alimentação, cabeamento, CPU/GPU e paginação; carreiras, jogos digitais, computação forense e verificação de imagens sintéticas.

**Total atual do banco: 105 questões** (65 anteriores + 20 do primeiro lote + 20 do segundo). Questões já utilizadas em avaliações não foram alteradas. Ambas as avaliações oficiais permanecem desativadas até liberação do professor.

### Filtros de dificuldade no painel

O painel agora oferece os níveis **Fáceis / Médias / Difíceis / Sem classificação** em dois contextos:

- **Questões da avaliação**: filtro visual da lista e da pré-visualização das questões ativas; não remove nem altera as questões e preserva sua posição original.
- **Banco de questões**: filtro de busca na biblioteca, combinável com disciplina e texto; selecionar uma questão e adicioná-la à avaliação apenas cria uma cópia.

O formulário também permite informar a dificuldade ao criar uma questão. As questões antigas não são classificadas automaticamente. A distribuição de níveis deve ser revisada pelo professor antes da aplicação, pois se trata de classificação pedagógica inicial.

O novo lote foi validado quanto a alternativas A–D, gabarito, justificativas, níveis, distribuição por disciplina e balanceamento das respostas. A homologação funcional no navegador segue recomendada antes da publicação para estudantes.


## Preparação final do simulado de 01/12/2026 — ponderação de dificuldade

**Situação:** composição concluída e testada; **não ativar antes da aplicação com a turma**.

### Distribuição

| Disciplina | Fáceis | Médias | Difíceis | Total |
| --- | ---: | ---: | ---: | ---: |
| Lógica de Programação | 2 | 2 | 1 | 5 |
| HTML/CSS | 2 | 2 | 1 | 5 |
| Arquitetura e Manutenção | 2 | 2 | 1 | 5 |
| Planejamento de Carreira e IA | 2 | 3 | 0 | 5 |
| **Total** | **8** | **9** | **3** | **20** |

- **Proporções:** 40% fáceis, 45% médias, 15% difíceis. A ponderação se refere à quantidade de questões, não à pontuação diferenciada.
- **Pontuação:** 1 ponto por questão; resultado de 0 a 20 pontos, percentual de acertos e correção por disciplina.
- **Alternativas:** A–D, uma resposta correta por questão; cinco respostas corretas em cada letra no conjunto total. Enunciados, gabaritos e justificativas residem apenas no Supabase.
- **Ordem e temas:** posições 1–5: Lógica (binário, sequência, variáveis, planilhas e decisões); 6–10: HTML/CSS (estrutura, cores, estilo inline, imagens e interpretação de código); 11–15: Hardware (RAM/SSD, drivers, cabos, paginação e diagnóstico de GPU); 16–20: Carreiras/IA (jogos, apresentações, forense, imagens sintéticas e impactos ambientais).
- **Tempo e ocorrências:** **120 minutos e limite de 4 ocorrências**, preservados conforme última configuração já encontrada no banco. O professor pode alterar esses valores em **Configurações da avaliação** antes que haja tentativas.
- **Ativação:** o simulado **continua desativado**, sem abertura automática, apesar da data no título. No painel do professor, escolher **Simulado 01/12 (preset)** e usar **Colocar simulado online**, confirmando a ação. Após a aplicação, usar **Tirar simulado do ar**. A opção antiga de marcar **Avaliação ativa** e salvar também continua disponível.
- **Avaliação oficial:** prova bimestral de 40 questões, 120 minutos e configurações próprias; **nenhuma questão ou configuração da prova oficial foi alterada**.

### Preservação e testes

- As 20 perguntas que ocupavam anteriormente o simulado continuam no **banco de questões**; as questões atualmente aplicadas foram selecionadas dentre os dois lotes autorais. Nenhuma questão foi transferida por exclusão do banco.
- O banco contém **105 questões distintas**. A migração `migration_009_normalizacao_fingerprint.sql` corrige a normalização de pontos (1 versus 1,00) nos identificadores de conteúdo; 20 cópias redundantes geradas na substituição foram consolidadas, sem perda de conteúdo distinto.
- **Teste transacional de ponta a ponta pelo backend:** autenticação do aluno fictício, recebimento de 20 itens A–D, início do cronômetro, registro de resposta, envio e resultado comentado de 1/20 concluídos com sucesso. Todos os dados e a ativação provisória do teste foram revertidos (**ROLLBACK**). Não foram deixadas tentativas cadastradas.
- **Homologação visual no navegador:** ainda recomendada antes da aplicação. Evitar realizar teste completo no próprio simulado com um aluno real, pois uma tentativa registrada bloqueia o ajuste posterior da composição.

**Links de aplicação:**
- Professor: https://wes-snk.github.io/aplicacao_modo_prova/professor.html?avaliacao=simulado
- Aluno: https://wes-snk.github.io/aplicacao_modo_prova/?avaliacao=simulado

O limite e a duração atuais podem ser modificados no painel. A escolha de 120 minutos foi preservada, não definida automaticamente pela nova ponderação.

## Preset de publicação rápida do simulado — 24/11/2026

O menu do painel do professor passou a destacar **Simulado 01/12 (preset)**. Ao selecioná-lo e autenticar-se, aparece uma seção **Publicação rápida** com:
- estado atualizado **Fora do ar / Online para alunos**;
- quantidade de questões, tempo e limite de ocorrências salvos no banco;
- botão único de alternância **Colocar simulado online / Tirar simulado do ar**, com confirmação antes da mudança;
- link **Abrir link do aluno**, sem revelar respostas ou configurações internas.

O botão usa a função `public.teacher_set_simulado_online(boolean)`, cuja migração é `migration_010_preset_publicacao_simulado.sql`. Essa função altera **somente `exams.is_active` do slug `simulado-4bim-1b-2026`**, sem editar parâmetros, questões, respostas, tentativas ou a prova oficial. Exige sessão autenticada de professor conforme o mecanismo existente. A liberação é recusada se a composição do preset não corresponder às **20 questões ativas e objetivas de A–D, com justificativa, peso 1, distribuição 8/9/3 e cinco gabaritos em cada alternativa**.

Valores do preset armazenados no banco na implementação: **20 questões, 120 minutos, 4 ocorrências**. O botão usa o tempo e limite já configurados e **não os redefine**, de modo que alterações salvas previamente no formulário permanecem respeitadas. Alterações não salvas são sinalizadas ao professor antes da ação. O formulário é sincronizado com o novo estado para evitar que um salvamento posterior reverta a publicação inadvertidamente.

**Operação no dia 1º de dezembro:** entrar em `professor.html?avaliacao=simulado`, escolher o preset (caso ainda não selecionado) e clicar em **Colocar simulado online**, confirmando. Enviar o link de aluno `index.html?avaliacao=simulado`. Encerrada a aplicação, usar o mesmo botão, agora com o texto **Tirar simulado do ar**.

**Validação:** publicação e desativação por RPC autenticada em transação com ROLLBACK, confirmando preservação da prova de 40 questões, título, tempo, limite e tentativas. O simulado **permaneceu inativo** após os testes. A ativação automática por data não foi solicitada nem implementada; a homologação visual pelo professor continua recomendada.


## Prévia completa do modo aluno — professor (24/11/2026)

No painel autenticado do professor, o botão **Testar como aluno** fica à direita do indicador de conexão, perto de **Sair**. Ele abre uma nova aba:

- `preview-aluno.html?avaliacao=simulado` — prévia do simulado de 01/12/2026;
- `preview-aluno.html?avaliacao=prova` — prévia da prova bimestral;
- `preview-aluno.html?avaliacao=anterior` — prévia da avaliação legada.

**Como usar:** entrar no painel do professor, clicar **Testar como aluno**, manter o nome fictício `PROFESSOR — TESTE`, clicar **Continuar**, aceitar as regras e iniciar. Testar a tela cheia, o cronômetro, a navegação, as alternativas, **Revisar depois**, o resumo de questões pendentes e o botão **Finalizar**. No simulado, a correção e as justificativas também são exibidas após o envio **simulado**.

**Segurança / isolamento:** a página de prévia replica a estrutura HTML do aluno, carrega o mesmo `student.js` e utiliza os estilos compartilhados; o módulo `preview-aluno.js` intercepta **todas as chamadas de aluno** (iniciar, salvar, marcar revisão, registrar ocorrência, enviar e corrigir) e as executa exclusivamente em memória no navegador. As **únicas chamadas reais ao Supabase** são `teacher_dashboard` e `teacher_questions`, exigindo autenticação do professor. A prévia pode ser realizada com a avaliação **inativa**, não consome tentativas, não afeta relatórios nem altera a prova oficial.

A prévia tem um aviso permanente identificando que não é uma aplicação real. Seus dados usam um namespace de cache separado no navegador; o cache de tentativas e respostas reais de estudantes nunca é reutilizado. Atualizar a aba reinicia a simulação. As ocorrências, notas e o tempo são calculados localmente — a experiência visual e a navegação são reais, **mas não se trata de um teste de conectividade, persistência ou controle de aplicação com o backend do aluno**. O desempenho pode diferir de uma tentativa real em laboratório. Recomenda-se homologação em navegador antes de disponibilizar aos estudantes.

O botão só aparece depois do login do professor. As telas de prévia não liberam o simulado nem executam qualquer rotina de publicação; o preset **Colocar simulado online** continua separado.


## Gerenciador de avaliações e presets personalizados — 26/11/2026

### Objetivo

O professor pode criar e reutilizar avaliações sem depender de criação manual de registros no Supabase. O módulo é independente da prova bimestral e do simulado de 01/12/2026. Presets são armazenados como avaliações reais (tabela `public.exams`), com registros de propriedade/arquivamento em `public.exam_presets`. Cada criação inicia **inativa**, sem horário de publicação automático.

**Acesso:** no painel autenticado, abrir **Gerenciar avaliações e presets**, na parte superior.

### Funcionalidades

1. **Novo preset:** título (5 a 160 caracteres), modalidade (prova ou simulado), duração (60, 90, 120, 180, outra entre 5 e 300 minutos, ou sem limite), limite de ocorrências (1 a 20). Após clicar **Criar preset desativado**, a interface abre automaticamente o novo painel.
2. **Começar vazio:** adicionar questões manualmente na seção **Banco de questões** do painel, com busca por palavras, disciplina e dificuldade.
3. **Composição automática:** quando o preset está vazio, o professor pode preencher uma matriz de quatro disciplinas por três dificuldades, indicando quantidades de fáceis, médias e difíceis. O padrão inicial é 20 questões (8 fáceis, 9 médias e 3 difíceis); a matriz pode ser livremente modificada de 1 a 80 questões. A montagem seleciona apenas questões válidas e classificadas do banco; se faltarem itens em alguma categoria, a transação é desfeita sem inclusão parcial.
4. **Duplicar:** qualquer avaliação à qual o professor tem acesso pode servir de modelo (questões e configurações). A cópia recebe identificador e link próprios e fica inativa. Nenhuma tentativa é copiada.
5. **Editar:** abrir a avaliação criada e usar as mesmas opções do painel de professor para configurações, questões, gabaritos e filtros. Regras de bloqueio após o registro de tentativas continuam válidas.
6. **Publicar/retirar do ar:** botões específicos da lista, com confirmação, alteram apenas `is_active`. A publicação exige ao menos uma questão objetiva válida e ativa, respeitando questões voluntariamente desativadas. O simulado original de 01/12 mantém seu botão de publicação rápida independente.
7. **Compartilhar/testar:** a listagem traz **Link do aluno**, **Copiar link** e **Prévia do aluno**. A prévia usa a sessão autenticada do professor e não gera tentativas no banco.
8. **Arquivar/restaurar:** não apaga questões nem resultados; para arquivar, o preset deve estar fora do ar e não pode ter tentativas pendentes. A restauração o retorna à lista utilizável.

### Endereços e arquitetura

Cada preset recebe `slug` de formato `preset-<32 caracteres hexadecimais>`, gerado aleatoriamente no servidor. O parâmetro `exame` permite acessar um preset de forma independente:

- Professor: `professor.html?exame=preset-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
- Aluno: `index.html?exame=preset-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
- Prévia: `preview-aluno.html?exame=preset-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

A aplicação aceita apenas slugs de preset com formato válido, evitando trocar silenciosamente para uma avaliação anterior caso o link esteja incorreto. O servidor também verifica se a avaliação existe e está disponível antes de permitir seu início.

Arquivos principais:
- `presets.js`: listagem, formulário de criação, clonagem, matriz de distribuição, publicação e arquivamento.
- `professor.html`: seção **Gerenciar avaliações e presets** e controles do módulo.
- `professor.js`: eventos de login e navegação para a prévia personalizada, mantendo o gerenciador de questões existente.
- `config.js`: leitura do parâmetro seguro `?exame=`, sem remover os links legados `?avaliacao=simulado` e `?avaliacao=prova`.
- `preview-aluno.js`: suporte à prévia dos novos slugs, com ações locais sem escrita de tentativa.
- `migration_011_gerenciador_presets.sql`: tabela e operações autenticadas.
- `migration_012_publicacao_questoes_ativas.sql`: validação de publicação baseada nas questões efetivamente ativas.

### Integridade e segurança

A tabela de propriedade dos presets está sob RLS, sem acesso direto para usuários `anon` ou `authenticated`. As operações específicas do módulo usam funções autenticadas e verificam `created_by = auth.uid()` nos presets personalizados. As avaliações preexistentes continuam separadas e disponíveis para consulta e duplicação conforme o painel existente. Não publicar gabaritos, dados pessoais, tokens ou enunciados no GitHub.

Foram testados no Supabase, em transações revertidas: criar vazio, montar 20 questões na matriz 8/9/3, publicar, desativar, duplicar, arquivar, restaurar, rejeitar publicação sem questões, ignorar questões marcadas inativas na validação e bloquear a publicação de um preset de outro proprietário. Nenhuma avaliação fictícia ou tentativa foi mantida.

**Validação pendente:** conferência visual em navegador/GitHub Pages, incluindo login e links dinâmicos, antes de aplicar um preset novo a estudantes. Não confundir a prévia em memória com uma tentativa real de homologação do backend. O status dos três exames legados não foi alterado durante a implementação.


## Organização modular do painel do professor — branch de homologação

A página de login `professor.html` foi simplificada: exibe exclusivamente o formulário de autenticação e informações de acesso. Presets, controles, listagem de questões e dados de estudantes somente aparecem após o login, em páginas específicas.

- `painel.html`: acompanhamento da aplicação, turma, autorização individual, ocorrências e resultados.
- `questoes.html`: questões pertencentes à avaliação e banco reutilizável.
- `avaliacoes.html`: preparação de avaliações, presets, regras, tempo e publicação.
- `alunos.html`: cadastro de estudantes, turma e situação cadastral.

Para evitar HTML duplicado, o arquivo `professor-shell.html` reúne a estrutura que os scripts existentes utilizam, e `teacher-pages.js` controla autenticação, navegação e visibilidade da área selecionada. `teacher-login.js` autentica e redireciona para a página solicitada, com validação de rota interna.

A navegação preserva os parâmetros `?avaliacao=simulado`, `?avaliacao=prova` e `?exame=preset-...`. Os presets continuam sendo criados e duplicados na área **Avaliações e presets**, enquanto a edição manual de questões ocorre em **Questões**.

As mudanças estão exclusivamente na branch `feature/sala-espera-monitoramento-gather`, vinculada ao PR em rascunho #2. Não foram integradas à `main`, nem aplicaram alterações ao banco do Modo Prova. Verificações para a aprovação manual: `docs/HOMOLOGACAO_SUPERVISAO.md`.


## Controle de entrada em duas etapas (migração 018)

O modo supervisionado passa a usar **duas autorizações individuais independentes**, gerenciadas na página `painel.html`, na avaliação selecionada:

1. **Permitir sala de espera:** após o aluno informar o nome completo, o professor permite sua entrada no mapa lúdico da escola. Sem essa liberação, o aluno permanece numa tela de espera sem acesso ao pátio, seus avatares nem as questões.
2. **Liberar prova:** o professor libera o acesso às questões daquele aluno. A liberação pode ocorrer antes ou depois da entrada na sala, mas **não substitui a autorização do pátio**. A avaliação também precisa estar publicada.
3. O cronômetro e a tentativa só começam depois que o aluno entra na prova e confirma as regras.

O nome é a única identificação exigida no ingresso. O campo **código individual** e a opção de gerar códigos foram retirados da UI; o banco deixa de exigir códigos e limpa valores previamente emitidos. O endpoint que emite novos códigos é removido e a configuração antiga que permitia obrigatoriedade de código não pode mais ser utilizada.

O professor dispõe de dois botões por estudante, com ações de bloqueio/revogação correspondentes. A opção de liberação coletiva de prova só se aplica aos alunos efetivamente presentes. A supervisão continua opt-in por avaliação; as provas não supervisionadas seguem o fluxo anterior.

**Limitação:** identificação apenas pelo nome não autentica a identidade de quem digita. Em aplicação presencial, o professor deve conferir quem utiliza cada terminal. Nenhum sistema pode afirmar, apenas pelo nome digitado, que a pessoa é de fato aquele aluno.

Arquivo da migração: `migrations/018_duas_permissoes_sem_codigos.sql`. Testes: `tests/supervision-two-gates.sql` e `tests/supervision.test.cjs`.
