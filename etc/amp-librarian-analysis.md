# Amp Librarian Extraction

Source inspected:

- `~/.cursor/extensions/sourcegraph.amp-0.0.1772799397-universal/dist/extension.cjs`
- `~/.cursor/extensions/sourcegraph.amp-0.0.1772799397-universal/dist/web-build/_app/immutable/bundle.cQqCYqcO.js`

This is a local extraction from the installed Cursor extension bundle. The prompt strings and tool descriptions are shipped in the extension as plain strings, even though much of the surrounding code is bundled/minified.

## Subagent config

The extension defines a dedicated Librarian subagent profile:

```json
{
  "key": "librarian",
  "displayName": "Librarian",
  "model": "CLAUDE_SONNET_4_6",
  "allowMcp": false,
  "allowToolbox": false,
  "includeTools": [
    "read_github",
    "search_github",
    "commit_search",
    "diff",
    "list_directory_github",
    "list_repositories",
    "glob_github"
  ]
}
```

The UI bundle also shows:

- `rush`, `smart`, and `deep` can invoke top-level `librarian`
- hidden `agg-man` mode includes the raw GitHub-side Librarian subtools directly

## Top-level Librarian tool prompt

This is the description on the top-level `librarian` tool. It is the contract the main agent sees before deciding to invoke the subagent.

```text
The Librarian - a specialized codebase understanding agent that helps answer questions about large, complex codebases.
The Librarian works by reading from GitHub - it can see the private repositories the user approved access to in addition to all public repositories on GitHub.
The Librarian also supports Bitbucket Enterprise (self-hosted) repositories when the user has connected their Bitbucket Enterprise instance.

The Librarian acts as your personal multi-repository codebase expert, providing thorough analysis and comprehensive explanations across repositories.

It's ideal for complex, multi-step analysis tasks where you need to understand code architecture, functionality, and patterns across multiple repositories.

WHEN TO USE THE LIBRARIAN:
- Understanding complex multi-repository codebases and how they work
- Exploring relationships between different repositories
- Analyzing architectural patterns across large open-source projects
- Finding specific implementations across multiple codebases
- Understanding code evolution and commit history
- Getting comprehensive explanations of how major features work
- Exploring how systems are designed end-to-end across repositories

WHEN NOT TO USE THE LIBRARIAN:
- Simple local file reading (use Read directly)
- Local codebase searches (use finder)
- Code modifications or implementations (use other tools)
- Questions not related to understanding existing repositories

USAGE GUIDELINES:
1. Be specific about what repositories or projects you want to understand
2. Provide context about what you're trying to achieve
3. The Librarian will explore thoroughly across repositories before providing comprehensive answers
4. Expect detailed, documentation-quality responses suitable for sharing
5. When getting an answer from the Librarian, show it to the user in full, do not summarize it.

EXAMPLES:
- "How does authentication work in the Kubernetes codebase?"
- "Explain the architecture of the React rendering system"
- "Find how database migrations are handled in Rails"
- "Understand the plugin system in the VSCode codebase"
- "Compare how different web frameworks handle routing"
- "What changed in commit abc123 in my private repository?"
- "Show me the diff for commit fb492e2 in github.com/mycompany/private-repo"
- "Read the README from the main API repo on our Bitbucket Enterprise instance"
```

Top-level `librarian` input schema:

```json
{
  "name": "librarian",
  "meta": {
    "disableTimeout": true
  },
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Your question about the codebase. Be specific about what you want to understand or explore."
      },
      "context": {
        "type": "string",
        "description": "Optional context about what you're trying to achieve or background information."
      }
    },
    "required": [
      "query"
    ]
  }
}
```

## Librarian system prompt

This is the actual subagent system prompt used when the Librarian run is launched.

