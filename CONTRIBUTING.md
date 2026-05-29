# Contributing

Thanks for your interest in improving the OmniRun worker for Claude Managed
Agents.

## Developer Certificate of Origin (DCO)

All contributions require a sign-off certifying that you wrote the patch (or
otherwise have the right to submit it under the project's license). We use the
[Developer Certificate of Origin](https://developercertificate.org/) 1.1.

Add a `Signed-off-by` line to every commit:

```
Signed-off-by: Your Name <you@example.com>
```

Git can add this automatically:

```bash
git commit -s -m "your message"
```

Pull requests without a DCO sign-off on each commit cannot be merged.

## Ground rules

- Keep `cmd/claude-worker` standalone — stdlib only, no third-party imports.
- Keep security claims honest. Do not add per-domain egress, compliance, or
  certification claims that the code does not actually enforce.
- Run `go build ./...` and `go vet ./...` before opening a PR.
- Shell scripts should pass `shellcheck`.
