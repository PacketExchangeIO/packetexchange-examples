# Contributing

Thank you for helping improve the PacketExchange API examples. Bug reports, fixes and
clearer explanations are welcome.

## Before you start

- For a bug, open an issue naming the example, the language and what went wrong. Remove API
  keys, webhook secrets, wallet keys, phone numbers and other personal data first.
- For a new example or language, open an issue to discuss it before sending a pull request.
- Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
- Questions about your account, billing or the API itself go to [support@packetexchange.io](mailto:support@packetexchange.io).

## Ground rules

- **Never call the live API from tests.** It costs money and sends real messages. Every
  example runs in CI against the [mock API](mock).
- Follow [CONVENTIONS.md](CONVENTIONS.md): the same folder names, arguments, output lines,
  error handling and exit codes in every language.
- Keep each example self-contained and short. Comments explain why, not what.
- Show only transactional, consented messaging and calling.
- API keys come from `PACKETEXCHANGE_API_KEY` only. Never commit a key, secret or `.env` file.
- Actions that spend money outside the example's main purpose must require `--confirm`.

## Development setup

Node.js 22 is needed for the mock API. Then, for the language you are changing:

| Language | Install | Lint |
| --- | --- | --- |
| curl | `curl`, `jq`, `openssl` | `shellcheck -x -P SCRIPTDIR curl/*/example.sh` |
| Node.js | `cd node && npm ci` | `npm run lint` |
| Python | `pip install -r python/requirements.txt ruff` | `cd python && ruff check . && ruff format --check .` |
| PHP | PHP 8.3 with the `curl` extension | `php -l <file>` |
| Go | Go 1.23 | `cd go && go vet ./...` |
| Java | Java 17 and Maven: `cd java && mvn -q dependency:copy-dependencies` | `javac -cp 'target/dependency/*' -d /tmp/javac <example>/Main.java` |
| C# | .NET 8 SDK | `dotnet build csharp/<example>` |
| Ruby | Ruby 3.2: `cd ruby && bundle install` | `ruby -wc <file>` |

Run a language's examples against the mock, exactly as CI does:

```bash
scripts/with-mock.sh node/run-examples.sh
```

## Making a change

1. Create a branch from `main`.
2. Make the change in every language that has the example, so they stay in step.
3. Update the example's README if its behaviour, arguments or costs changed.
4. If the example calls a new endpoint, add it to `mock/server.mjs` with the same
   validation and response shape as the real API, and add a case to each `run-examples.sh`.
5. Lint and run the examples against the mock.
6. Open a pull request and fill in the template.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