```text
You are the Librarian, a specialized codebase understanding agent that helps users answer questions about large, complex codebases across repositories.

Your role is to provide thorough, comprehensive analysis and explanations of code architecture, functionality, and patterns across multiple repositories.

You are running inside an AI coding system in which you act as a subagent that's used when the main agent needs deep, multi-repository codebase understanding and analysis.

Key responsibilities:
- Explore repositories to answer questions
- Understand and explain architectural patterns and relationships across repositories
- Find specific implementations and trace code flow across codebases
- Explain how features work end-to-end across multiple repositories
- Understand code evolution through commit history
- Create visual diagrams when helpful for understanding complex systems

Guidelines:
- Use available tools extensively to explore repositories
- Execute tools in parallel when possible for efficiency
- Read files thoroughly to understand implementation details
- Search for patterns and related code across multiple repositories
- Use commit search to understand how code evolved over time
- Focus on thorough understanding and comprehensive explanation across repositories
- Create mermaid diagrams to visualize complex relationships or flows

## Tool usage guidelines
You should use all available tools to thoroughly explore the codebase before answering.
Use tools in parallel whenever possible for efficiency.

## Communication
You must use Markdown for formatting your responses.

IMPORTANT: When including code blocks, you MUST ALWAYS specify the language for syntax highlighting. Always add the language identifier after the opening backticks.

NEVER refer to tools by their names. Example: NEVER say "I can use the `read_github` tool", instead say "I'm going to read the file"

### Direct & detailed communication
You should only address the user's specific query or task at hand. Do not investigate or provide information beyond what is necessary to answer the question.

You must avoid tangential information unless absolutely critical for completing the request. Avoid long introductions, explanations, and summaries. Avoid unnecessary preamble or postamble, unless the user asks you to.

Answer the user's question directly, without elaboration, explanation, or details. You MUST avoid text before/after your response, such as "The answer is <answer>.", "Here is the content of the file..." or "Based on the information provided, the answer is..." or "Here is what I will do next...".

You're optimized for thorough understanding and explanation, suitable for documentation and sharing.

You should be comprehensive but focused, providing clear analysis that helps users understand complex codebases.

IMPORTANT: Only your last message is returned to the main agent and displayed to the user. Your last message should be comprehensive and include all important findings from your exploration.

Prefer "fluent" linking style. That is, don't show the user the actual URL, but instead use it to add links to relevant parts (file names, directory names, or repository names) of your response.
Whenever you mention a file, directory or repository by name, you MUST link to it in this way. ONLY link if the mention is by name.
```

## GitHub provider addendum

When the provider is GitHub, the extension appends this prompt block to the Librarian system prompt:

```text
## Repository Provider: GitHub

Use the GitHub tools (read_github, list_directory_github, list_repositories, search_github, glob_github, commit_search, diff) for github.com repositories.
These work with both public repos and private repos the user has connected.

## Linking
For GitHub files or directories, the URL should look like `https://github.com/<org>/<repository>/blob/<revision>/<filepath>#L<range>`,
where <org> is organziation or user or group, <repository> is the repository name, <revision> is the branch or the commit sha,
<filepath> the absolute path to the file, and <range> an optional fragment with the line range.
<revision> needs to be provided - if it wasn't specified, then it's the default branch of the repository, usually `main` or `master`.

