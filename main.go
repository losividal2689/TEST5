package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ---------------------------------------------------------------------------
// BERMUDA Stealth Gateway NG — Master Edge Entrypoint & Runtime Orchestrator
// Unified Architecture: cgroup v1/v2 Quota, Runtime Secret Injection, 4-Stage Drain
// ---------------------------------------------------------------------------

const (
	defaultPort            = "8080"
	defaultSelfMemMB       = 128
	defaultGOMAXPROCS      = 2
	defaultXrayConfigPath  = "/app/config.json"
	httpDrainTimeout       = 10 * time.Second
	supervisorStopWait     = 8 * time.Second
	edgeKeepAlivePeriod    = 15 * time.Second
	drainPropagationWindow = 500 * time.Millisecond
)

// applyMemoryCeiling configures Go's runtime memory target (soft limit).
// GOGC=100 paired with this limit prevents GC death spirals while leaving
// ~256MiB for Linux socket/page buffers and kernel overhead.
func applyMemoryCeiling(selfMB int) {
	debug.SetMemoryLimit(int64(selfMB) << 20)
	debug.SetGCPercent(100)
}

// applyGOMAXPROCS dynamically pins the Go scheduler to the container quota.
// Priority: 1. BERMUDA_GOMAXPROCS env -> 2. cgroup v2/v1 quota -> 3. default 2 vCPU.
func applyGOMAXPROCS() int {
	n := 0
	if v := strings.TrimSpace(os.Getenv("BERMUDA_GOMAXPROCS")); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			n = parsed
		}
	}
	if n <= 0 {
		if quota, ok := cgroupCPUQuota(); ok {
			n = int(mathCeil(quota))
			if maxCPU := runtime.NumCPU(); n > maxCPU {
				n = maxCPU
			}
		}
	}
	if n <= 0 {
		n = defaultGOMAXPROCS
	}
	runtime.GOMAXPROCS(n)
	return n
}

// cgroupCPUQuota auto-detects CPU limits from cgroup v2 or v1 hierarchies.
func cgroupCPUQuota() (float64, bool) {
	if rel, ok := cgroupV2Path(); ok {
		base := "/sys/fs/cgroup"
		candidates := []string{base + rel + "/cpu.max", base + "/cpu.max"}
		if rel == "/" || rel == "" {
			candidates = []string{base + "/cpu.max"}
		}
		for _, p := range candidates {
			if data, err := os.ReadFile(p); err == nil {
				fields := strings.Fields(string(data))
				if len(fields) == 2 && fields[0] != "max" {
					quota, err1 := strconv.ParseFloat(fields[0], 64)
					period, err2 := strconv.ParseFloat(fields[1], 64)
					if err1 == nil && err2 == nil && quota > 0 && period > 0 {
						return quota / period, true
					}
				}
				return 0, false
			}
		}
	}

	quotaB, err1 := os.ReadFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
	periodB, err2 := os.ReadFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
	if err1 == nil && err2 == nil {
		quota, e1 := strconv.ParseFloat(strings.TrimSpace(string(quotaB)), 64)
		period, e2 := strconv.ParseFloat(strings.TrimSpace(string(periodB)), 64)
		if e1 == nil && e2 == nil && quota > 0 && period > 0 {
			return quota / period, true
		}
	}
	return 0, false
}

func cgroupV2Path() (string, bool) {
	data, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 3)
		if len(parts) == 3 && parts[0] == "0" && parts[1] == "" {
			return parts[2], true
		}
	}
	return "", false
}

func mathCeil(v float64) float64 {
	if v <= 0 {
		return 0
	}
	i := float64(int(v))
	if i < v {
		return i + 1
	}
	return i
}

// tcpKeepAliveListener tunes accepted client sockets for low-latency line-rate
// streaming and cellular CGNAT persistence without enabling abortive close.
type tcpKeepAliveListener struct {
	*net.TCPListener
}

func (ln tcpKeepAliveListener) Accept() (net.Conn, error) {
	conn, err := ln.AcceptTCP()
	if err != nil {
		return nil, err
	}
	_ = conn.SetKeepAlive(true)
	_ = conn.SetKeepAlivePeriod(edgeKeepAlivePeriod)
	_ = conn.SetNoDelay(true)
	return conn, nil
}

