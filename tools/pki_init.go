package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

var (
	ucentralPubAllow = []string{
		"cmd.configure.>",
		"cmd.action.>",
		"status.get.>",
		"capabilities.get.>",
		"$KV.cfg_desired.>",
		"$JS.API.STREAM.INFO.KV_cfg_desired",
		"$JS.API.DIRECT.GET.KV_cfg_desired.>",
		"$JS.ACK.KV_cfg_desired.>",
		"_INBOX.>",
	}
	ucentralSubAllow = []string{
		"status.>",
		"telemetry.>",
		"logs.>",
		"health.>",
		"result.>",
		"_INBOX.>",
	}

	vyosPubAllow = []string{
		"status.>",
		"telemetry.>",
		"logs.>",
		"health.>",
		"result.>",
		"$JS.API.STREAM.INFO.KV_cfg_desired",
		"$JS.API.DIRECT.GET.KV_cfg_desired.>",
		"$JS.API.CONSUMER.CREATE.KV_cfg_desired.>",
		"$JS.API.CONSUMER.INFO.KV_cfg_desired.>",
		"$JS.API.CONSUMER.MSG.NEXT.KV_cfg_desired.>",
		"$JS.API.CONSUMER.DELETE.KV_cfg_desired.>",
		"$JS.ACK.KV_cfg_desired.>",
		"_INBOX.>",
	}
	vyosSubAllow = []string{
		"cmd.configure.>",
		"cmd.action.>",
		"status.get.>",
		"capabilities.get.>",
		"$KV.cfg_desired.>",
		"_INBOX.>",
	}
)

func equalStringSlices(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	counts := make(map[string]int, len(a))
	for _, x := range a {
		counts[x]++
	}
	for _, x := range b {
		counts[x]--
		if counts[x] < 0 {
			return false
		}
	}
	return true
}

