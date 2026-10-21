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
