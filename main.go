package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"syscall"
	"time"
)

const (
	defaultPort         = "8080"
	defaultSelfMemMB    = 128
	defaultGOMAXPROCS   = 2
	httpDrainTimeout    = 10 * time.Second
	supervisorStopWait  = 8 * time.Second
	edgeKeepAlivePeriod = 15 * time.Second
)

func applyMemoryCeiling(selfMB int) {
	debug.SetMemoryLimit(int64(selfMB) << 20)
	debug.SetGCPercent(100)
}

func applyGOMAXPROCS() int {
	n := defaultGOMAXPROCS
	if v := os.Getenv("BERMUDA_GOMAXPROCS"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			n = parsed
		}
	}
	runtime.GOMAXPROCS(n)
	return n
}

type tcpKeepAliveListener struct {
	*net.TCPListener
}

func (ln tcpKeepAliveListener) Accept() (net.Conn, error) {
	tc, err := ln.AcceptTCP()
	if err != nil {
		return nil, err
	}
	_ = tc.SetKeepAlive(true)
	_ = tc.SetKeepAlivePeriod(edgeKeepAlivePeriod)
	_ = tc.SetNoDelay(true)
	return tc, nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.Println("[Gateway] Initializing BERMUDA Stealth Gateway NG...")

	applyMemoryCeiling(defaultSelfMemMB)
	procs := applyGOMAXPROCS()
	log.Printf("[Runtime] Gateway memory ceiling locked at %dMiB (GOGC=100), GOMAXPROCS=%d", defaultSelfMemMB, procs)

	port := getEnv("PORT", defaultPort)

	// Preflight non-fatal like your original working system
	sup := NewSupervisor()
	if err := sup.Preflight(); err != nil {
		log.Printf("[Gateway] Warning: Supervisor preflight validation issue: %v. Continuing to start...", err)
	}

	gw := NewGateway(sup)

	rootCtx, stopRoot := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stopRoot()

	supErrCh := make(chan error, 1)
	go func() {
		supErrCh <- sup.Run(rootCtx)
	}()

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           gw.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    32 * 1024,
		ConnState:         gw.TrackConnState,
	}

	ln, err := net.Listen("tcp", ":"+port)
	if err != nil {
		log.Fatalf("[Gateway] Fatal: Failed to bind edge listener :%s: %v", port, err)
	}

	tcpListener := &tcpKeepAliveListener{
		TCPListener: ln.(*net.TCPListener),
	}

	serverErrCh := make(chan error, 1)
	go func() {
		log.Printf("[Gateway] Edge listener active on :%s (PID %d, GOMAXPROCS=%d, GOMEMLIMIT=%dMiB, TCP_NODELAY=true)",
			port, os.Getpid(), procs, defaultSelfMemMB)
		if err := srv.Serve(tcpListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErrCh <- err
		}
	}()

	select {
	case err := <-serverErrCh:
		log.Printf("[Gateway] Fatal: HTTP server failure: %v", err)
		gw.SetDraining()
		gw.CloseTunnels()
		sup.Stop(supervisorStopWait)
		os.Exit(1)

	case err := <-supErrCh:
		if err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("[Gateway] Fatal: Supervisor loop halted unexpectedly: %v", err)
			gw.SetDraining()
			gw.CloseTunnels()
			sup.Stop(supervisorStopWait)
			os.Exit(1)
		}

	case <-rootCtx.Done():
		log.Println("[Gateway] Termination signal intercepted. Commencing graceful drain sequence...")
	}

	// 4-stage graceful drain
	gw.SetDraining()
	log.Println("[Gateway] Stage 1/4: /healthz flipped to 503 (traffic shedding)")

	drainCtx, cancelDrain := context.WithTimeout(context.Background(), httpDrainTimeout)
	defer cancelDrain()

	if err := srv.Shutdown(drainCtx); err != nil {
		log.Printf("[Gateway] Stage 2/4 Warning: HTTP server drain timeout exceeded: %v. Forcing socket closure.", err)
		_ = srv.Close()
	} else {
		log.Println("[Gateway] Stage 2/4: All edge HTTP connections drained successfully.")
	}

	log.Println("[Gateway] Stage 3/4: Closing hijacked tunnels & releasing idle loopback sockets...")
	gw.CloseTunnels()
	gw.CloseIdleBackendConns()

	log.Println("[Gateway] Stage 4/4: Teardown child Xray process group...")
	sup.Stop(supervisorStopWait)

	log.Println("[Gateway] BERMUDA Stealth Gateway shutdown complete. Ports released cleanly. Exit 0.")
}