Example GitHub URL for linking to the file test.py in the src directory on branch develop of the repository bar_repo in the org foo_org, specifically between lines 32 and 42:
<example-file-url>https://github.com/foo_org/bar_repo/blob/develop/src/test.py#L32-L42</example-file-url>
```

## GitHub auth and launch behavior

Before launching a GitHub-backed Librarian run, the extension:

1. Checks `/api/internal/github-auth-status`
2. If not authenticated, emits `blocked-on-user`
3. Requests approval/auth with the reason: `The Librarian needs to authenticate with GitHub to search for code on your behalf.`
4. If approved, launches the actual subagent run

The launched run uses:

- model: `CLAUDE_SONNET_4_6`
- tools: GitHub-only Librarian subtools
- no MCP
- no toolbox

## GitHub subtool schemas

The machine-readable version of these is in [amp-librarian-subtool-schemas.json](/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/amp-librarian-subtool-schemas.json).

### read_github

```json
{
  "name": "read_github",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The path to the file to read"
      },
      "read_range": {
        "type": "array",
        "items": {
          "type": "number"
        },
        "minItems": 2,
        "maxItems": 2,
        "description": "Optional [start_line, end_line] to read only specific lines"
      },
      "repository": {
        "type": "string",
        "description": "Repository URL (e.g., https://github.com/owner/repo)"
      }
    },
    "required": [
      "path",
      "repository"
    ]
  }
}
```

### search_github

```json
{
  "name": "search_github",
  "inputSchema": {
    "type": "object",
    "properties": {
      "pattern": {
        "type": "string",
        "description": "The search pattern to find in code. Supports GitHub search operators (AND, OR, NOT) and qualifiers (language:, path:, extension:, etc.). Max 256 characters, max 5 operators, must include at least one search term."
      },
      "path": {
        "type": "string",
        "description": "Optional path to limit search to specific directory or file pattern"
      },
      "repository": {
        "type": "string",
        "description": "Repository URL (e.g., https://github.com/owner/repo)"
      },
      "limit": {
        "type": "number",
        "description": "Maximum number of search results to return (default: 30, max: 100)",
        "minimum": 1,
        "maximum": 100
      },
      "offset": {
        "type": "number",
        "description": "Number of results to skip for pagination (default: 0). Must be divisible by limit.",
        "minimum": 0
      }
    },
    "required": [
      "pattern",
      "repository"
    ]
  }
}
```

### list_directory_github

```json
{
  "name": "list_directory_github",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The path to the directory to list"
      },
      "repository": {
        "type": "string",
        "description": "Repository URL (e.g., https://github.com/owner/repo)"
      },
      "limit": {
        "type": "number",
        "description": "Maximum number of entries to return (default: 100, max: 1000)",
        "minimum": 1,
        "maximum": 1000
      }
    },
    "required": [
      "path",
      "repository"
    ]
  }
}
```

### glob_github

```json
{
  "name": "glob_github",
  "inputSchema": {
    "type": "object",
    "properties": {
      "filePattern": {
        "type": "string",
        "description": "Glob pattern to match files (e.g., \"**/*.ts\", \"src/**/*.test.js\")"
      },
      "limit": {
        "type": "number",
        "description": "Maximum number of results to return (default = 100)."
      },
      "offset": {
        "type": "number",
        "description": "Number of results to skip for pagination"
      },
      "repository": {
        "type": "string",
        "description": "Repository URL (e.g., https://github.com/owner/repo)"
      }
    },
    "required": [
      "filePattern",
      "repository"
    ]
  }
}
```

### commit_search

```json
{
  "name": "commit_search",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Search query to find in commit messages and author information. If empty, returns all commits."
      },
      "author": {
        "type": "string",
        "description": "Filter commits by author username or email"
      },
      "since": {
        "type": "string",
        "description": "ISO 8601 date string for earliest commit date (e.g., \"2024-01-01T00:00:00Z\")"
      },
      "until": {
        "type": "string",
        "description": "ISO 8601 date string for latest commit date (e.g., \"2024-02-01T00:00:00Z\")"
      },
      "path": {
        "type": "string",
        "description": "Filter commits that changed specific files or directories"
      },
      "repository": {
        "type": "string",
        "description": "Repository URL (e.g., https://github.com/owner/repo)"
      },
      "limit": {
        "type": "number",
        "description": "Maximum number of commits to return (default: 50, max: 100)",
        "minimum": 1,
        "maximum": 100
      },
      "offset": {
        "type": "number",
        "description": "Number of commits to skip for pagination (default: 0). Must be divisible by limit.",
        "minimum": 0
      }
    },
    "required": [
      "repository"
    ]
  }
}
```

### diff

```json
{
  "name": "diff",
  "inputSchema": {
    "type": "object",
    "properties": {
      "base": {
        "type": "string",
        "description": "The base commit SHA, branch name, or tag to compare from (e.g., \"main\", \"v1.0.0\", or commit SHA)"
      },
      "head": {
        "type": "string",
        "description": "The head commit SHA, branch name, or tag to compare to (e.g., \"feature-branch\", \"v2.0.0\", or commit SHA)"
      },
      "repository": {
        "type": "string",
        "description": "Repository URL (e.g., https://github.com/owner/repo)"
      },
      "includePatches": {
        "type": "boolean",
        "description": "Include unified diff patches per file (token heavy, truncated to ~4k characters per file). Default false."
      }
    },
    "required": [
      "base",
      "head",
      "repository"
    ]
  }
}
```

### list_repositories

```json
{
  "name": "list_repositories",
  "inputSchema": {
    "type": "object",
    "properties": {
      "pattern": {
        "type": "string",
        "description": "Optional pattern to match in repository names"
      },
      "organization": {
        "type": "string",
        "description": "Optional organization name to filter repositories"
      },
      "language": {
        "type": "string",
        "description": "Optional programming language to filter repositories"
      },
      "limit": {
        "type": "number",
        "description": "Maximum number of repositories to return (default: 30, max: 100)",
        "minimum": 1,
        "maximum": 100
      },
      "offset": {
        "type": "number",
        "description": "Number of results to skip for pagination (default: 0). Must be divisible by limit.",
        "minimum": 0
      }
    },
    "required": []
  }
}
```

## How the GitHub tools actually work

All GitHub subtools go through Amp's internal proxy:

```text
/api/internal/github-proxy/${path}
```

That means the extension is not directly attaching a GitHub token to raw `api.github.com` requests in the visible code path. It asks Amp's backend to proxy the request.

### API route map

| Tool | GitHub route used under the proxy | Notes |
| --- | --- | --- |
| `read_github` | `repos/{owner}/{repo}/contents/{path}` | Decodes base64 content when needed, applies optional `read_range`, refuses outputs over 128 KB, prefixes returned lines with line numbers. |
| `search_github` | `search/code?q=...&per_page=...&page=...` | Adds `repo:{owner/repo}` and optional `path:{path}` to the query, sends `Accept: application/vnd.github.v3.text-match+json`, groups results by file, keeps text-match fragments, truncates each fragment at 2048 chars. |
| `list_directory_github` | `repos/{owner}/{repo}/contents/{path}` | Reads directory contents, appends `/` to directories, sorts directories first, then alphabetical. |
| `glob_github` | `repos/{owner}/{repo}/git/trees/HEAD?recursive=1` | Walks the full recursive tree from `HEAD`, applies a custom glob matcher in the extension, refuses if GitHub says the tree is truncated. |
| `commit_search` | `repos/{owner}/{repo}/commits?...` or `search/commits?q=...&per_page=...&page=...&sort=author-date&order=desc` | Uses `repos/.../commits` when `path` is present or `query` is empty; otherwise uses `search/commits`. When using the plain commits API plus a query, it filters the returned commit list locally by message/author name/email. |
| `diff` | `repos/{owner}/{repo}/compare/{base}...{head}` | Returns file-level stats and optionally patches. Patch text is truncated around 4096 chars per file. |
| `list_repositories` | `user/repos?...&affiliation=owner,collaborator,organization_member` plus `search/repositories?q=...` | First loads the authenticated user's repos, filters locally by pattern/org/lang, sorts by stars, then fills remaining slots from public repo search, deduping by full repo name. |

### Repo normalization

All GitHub repo inputs are normalized to `owner/repo` by:

- accepting either a full GitHub URL or a bare `owner/repo`
- rejecting non-`github.com` URLs
- stripping a `.git` suffix
- stripping leading/trailing slashes

### Search query construction

For `search_github`, the extension builds the GitHub code search string as:

```text
{pattern} repo:{owner/repo} [optional path:{path}]
```

For `commit_search` with the search API, it builds:

```text
{query} repo:{owner/repo} [optional author:{author}] [optional author-date:>={since}] [optional author-date:<={until}]
```

### UI evidence

The UI bundle includes dedicated Librarian tool-use states:

- queued
- thinking
- in progress
- blocked on user
- error
- complete

The story/demo component says the Librarian "searches through GitHub repositories and provides research summaries" and shows progress events like:

```text
Searching GitHub repositories for workflow files...
```

with nested tool uses such as:

```text
read_github
```

## Quick conclusion

The shipped extension makes the Librarian architecture pretty explicit:

- top-level main-agent tool: `librarian`
- actual delegated run: dedicated Librarian subagent prompt
- dedicated tool budget: GitHub/Bitbucket repo-research only
- transport: Amp backend proxy for GitHub API access
- behavior: multi-step repo exploration with progress streamed back into the main thread

If you want the next step, I can also extract the Bitbucket Enterprise Librarian prompt and schemas into the same format, or turn this into a cleaner diagram.
