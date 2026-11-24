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
- **20 questões objetivas**, todas com cinco alternativas (A–E), uma por página.
- **Distribuição:** 5 de Lógica, 5 de HTML/CSS, 5 de Arquitetura e Manutenção e 5 de Planejamento de Carreira/IA.
- **Duração:** 60 minutos, com registro de ocorrências conforme as configurações do professor.
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
- Questões antigas com quatro alternativas são preservadas, mas precisam de uma nova versão com cinco alternativas antes de serem importadas para uma avaliação atual.
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

As novas questões foram **adicionadas apenas ao banco**, para revisão pedagógica antes da seleção. O simulado continua com suas 20 questões anteriores e a prova oficial com suas 40 questões, ambos inativos. A publicação do código não libera nenhuma avaliação.

### Orientação de uso

Acesse `professor.html?avaliacao=simulado`, entre com a conta de professor, procure no Banco de questões por **“Questões autorais — estilo ENEM (revisão 2026)”**, utilize os filtros de disciplina e dificuldade e pré-visualize as alternativas. Ao decidir quais itens serão usados, utilize **Adicionar à avaliação**. A seleção copia o item; a biblioteca permanece intacta.

**Cuidado:** não publicar enunciados e gabaritos no repositório público; o conjunto reside exclusivamente no Supabase. Testes de inclusão e edição realizados em transações revertidas não alteraram as avaliações existentes.
