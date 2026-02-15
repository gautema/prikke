package main

import (
	"fmt"
	"math/rand"
	"net/http"
	"strconv"
	"time"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// ?delay=100 — fixed delay in ms
		if d := r.URL.Query().Get("delay"); d != "" {
			if ms, err := strconv.Atoi(d); err == nil {
				time.Sleep(time.Duration(ms) * time.Millisecond)
			}
		}

		// ?jitter=500 — random delay 0-500ms (simulates real endpoints)
		if j := r.URL.Query().Get("jitter"); j != "" {
			if ms, err := strconv.Atoi(j); err == nil {
				time.Sleep(time.Duration(rand.Intn(ms)) * time.Millisecond)
			}
		}

		// ?status=503 — return specific status code
		status := 200
		if s := r.URL.Query().Get("status"); s != "" {
			if code, err := strconv.Atoi(s); err == nil {
				status = code
			}
		}

		// ?fail_rate=10 — fail 10% of requests with 500
		if f := r.URL.Query().Get("fail_rate"); f != "" {
			if pct, err := strconv.Atoi(f); err == nil {
				if rand.Intn(100) < pct {
					status = 500
				}
			}
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		fmt.Fprintf(w, `{"status":"ok","method":"%s","path":"%s"}`, r.Method, r.URL.Path)
	})

	fmt.Println("Mock endpoint listening on :8080")
	http.ListenAndServe(":8080", nil)
}
