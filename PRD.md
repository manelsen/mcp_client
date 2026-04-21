# gleam_mcp — Product Requirements Document

**Version:** 0.2.0 (target)
**Status:** Draft
**Owner:** manelsen

---

## 1. Problema

Nenhum cliente MCP existe para Gleam no Hex.pm. Desenvolvedores que constroem agentes de IA em Gleam precisam implementar o protocolo do zero ou abandonar o ecossistema BEAM.

O MCP (Model Context Protocol) da Anthropic está se tornando o padrão de fato para integração de ferramentas em LLMs. Há dezenas de servidores publicados (GitHub, filesystem, Postgres, Slack, browser) e nenhuma biblioteca Gleam os conecta.

---

## 2. Proposta

`gleam_mcp` é o cliente MCP nativo para Gleam: conecta a servidores MCP locais e remotos, descobre ferramentas, e as invoca via JSON-RPC 2.0. A API é ergonômica, o estado é gerenciado por atores OTP, e o comportamento é especificado por testes contra servidores reais.

---

## 3. Usuários-alvo

| Perfil | Necessidade |
|--------|-------------|
| Desenvolvedor de agentes IA em Gleam | Conectar ao ecossistema MCP sem sair do BEAM |
| Autor de framework (ex: Supernova) | Base confiável para integração MCP em camadas superiores |
| Experimentador | Explorar ferramentas MCP de forma interativa num script Gleam |

---

## 4. O que existe hoje (v0.1.0)

### Funciona
- Transporte STDIO: spawna processo externo, comunica via JSON-RPC 2.0 newline-delimited
- Gerenciador multi-servidor com atores OTP
- Handshake MCP completo: `initialize` → `notifications/initialized` → `tools/list`
- Execução de ferramentas via `tools/call`
- Nomes qualificados: `"server_name/tool_name"` para evitar colisões entre servidores
- Validação de versão de protocolo (rejeita versões incompatíveis)
- Evicção automática de servidor morto (crash detection via Erlang port)
- Buffer de linha de 1 MB (suporta payloads grandes)
- JSON escaping correto em strings (aspas, barras, newlines)

### Não existe
- Transporte HTTP+SSE (Streamable HTTP — MCP spec 2025-03-26)
- Suporte a `resources` e `prompts` (só `tools`)
- Reconexão automática após crash do servidor
- Doc comments `///` em todas as funções públicas
- HexDocs navegável
- CHANGELOG.md

---

## 5. Requisitos v0.2.0

### 5.1 Documentação (obrigatório antes de publicar)

- [ ] Todos os tipos e funções públicos com `///` doc comments
- [ ] README orientado ao usuário: instalação → exemplo 10 linhas → referência rápida
- [ ] HexDocs gerado sem avisos (`gleam docs build` limpo)
- [ ] CHANGELOG.md com entrada `0.1.0` e `0.2.0`

### 5.2 Resources (alta prioridade)

MCP `resources` expõem arquivos, dados e contexto que o LLM pode ler. Sem isso, metade dos servidores publicados é inutilizável.

```gleam
// API proposta
pub fn resources(client: Client) -> List(Resource)
pub fn read_resource(client: Client, server: String, uri: String) -> Result(String, String)
```

Protocolo:
- `resources/list` → lista URIs disponíveis
- `resources/read` → lê conteúdo de um URI

### 5.3 Prompts (média prioridade)

MCP `prompts` são templates parametrizados. Menos críticos que resources mas parte da spec.

```gleam
pub fn prompts(client: Client) -> List(Prompt)
pub fn get_prompt(client: Client, server: String, name: String, args: Dict(String, String)) -> Result(String, String)
```

### 5.4 Reconexão automática (alta prioridade)

Hoje: servidor cai → ferramenta some → usuário nunca sabe.
Proposto: backoff exponencial com limite de tentativas configurável.