// prepareRuntimeXrayConfig materializes a Railway sensitive secret variable into
// a private ephemeral file (mode 0600) to keep credentials completely out of Git
// and Docker image layers, with transparent fallback to local config paths.
func prepareRuntimeXrayConfig() (func(), error) {
	configJSON, hasSecretJSON := os.LookupEnv("BERMUDA_XRAY_CONFIG_JSON")
	configPath := os.Getenv("BERMUDA_XRAY_CONFIG")

	if hasSecretJSON && strings.TrimSpace(configJSON) != "" {
		trimmedJSON := strings.TrimSpace(configJSON)
		if len(trimmedJSON) > 2<<20 || !json.Valid([]byte(trimmedJSON)) {
			return nil, errors.New("BERMUDA_XRAY_CONFIG_JSON must contain valid JSON under 2 MiB")
		}

		file, err := os.CreateTemp("/tmp", "bermuda-xray-config-*.json")
		if err != nil {
			return nil, fmt.Errorf("create ephemeral Xray config: %w", err)
		}
		path := file.Name()
		cleanup := func() { _ = os.Remove(path) }
		fail := func(err error) (func(), error) {
			_ = file.Close()
			cleanup()
			return nil, err
		}

		if err := file.Chmod(0o600); err != nil {
			return fail(fmt.Errorf("protect ephemeral Xray config permissions: %w", err))
		}
		if _, err := file.WriteString(trimmedJSON); err != nil {
			return fail(fmt.Errorf("write ephemeral Xray config: %w", err))
		}
		if err := file.Close(); err != nil {
			cleanup()
			return nil, fmt.Errorf("close ephemeral Xray config: %w", err)
		}
		if err := os.Setenv("BERMUDA_XRAY_CONFIG", path); err != nil {
			cleanup()
			return nil, fmt.Errorf("set ephemeral Xray config path: %w", err)
		}
		// Erase sensitive JSON from process environment memory
		if err := os.Unsetenv("BERMUDA_XRAY_CONFIG_JSON"); err != nil {
			cleanup()
			return nil, fmt.Errorf("scrub Xray config secret from environment: %w", err)
		}
		return cleanup, nil
	}

	// Fallback discovery: check mounted paths or fallback to standard location
	if configPath == "" {
		if _, err := os.Stat("/run/secrets/bermuda-xray-config.json"); err == nil {
			_ = os.Setenv("BERMUDA_XRAY_CONFIG", "/run/secrets/bermuda-xray-config.json")
		} else {
			_ = os.Setenv("BERMUDA_XRAY_CONFIG", defaultXrayConfigPath)
		}
	}
	return func() {}, nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if err := runGateway(); err != nil {
		log.Printf("[Gateway] Fatal: %v", err)
		os.Exit(1)
	}
}

