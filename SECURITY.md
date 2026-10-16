# Security Policy

## Supported Versions

Only the latest commit on the `master` branch is supported for security updates.

| Branch / Version | Supported          |
| ---------------- | ------------------ |
| `master`         | :white_check_mark: |
| Older commits    | :x:                |

---

## Reporting a Vulnerability

If you discover a security vulnerability or security weakness in this repository or its autonomous agent workflows, **do not open a public issue**.

Please report the vulnerability responsibly via:
1. **GitHub Private Vulnerability Reporting**: Use the **Security** tab $\rightarrow$ **Report a vulnerability** on GitHub.
2. **Email**: Contact Ferenc Klein directly at `ferenc.klein.pe@gmail.com` with the subject `[SECURITY] ai-pipeline vulnerability report`.

Please include:
- A description of the issue and potential impact.
- Step-by-step instructions or proof-of-concept to reproduce the vulnerability.
- Any suggested remediations or workarounds.

You will receive an acknowledgment within 48 hours and regular updates until resolution.

---

## Autonomous Pipeline Security Guardrails

When operating this autonomous agent pipeline on public repositories, maintainers must adhere to the following security best practices:

### 1. Prompt Injection & Untrusted Issue Gating
- Autonomous agents (`role-product-manager`, `role-implementer`, etc.) process natural language text from GitHub issues and pull requests.
- **Never allow untrusted community issues to enter the pipeline automatically.**
- Require project maintainers to triage, review, and manually advance external issues to the `PM` or `Ready` columns.

### 2. GitHub Bot Token Least Privilege
- The bot account or GitHub App (`gh` / `gh-bot`) used by polling tools should operate under strict **least-privilege** permissions:
  - **Issues & Pull Requests**: Read and Write.
  - **Projects (v2)**: Read and Write.
  - **Workflows / Admin / Organization**: **No Access**.
- Never store secrets or GitHub PATs in `.project-config.json` or committed files. Use local environment variables or secure credential helpers.

### 3. Worktree & Local Command Sandboxing
- Implementer and QA roles execute builds and tests (`npm test`, `npm run build`, `pytest`, etc.).
- When testing pull requests from external forks, execute runs inside containerized or sandbox environments to prevent malicious code execution during test execution.
