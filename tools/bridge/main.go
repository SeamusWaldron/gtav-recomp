// Command bridge serves the Mac's checked game folder to the Vision Pro app, which fetches byte
// ranges on demand and caches them (docs/BRIDGE.md). Read-only; standard library only.
//
//	cd tools/bridge && go run . [-dir "<game folder>"] [-addr :7360] [-v]
package main

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"
)

// The roots the app mounts: data/game (game:), data/update (update:), data/user (content).
var roots = []string{"game", "update", "user"}

type server struct {
	data    string // <game folder>/data
	verbose bool

	requests atomic.Int64
	bytes    atomic.Int64
}

func main() {
	dir := flag.String("dir", "", "game folder (default: the GTAV.app GameFolder setting)")
	addr := flag.String("addr", ":7360", "listen address")
	verbose := flag.Bool("v", false, "log every request")
	flag.Parse()

	if *dir == "" {
		out, err := exec.Command("defaults", "read", "io.github.gtav-recomp", "GameFolder").Output()
		if err != nil {
			log.Fatal("no -dir given and no GameFolder setting; pass -dir \"<game folder>\"")
		}
		*dir = strings.TrimSpace(string(out))
	}
	s := &server{data: filepath.Join(*dir, "data"), verbose: *verbose}
	if _, err := os.Stat(filepath.Join(s.data, "installed.txt")); err != nil {
		log.Fatalf("no checked install in %s (data/installed.txt missing; is the drive mounted?)", *dir)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/manifest", s.manifest)
	mux.HandleFunc("GET /v1/file/{root}/{path...}", s.file)
	hs := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout: 5 * time.Minute}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	log.Printf("serving %s (read-only) on port %d", s.data, port)
	if name, err := exec.Command("scutil", "--get", "LocalHostName").Output(); err == nil {
		log.Printf("  app flag: --bridge_url=http://%s.local:%d", strings.TrimSpace(string(name)), port)
	}
	for _, ip := range lanAddrs() {
		log.Printf("  or:       --bridge_url=http://%s:%d", ip, port)
	}
	log.Printf("anyone on this network can read the game data while this runs; use your own network")
	go s.report()
	log.Fatal(hs.Serve(ln))
}

// manifest lists every file and directory under the roots: "F|D\troot\tsize\tmtime_ns\tpath\n",
// paths relative to the root with '/' separators. Hidden entries are skipped.
func (s *server) manifest(w http.ResponseWriter, r *http.Request) {
	var b strings.Builder
	for _, root := range roots {
		base := filepath.Join(s.data, root)
		var lines []string
		err := filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if p == base {
				return nil
			}
			if strings.HasPrefix(d.Name(), ".") {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			rel, _ := filepath.Rel(base, p)
			rel = filepath.ToSlash(rel)
			if d.IsDir() {
				lines = append(lines, fmt.Sprintf("D\t%s\t0\t0\t%s\n", root, rel))
				return nil
			}
			if !d.Type().IsRegular() {
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			lines = append(lines, fmt.Sprintf("F\t%s\t%d\t%d\t%s\n", root, info.Size(),
				info.ModTime().UnixNano(), rel))
			return nil
		})
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		sort.Strings(lines)
		for _, l := range lines {
			b.WriteString(l)
		}
	}
	body := b.String()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.Write([]byte(body))
	log.Printf("manifest -> %s", r.RemoteAddr)
}

// file serves one byte range of a file (http.ServeContent handles Range and sets Content-Length).
func (s *server) file(w http.ResponseWriter, r *http.Request) {
	root, rel := r.PathValue("root"), r.PathValue("path")
	if !isRoot(root) || rel == "" || !fs.ValidPath(rel) || hasHidden(rel) {
		http.NotFound(w, r)
		return
	}
	base := filepath.Join(s.data, root)
	full := filepath.Join(base, filepath.FromSlash(rel))
	// Refuse symlinks that leave the root.
	real, err := filepath.EvalSymlinks(full)
	realBase, err2 := filepath.EvalSymlinks(base)
	if err != nil || err2 != nil || !strings.HasPrefix(real, realBase+string(filepath.Separator)) {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(real)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	cw := &countingWriter{ResponseWriter: w}
	http.ServeContent(cw, r, path.Base(rel), info.ModTime(), f)
	s.requests.Add(1)
	s.bytes.Add(cw.n)
	if s.verbose {
		log.Printf("%s %s/%s %s -> %d bytes", r.RemoteAddr, root, rel, r.Header.Get("Range"), cw.n)
	}
}

// report logs throughput every 10 s while there is traffic.
func (s *server) report() {
	var lastReq, lastBytes int64
	for range time.Tick(10 * time.Second) {
		req, b := s.requests.Load(), s.bytes.Load()
		if req == lastReq {
			continue
		}
		log.Printf("%d requests, %.1f MB in the last 10 s (%.1f MB/s); %.1f MB total",
			req-lastReq, float64(b-lastBytes)/1e6, float64(b-lastBytes)/1e7, float64(b)/1e6)
		lastReq, lastBytes = req, b
	}
}

type countingWriter struct {
	http.ResponseWriter
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.ResponseWriter.Write(p)
	c.n += int64(n)
	return n, err
}

func isRoot(r string) bool {
	for _, x := range roots {
		if r == x {
			return true
		}
	}
	return false
}

func hasHidden(rel string) bool {
	for _, part := range strings.Split(rel, "/") {
		if strings.HasPrefix(part, ".") {
			return true
		}
	}
	return false
}

func lanAddrs() []string {
	var out []string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLoopback() {
			out = append(out, ipn.IP.String())
		}
	}
	return out
}