```gleam
pub type RetryPolicy {
  NoRetry
  Retry(max_attempts: Int, base_delay_ms: Int)
}

// Na ServerConfig:
ServerConfig(
  name: "github",
  command: "npx",
  args: [...],
  env: [...],
  retry: Retry(max_attempts: 3, base_delay_ms: 500),
)
```

### 5.5 Transporte HTTP+SSE (baixa prioridade v0.2, alta v0.3)

O MCP spec 2025-03-26 introduziu Streamable HTTP como transporte alternativo. Servidores cloud (ex: Cloudflare Workers MCP) só falam HTTP.

Requer:
- Dependência `gleam_http` / `gleam_hackney`
- Sessão stateful via `Mcp-Session-Id` header
- SSE para respostas em streaming

**Não bloqueia publicação.** Documentar como limitação conhecida no README.

---

## 6. O que NÃO está no escopo

- **Target JavaScript**: o transporte STDIO usa Erlang ports — fundamentalmente incompatível com Node/Deno. Uma implementação JS-native seria um pacote separado.
- **Servidor MCP** (o lado que responde): este pacote é exclusivamente cliente.
- **Parsing de input schemas**: os schemas JSON Schema dos tools são passados como `String` opaca. Validação é responsabilidade do chamador.
- **Autenticação OAuth**: alguns servidores HTTP MCP usam OAuth. Fora do escopo desta versão.

---

## 7. API pública alvo (v0.2.0)

```gleam
import gleam_mcp
import gleam_mcp/resource.{type Resource}

// Ciclo de vida
gleam_mcp.new() -> Result(Client, actor.StartError)
gleam_mcp.stop(client) -> Nil

// Servidores
gleam_mcp.register(client, config) -> Result(Nil, String)
gleam_mcp.unregister(client, name) -> Result(Nil, String)
gleam_mcp.servers(client) -> List(String)

// Ferramentas
gleam_mcp.tools(client) -> List(Tool)
gleam_mcp.call(client, "server/tool", "{\"key\":\"value\"}") -> Result(String, String)

// Resources (novo em v0.2.0)
gleam_mcp.resources(client) -> List(Resource)
gleam_mcp.read(client, "server", "file:///path/to/file") -> Result(String, String)

// Prompts (novo em v0.2.0)
gleam_mcp.prompts(client) -> List(Prompt)
gleam_mcp.prompt(client, "server", "name", args) -> Result(String, String)
```

---

## 8. Critérios de aceite

### v0.2.0 está pronta para publicação quando:

- [ ] `gleam build` e `gleam test` passam sem avisos
- [ ] `gleam docs build` gera documentação completa (sem funções sem doc)
- [ ] Testes cobrem: tools + resources + prompts com mock server
- [ ] Testes cobrem: reconexão após crash (quando `Retry` configurado)
- [ ] README tem exemplo funcional copiável em menos de 15 linhas
- [ ] CHANGELOG documenta as duas versões
- [ ] Testado manualmente contra: GitHub MCP, filesystem MCP, e um servidor HTTP MCP

---

## 9. Decisões de design abertas

| Questão | Opção A | Opção B | Status |
|---------|---------|---------|--------|
| Resultado de `call` | `String` (JSON bruto) | Tipo estruturado | Manter `String` por flexibilidade |
| Timeout configurável por chamada | Sim (atual) | Global no cliente | Manter por chamada |
| `resources` no mesmo `Client` ou API separada? | Mesmo `Client` | Módulo separado | **Aberto** |
| Comportamento com servidor lento | Timeout fixo | Timeout configurável | **Aberto** |

---

## 10. Referências

- [MCP Specification 2024-11-05](https://spec.modelcontextprotocol.io/specification/2024-11-05/)
- [MCP Specification 2025-03-26](https://spec.modelcontextprotocol.io/specification/2025-03-26/) — introduz HTTP transport
- [MCP Servers (oficial)](https://github.com/modelcontextprotocol/servers)
- [Hex.pm — busca por "mcp"](https://hex.pm/packages?search=mcp) — zero resultados em Gleam