func runGateway() error {
	log.Println("[Gateway] Initializing BERMUDA Stealth Gateway NG...")

	// 1. Register POSIX termination signals. SIGHUP triggers graceful drain.
	signalCtx, stopSignals := signal.NotifyContext(context.Background(),
		syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stopSignals()
	rootCtx, cancelRoot := context.WithCancel(signalCtx)
	defer cancelRoot()

	// 2. Enforce memory target and pin Go scheduler to container cgroup quota
	applyMemoryCeiling(defaultSelfMemMB)
	procs := applyGOMAXPROCS()
	log.Printf("[Runtime] Gateway memory target=%dMiB (soft), GOMAXPROCS=%d (cgroup auto-tuned)",
		defaultSelfMemMB, procs)

	port := getEnv("PORT", defaultPort)

	// 3. Prepare runtime Xray config from Railway secret or mounted path
	cleanupXrayConfig, err := prepareRuntimeXrayConfig()
	if err != nil {
		return fmt.Errorf("runtime Xray configuration setup failed: %w", err)
	}
	defer cleanupXrayConfig()

	// 4. Instantiate supervisor and run context-aware preflight
	sup := NewSupervisor()
	if err := sup.PreflightContext(rootCtx); err != nil {
		if rootCtx.Err() != nil {
			return nil
		}
		return fmt.Errorf("Xray preflight validation failed: %w", err)
	}

	// 5. Instantiate reverse proxy gateway with 64KiB channel buffer pool
	gw := NewGateway(sup)

	rawListener, err := net.Listen("tcp", ":"+port)
	if err != nil {
		return fmt.Errorf("bind edge listener on :%s: %w", port, err)
	}
	tcpListener, ok := rawListener.(*net.TCPListener)
	if !ok {
		_ = rawListener.Close()
		return errors.New("edge listener is not a TCP listener")
	}
	listener := tcpKeepAliveListener{TCPListener: tcpListener}
	defer listener.Close()

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           gw.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    32 * 1024,
		ConnState:         gw.TrackConnState,
	}

	// 6. Run supervisor in background, decoupled from early signal cancellation
	supervisorCtx, cancelSupervisor := context.WithCancel(context.Background())
	defer cancelSupervisor()
	supErrCh := make(chan error, 1)
	go func() { supErrCh <- sup.Run(supervisorCtx) }()
	<-sup.RunStarted()

	serverErrCh := make(chan error, 1)
	go func() {
		log.Printf("[Gateway] Edge listener active on :%s (PID %d, GOMAXPROCS=%d, memory target=%dMiB, keepalive=%s)",
			port, os.Getpid(), procs, defaultSelfMemMB, edgeKeepAlivePeriod)
		serverErrCh <- srv.Serve(listener)
	}()

	var terminalErr error
	supervisorResultRead := false
	serverResultRead := false

	select {
	case <-rootCtx.Done():
		log.Printf("[Gateway] Termination signal intercepted; commencing ordered 4-stage drain...")
	case serveErr := <-serverErrCh:
		serverResultRead = true
		if !errors.Is(serveErr, http.ErrServerClosed) {
			terminalErr = fmt.Errorf("HTTP server failed: %w", serveErr)
		}
		cancelRoot()
	case supErr := <-supErrCh:
		supervisorResultRead = true
		if rootCtx.Err() == nil {
			if supErr == nil {
				terminalErr = errors.New("supervisor loop exited unexpectedly")
			} else {
				terminalErr = fmt.Errorf("supervisor loop failed: %w", supErr)
			}
		}
		cancelRoot()
	}

	// ---------------------------------------------------------------------------
	// Ordered 4-Stage Graceful Drain State Machine
	// ---------------------------------------------------------------------------

	// Stage 1: Flip /healthz to 503 so Railway edge mesh sheds traffic.
	// Allow 500ms propagation window before closing listeners.
	gw.SetDraining()
	log.Println("[Gateway] Stage 1/4: /healthz flipped to 503 (traffic shedding)")
	if terminalErr == nil {
		time.Sleep(drainPropagationWindow)
	}

	// Stage 2: Drain in-flight non-hijacked HTTP requests up to httpDrainTimeout.
	drainCtx, cancelDrain := context.WithTimeout(context.Background(), httpDrainTimeout)
	if err := srv.Shutdown(drainCtx); err != nil {
		log.Printf("[Gateway] Stage 2/4 Warning: HTTP drain timeout exceeded (%v); forcing socket closure", err)
		_ = srv.Close()
	} else {
		log.Println("[Gateway] Stage 2/4: Ordinary HTTP requests drained successfully")
	}
	cancelDrain()

	// Stage 3: Deterministically force-close active hijacked WebSocket tunnels
	// and release idle loopback transport connections.
	log.Println("[Gateway] Stage 3/4: Closing hijacked tunnels & releasing idle loopback sockets...")
	gw.CloseTunnels()
	gw.CloseIdleBackendConns()

	// Stage 4: Teardown child Xray process group and wait for clean reaping.
	log.Println("[Gateway] Stage 4/4: Teardown child Xray process group...")
	cancelSupervisor()
	sup.Stop(supervisorStopWait)

	if !supervisorResultRead {
		select {
		case supErr := <-supErrCh:
			if terminalErr == nil && supErr != nil {
				terminalErr = fmt.Errorf("supervisor shutdown error: %w", supErr)
			}
		case <-time.After(time.Second):
			log.Printf("[Gateway] Warning: supervisor result channel did not close promptly")
		}
	}

	if !serverResultRead {
		select {
		case serveErr := <-serverErrCh:
			if !errors.Is(serveErr, http.ErrServerClosed) && terminalErr == nil {
				terminalErr = fmt.Errorf("HTTP server shutdown error: %w", serveErr)
			}
		case <-time.After(time.Second):
			_ = listener.Close()
		}
	}

	log.Println("[Gateway] BERMUDA Stealth Gateway shutdown complete. Ports released cleanly. Exit 0.")
	return terminalErr
}
