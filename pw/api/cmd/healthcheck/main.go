// healthcheck は Docker の healthcheck から実行される小さな HTTP クライアントです。
package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

const defaultURL = "http://localhost:3000/health"

func main() {
	url := os.Getenv("HEALTHCHECK_URL")
	if url == "" {
		url = defaultURL
	}

	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Get(url)
	if err != nil {
		fail(err)
	}
	defer response.Body.Close()

	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		fail(fmt.Errorf("unexpected HTTP status: %s", response.Status))
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
