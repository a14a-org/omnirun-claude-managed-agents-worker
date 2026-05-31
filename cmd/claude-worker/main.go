// Command claude-worker is the host-side poller for Anthropic's self-hosted
// Managed Agents worker integration.
//
// It is a thin supervisor around the Go `ant` CLI. The actual work-queue
// protocol (claim a session, stream tool calls, post results) is implemented by
// `ant beta:worker`. We run it in the container-per-session mode:
//
//	ant beta:worker poll --on-work ./spawn.sh
//
// On each claimed session, `ant` invokes spawn.sh with the per-session env vars
// (ANTHROPIC_SESSION_ID / ANTHROPIC_WORK_ID / ANTHROPIC_BASE_URL) set, plus the
// org-level ANTHROPIC_ENVIRONMENT_KEY / ANTHROPIC_ENVIRONMENT_ID inherited from
// this process's environment. spawn.sh then creates a fresh OmniRun microVM
// sandbox for that session and runs the worker inside it.
//
// This program intentionally does almost nothing itself: it validates that the
// required org-level env vars are present (so misconfiguration fails fast on
// the host rather than inside a sandbox), resolves the spawn script path, and
// execs `ant`. Keeping the integration surface in `ant` + spawn.sh means there
// is no bespoke Go reimplementation of the (beta, evolving) worker protocol to
// maintain.
//
// SECURITY: The org-level ANTHROPIC_ENVIRONMENT_KEY stays on the host and in
// this process. It is forwarded only to `ant` and spawn.sh. The org API key
// (ANTHROPIC_API_KEY) must NOT be set here and must never be passed into a
// sandbox.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
)

// requiredEnv lists the org-level env vars that must be present before we hand
// off to `ant`. Per-session vars (ANTHROPIC_SESSION_ID etc.) are injected by
// `ant` per claimed session and are NOT required up front.
var requiredEnv = []string{
	"ANTHROPIC_ENVIRONMENT_KEY",
	"ANTHROPIC_ENVIRONMENT_ID",
}

func main() {
	var (
		antBin    = flag.String("ant", "ant", "path to the `ant` CLI binary")
		spawnPath = flag.String("spawn", "", "path to spawn.sh (default: ./scripts/spawn.sh relative to CWD)")
	)
	flag.Parse()

	if err := run(*antBin, *spawnPath); err != nil {
		fmt.Fprintln(os.Stderr, "claude-worker:", err)
		os.Exit(1)
	}
}

// missingEnv returns, in order, the names from keys whose value reported by
// lookup is empty. It is a pure helper (lookup is injected) so the
// fail-fast validation can be tested without touching the process environment.
func missingEnv(keys []string, lookup func(string) string) []string {
	var missing []string
	for _, k := range keys {
		if lookup(k) == "" {
			missing = append(missing, k)
		}
	}
	return missing
}

func run(antBin, spawnPath string) error {
	missing := missingEnv(requiredEnv, os.Getenv)
	if len(missing) > 0 {
		return fmt.Errorf("missing required env vars: %v (set them on the host; do NOT set ANTHROPIC_API_KEY here)", missing)
	}

	// Refuse to run if the org API key is present in the environment: it must
	// never be forwarded into sandboxes, and its presence usually signals a
	// misconfiguration where someone exported the wrong credential.
	if os.Getenv("ANTHROPIC_API_KEY") != "" {
		return errors.New("ANTHROPIC_API_KEY is set in the host environment; unset it — the worker uses ANTHROPIC_ENVIRONMENT_KEY only and the API key must never reach a sandbox")
	}

	resolvedSpawn, err := resolveSpawn(spawnPath)
	if err != nil {
		return err
	}

	antExe, err := exec.LookPath(antBin)
	if err != nil {
		return fmt.Errorf("cannot find `ant` binary %q on PATH: %w", antBin, err)
	}

	fmt.Printf("claude-worker: polling with %s, spawn=%s\n", antExe, resolvedSpawn)

	// Hand off to `ant beta:worker poll --on-work <spawn.sh>`. We exec a long
	// running process and stream its stdio; the worker protocol and per-session
	// orchestration live entirely in `ant` + spawn.sh.
	cmd := exec.Command(antExe, "beta:worker", "poll", "--on-work", resolvedSpawn)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start ant beta:worker poll: %w", err)
	}

	// Relay termination signals to ant so it drains in-flight sessions before
	// exiting (ant exits cleanly on SIGTERM/SIGINT). Under systemd the cgroup
	// kill reaches ant directly too; relaying makes drain explicit and also
	// works when run outside systemd.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		if sig, ok := <-sigCh; ok && cmd.Process != nil {
			_ = cmd.Process.Signal(sig)
		}
	}()

	if err := cmd.Wait(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				os.Exit(ws.ExitStatus())
			}
		}
		return fmt.Errorf("ant beta:worker poll failed: %w", err)
	}
	return nil
}

// resolveSpawn locates the spawn script, defaulting to ./scripts/spawn.sh, and
// verifies it exists and is executable.
func resolveSpawn(spawnPath string) (string, error) {
	if spawnPath == "" {
		spawnPath = filepath.Join("scripts", "spawn.sh")
	}
	abs, err := filepath.Abs(spawnPath)
	if err != nil {
		return "", fmt.Errorf("resolve spawn path: %w", err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("spawn script not found at %s: %w", abs, err)
	}
	if info.Mode()&0o111 == 0 {
		return "", fmt.Errorf("spawn script %s is not executable (chmod +x it)", abs)
	}
	return abs, nil
}