func main() {
	mode := flag.String("mode", "bootstrap", "Execution mode: bootstrap or verify-creds")
	credsPath := flag.String("creds", "", "Path to credentials file to verify (for verify-creds mode)")
	outJwtDir := flag.String("out-jwt", "/opt/olg/config/jwt", "Output directory for server JWTs and keys")
	outClientDir := flag.String("out-client", "/etc/olg/client", "Output directory for uCentral client credentials")
	outGuestDir := flag.String("out-guest", "/etc/olg/guest-secrets", "Output directory for VyOS agent credentials")
	outResolverFile := flag.String("out-resolver", "/opt/olg/config/resolver.conf", "Path to resolver.conf output")
	flag.Parse()

	if *mode == "verify-creds" {
		if *credsPath == "" {
			fmt.Fprintf(os.Stderr, "Error: --creds <path> is required for verify-creds mode\n")
			os.Exit(1)
		}

		var expectedPub, expectedSub []string
		if data, err := os.ReadFile(*credsPath); err == nil && len(data) > 0 {
			if userJwt, err := jwt.ParseDecoratedJWT(data); err == nil {
				if claims, err := jwt.DecodeUserClaims(userJwt); err == nil {
					filename := filepath.Base(*credsPath)
					if claims.Name == "ucentral_client" || strings.Contains(filename, "ucentral") {
						expectedPub = ucentralPubAllow
						expectedSub = ucentralSubAllow
					} else if claims.Name == "vyos_agent" || strings.Contains(filename, "vyos") {
						expectedPub = vyosPubAllow
						expectedSub = vyosSubAllow
					}
				}
			}
		}

		if !isValidUserCreds(*credsPath, "", expectedPub, expectedSub) {
			fmt.Fprintf(os.Stderr, "Credentials file %s is missing, corrupt, or has outdated permissions\n", *credsPath)
			os.Exit(1)
		}
		fmt.Printf("Credentials file %s verified successfully.\n", *credsPath)
		return
	}

	if err := run(*outJwtDir, *outClientDir, *outGuestDir, *outResolverFile); err != nil {
		fmt.Fprintf(os.Stderr, "Error bootstrapping NATS PKI: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("NATS PKI & Credentials bootstrapped successfully.")
}

func isValidUserCreds(path string, expectedIssuer string, expectedPub, expectedSub []string) bool {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return false
	}
	userJwt, err := jwt.ParseDecoratedJWT(data)
	if err != nil {
		return false
	}
	claims, err := jwt.DecodeUserClaims(userJwt)
	if err != nil || (expectedIssuer != "" && claims.Issuer != expectedIssuer) {
		return false
	}
	if expectedPub != nil && !equalStringSlices(claims.Permissions.Pub.Allow, expectedPub) {
		return false
	}
	if expectedSub != nil && !equalStringSlices(claims.Permissions.Sub.Allow, expectedSub) {
		return false
	}
	kp, err := jwt.ParseDecoratedNKey(data)
	if err != nil || kp == nil {
		return false
	}
	pub, err := kp.PublicKey()
	if err != nil || pub == "" {
		return false
	}
	return pub == claims.Subject
}

func run(jwtDir, clientDir, guestDir, resolverPath string) error {
	for _, dir := range []string{jwtDir, clientDir, guestDir, filepath.Dir(resolverPath)} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}

	// 1. Operator Keypair & JWT (Preserve existing if present and valid)
	var opKp nkeys.KeyPair
	opNkPath := filepath.Join(jwtDir, "operator.nk")
	if data, err := os.ReadFile(opNkPath); err == nil && len(data) > 0 {
		opKp, _ = nkeys.FromSeed([]byte(strings.TrimSpace(string(data))))
	}
	if opKp == nil {
		kp, err := nkeys.CreateOperator()
		if err != nil {
			return fmt.Errorf("failed to create operator keypair: %w", err)
		}
		opKp = kp
		opSeed, err := opKp.Seed()
		if err != nil {
			return err
		}
		if err := atomicWriteFile(opNkPath, opSeed, 0600); err != nil {
			return err
		}
	}
	opPub, err := opKp.PublicKey()
	if err != nil {
		return err
	}

	var opJwt string
	opJwtPath := filepath.Join(jwtDir, "operator.jwt")
	if data, err := os.ReadFile(opJwtPath); err == nil && len(data) > 0 {
		if claims, err := jwt.DecodeOperatorClaims(string(data)); err == nil && claims.Subject == opPub {
			opJwt = string(data)
		}
	}
	if opJwt == "" {
		opClaims := jwt.NewOperatorClaims(opPub)
		opClaims.Name = "OLG-Operator"
		opClaims.IssuedAt = time.Now().Unix()
		encoded, err := opClaims.Encode(opKp)
		if err != nil {
			return fmt.Errorf("failed to encode operator JWT: %w", err)
		}
		opJwt = encoded
		if err := atomicWriteFile(opJwtPath, []byte(opJwt), 0600); err != nil {
			return err
		}
	}

	// 2. System Account Keypair & JWT (Preserve existing if present and valid)
	var sysKp nkeys.KeyPair
	sysNkPath := filepath.Join(jwtDir, "sys_account.nk")
	if data, err := os.ReadFile(sysNkPath); err == nil && len(data) > 0 {
		sysKp, _ = nkeys.FromSeed([]byte(strings.TrimSpace(string(data))))
	}
	if sysKp == nil {
		kp, err := nkeys.CreateAccount()
		if err != nil {
			return fmt.Errorf("failed to create sys account keypair: %w", err)
		}
		sysKp = kp
		sysSeed, err := sysKp.Seed()
		if err != nil {
			return err
		}
		if err := atomicWriteFile(sysNkPath, sysSeed, 0600); err != nil {
			return err
		}
	}
	sysPub, err := sysKp.PublicKey()
	if err != nil {
		return err
	}

	var sysJwt string
	sysJwtPath := filepath.Join(jwtDir, "sys_account.jwt")
	if data, err := os.ReadFile(sysJwtPath); err == nil && len(data) > 0 {
		if claims, err := jwt.DecodeAccountClaims(string(data)); err == nil && claims.Subject == sysPub && claims.Issuer == opPub {
			sysJwt = string(data)
		}
	}
	if sysJwt == "" {
		sysClaims := jwt.NewAccountClaims(sysPub)
		sysClaims.Name = "SYS"
		sysClaims.IssuedAt = time.Now().Unix()
		encoded, err := sysClaims.Encode(opKp)
		if err != nil {
			return fmt.Errorf("failed to encode sys account JWT: %w", err)
		}
		sysJwt = encoded
		if err := atomicWriteFile(sysJwtPath, []byte(sysJwt), 0600); err != nil {
			return err
		}
	}

	// 3. Application (OLG) Account Keypair & JWT (Preserve existing if present and valid)
	var olgKp nkeys.KeyPair
	olgNkPath := filepath.Join(jwtDir, "olg_account.nk")
	if data, err := os.ReadFile(olgNkPath); err == nil && len(data) > 0 {
		olgKp, _ = nkeys.FromSeed([]byte(strings.TrimSpace(string(data))))
	}
	if olgKp == nil {
		kp, err := nkeys.CreateAccount()
		if err != nil {
			return fmt.Errorf("failed to create olg account keypair: %w", err)
		}
		olgKp = kp
		olgSeed, err := olgKp.Seed()
		if err != nil {
			return err
		}
		if err := atomicWriteFile(olgNkPath, olgSeed, 0600); err != nil {
			return err
		}
	}
	olgPub, err := olgKp.PublicKey()
	if err != nil {
		return err
	}

	var olgJwt string
	olgJwtPath := filepath.Join(jwtDir, "olg_account.jwt")
	if data, err := os.ReadFile(olgJwtPath); err == nil && len(data) > 0 {
		if claims, err := jwt.DecodeAccountClaims(string(data)); err == nil && claims.Subject == olgPub && claims.Issuer == opPub {
			olgJwt = string(data)
		}
	}
	if olgJwt == "" {
		olgClaims := jwt.NewAccountClaims(olgPub)
		olgClaims.Name = "OLG"
		olgClaims.IssuedAt = time.Now().Unix()
		olgClaims.Limits.JetStreamLimits.DiskStorage = -1
		olgClaims.Limits.JetStreamLimits.MemoryStorage = -1
		olgClaims.Limits.JetStreamLimits.Streams = -1
		olgClaims.Limits.JetStreamLimits.Consumer = -1
		encoded, err := olgClaims.Encode(opKp)
		if err != nil {
			return fmt.Errorf("failed to encode olg account JWT: %w", err)
		}
		olgJwt = encoded
		if err := atomicWriteFile(olgJwtPath, []byte(olgJwt), 0600); err != nil {
			return err
		}
	}

	// 4. Users under OLG Account (Only generate if missing or invalid)
	// 4a. Orchestrator User (Admin)
	orchCredsPath := filepath.Join(jwtDir, "orchestrator.creds")
	if !isValidUserCreds(orchCredsPath, olgPub, nil, nil) {
		orchCreds, err := createUserCreds("orchestrator", olgKp, func(u *jwt.UserClaims) {
			// Full permissions
		})
		if err != nil {
			return err
		}
		if err := atomicWriteFile(orchCredsPath, orchCreds, 0600); err != nil {
			return err
		}
	}

	// 4b. uCentral Client User
	ucentralCredsPath := filepath.Join(clientDir, "ucentral.creds")
	if !isValidUserCreds(ucentralCredsPath, olgPub, ucentralPubAllow, ucentralSubAllow) {
		ucentralCreds, err := createUserCreds("ucentral_client", olgKp, func(u *jwt.UserClaims) {
			u.Permissions.Pub.Allow = ucentralPubAllow
			u.Permissions.Sub.Allow = ucentralSubAllow
		})
		if err != nil {
			return err
		}
		if err := atomicWriteFile(ucentralCredsPath, ucentralCreds, 0600); err != nil {
			return err
		}
	}

	// 4c. VyOS Agent User
	vyosCredsPath := filepath.Join(guestDir, "vyos_agent.creds")
	if !isValidUserCreds(vyosCredsPath, olgPub, vyosPubAllow, vyosSubAllow) {
		vyosCreds, err := createUserCreds("vyos_agent", olgKp, func(u *jwt.UserClaims) {
			u.Permissions.Pub.Allow = vyosPubAllow
			u.Permissions.Sub.Allow = vyosSubAllow
		})
		if err != nil {
			return err
		}
		if err := atomicWriteFile(vyosCredsPath, vyosCreds, 0600); err != nil {
			return err
		}
	}

	// Write resolver.conf
	resolverContent := fmt.Sprintf(`# Auto-generated NATS Memory Account Resolver
operator: "/etc/nats/jwt/operator.jwt"
system_account: "%s"
resolver: MEMORY
resolver_preload: {
  "%s": "%s",
  "%s": "%s"
}
`, sysPub, sysPub, sysJwt, olgPub, olgJwt)

	return atomicWriteFile(resolverPath, []byte(resolverContent), 0600)
}

func createUserCreds(name string, accountKp nkeys.KeyPair, customize func(*jwt.UserClaims)) ([]byte, error) {
	uKp, err := nkeys.CreateUser()
	if err != nil {
		return nil, fmt.Errorf("failed to create user %s keypair: %w", name, err)
	}
	uPub, err := uKp.PublicKey()
	if err != nil {
		return nil, err
	}
	uSeed, err := uKp.Seed()
	if err != nil {
		return nil, err
	}

	uClaims := jwt.NewUserClaims(uPub)
	uClaims.Name = name
	uClaims.IssuedAt = time.Now().Unix()
	if customize != nil {
		customize(uClaims)
	}

	uJwt, err := uClaims.Encode(accountKp)
	if err != nil {
		return nil, fmt.Errorf("failed to encode user %s JWT: %w", name, err)
	}

	creds, err := jwt.FormatUserConfig(uJwt, uSeed)
	if err != nil {
		return nil, fmt.Errorf("failed to format user config for %s: %w", name, err)
	}
	return creds, nil
}

func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
	tmpPath := fmt.Sprintf("%s.tmp.%d", path, time.Now().UnixNano())
	if err := os.WriteFile(tmpPath, data, perm); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}
