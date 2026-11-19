package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func main() {
	serverURL := flag.String("server", "tls://127.0.0.1:4222", "NATS server URL")
	credsFile := flag.String("creds", "/opt/olg/config/jwt/orchestrator.creds", "Path to .creds file")
	caFile := flag.String("ca", "/opt/olg/config/certs/ca.crt", "Path to CA certificate file")
	probeOnly := flag.Bool("probe-only", false, "Only probe connection and JetStream readiness, then exit")
	payloadFile := flag.String("payload", "", "Path to configuration payload JSON file to push")
	bucketName := flag.String("bucket", "cfg_desired", "JetStream KV bucket name")
	keyName := flag.String("key", "desired.vyos", "KV key name")
	ifNotExists := flag.Bool("if-not-exists", false, "Only seed if key does not already exist")
	force := flag.Bool("force", false, "Force overwrite of key even if it already exists")
	flag.Parse()

	if err := run(*serverURL, *credsFile, *caFile, *payloadFile, *bucketName, *keyName, *probeOnly, *ifNotExists, *force); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run(server, creds, ca, payloadPath, bucket, key string, probeOnly, ifNotExists, force bool) error {
	opts := []nats.Option{
		nats.UserCredentials(creds),
		nats.Timeout(5 * time.Second),
	}

	if ca != "" {
		caCert, err := os.ReadFile(ca)
		if err != nil {
			return fmt.Errorf("failed to read CA file %s: %w", ca, err)
		}
		caPool := x509.NewCertPool()
		if !caPool.AppendCertsFromPEM(caCert) {
			return fmt.Errorf("failed to parse CA certificate from %s", ca)
		}
		tlsConfig := &tls.Config{
			RootCAs: caPool,
		}
		opts = append(opts, nats.Secure(tlsConfig))
	}

	nc, err := nats.Connect(server, opts...)
	if err != nil {
		return fmt.Errorf("failed to connect to NATS at %s: %w", server, err)
	}
	defer nc.Close()

	js, err := jetstream.New(nc)
	if err != nil {
		return fmt.Errorf("failed to initialize JetStream context: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if probeOnly {
		// Probe JetStream API availability without modifying or creating KV buckets
		if _, err := js.AccountInfo(ctx); err != nil {
			return fmt.Errorf("failed JetStream account readiness probe: %w", err)
		}
		fmt.Println("NATS connection and JetStream readiness probe succeeded.")
		return nil
	}

	// Ensure KV bucket exists during actual payload seeding
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:      bucket,
		Description: "OLG Appliance Desired Network Configuration Bucket",
		History:     10,
		Storage:     jetstream.FileStorage,
	})
	if err != nil {
		return fmt.Errorf("failed to create/access KV bucket %s: %w", bucket, err)
	}

	if payloadPath == "" {
		return fmt.Errorf("payload file must be specified when not running in probe-only mode")
	}

	data, err := os.ReadFile(payloadPath)
	if err != nil {
		return fmt.Errorf("failed to read payload file %s: %w", payloadPath, err)
	}

	// Extract or generate UUID from payload
	var header struct {
		UUID json.RawMessage `json:"uuid"`
	}
	_ = json.Unmarshal(data, &header)
	uuidStr := string(header.UUID)
	var intUUID int64
	if err := json.Unmarshal(header.UUID, &intUUID); err == nil {
		uuidStr = fmt.Sprintf("%d", intUUID)
	} else {
		var s string
		if err := json.Unmarshal(header.UUID, &s); err == nil {
			uuidStr = s
		}
	}
	if uuidStr == "" || uuidStr == "null" {
		uuidStr = fmt.Sprintf("%d", time.Now().Unix())
	}

	rec := map[string]interface{}{
		"Version":   "1.0",
		"RPCID":     fmt.Sprintf("bootstrap-%d", time.Now().UnixNano()),
		"Target":    "vyos",
		"UUID":      uuidStr,
		"Payload":   json.RawMessage(data),
		"Timestamp": time.Now().UTC(),
	}

	envelopeData, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("failed to marshal desired config envelope: %w", err)
	}

	if ifNotExists && !force {
		rev, err := kv.Create(ctx, key, envelopeData)
		if err != nil {
			if errors.Is(err, jetstream.ErrKeyExists) {
				fmt.Printf("Key '%s' already exists in bucket '%s'; skipping seeding as --if-not-exists is specified.\n", key, bucket)
				return nil
			}
			return fmt.Errorf("failed to create key %s in bucket %s: %w", key, bucket, err)
		}
		fmt.Printf("Successfully created payload in bucket '%s', key '%s' (Revision: %d).\n", bucket, key, rev)
		return nil
	}

	rev, err := kv.Put(ctx, key, envelopeData)
	if err != nil {
		return fmt.Errorf("failed to put key %s in bucket %s: %w", key, bucket, err)
	}

	fmt.Printf("Successfully pushed payload to bucket '%s', key '%s' (Revision: %d).\n", bucket, key, rev)
	return nil
}
