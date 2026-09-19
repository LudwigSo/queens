package main

import (
	"bytes"
	"os"
	"testing"
)

// The checked-in openapi.yaml is the reviewable form of the API contract. This
// is a Go test rather than a CI-only step, so drift fails locally, in the same
// run that introduced it.
func TestOpenAPISpecUpToDate(t *testing.T) {
	want, err := OpenAPIDocument()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	got, err := os.ReadFile("../../openapi.yaml")
	if err != nil {
		t.Fatalf("read openapi.yaml: %v\nRun: go run ./cmd/queensd openapi -o openapi.yaml", err)
	}
	strip := func(b []byte) []byte { return bytes.ReplaceAll(b, []byte("\r"), nil) }
	if !bytes.Equal(strip(want), strip(got)) {
		t.Fatal("openapi.yaml is out of date.\nRun: go run ./cmd/queensd openapi -o openapi.yaml")
	}
}
