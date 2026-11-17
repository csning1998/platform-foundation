package config

import (
	"errors"
	"fmt"
)

var (
	// ErrSecretKey reports a key whose value MUST NOT leave the process, for example a Vault token.
	ErrSecretKey = errors.New("config: the key contains a secret")
	// ErrKeyUndefined reports a key which the .env file does not declare.
	ErrKeyUndefined = errors.New("config: the key is undefined")
)

// secretKeys names every .env key whose value a caller outside the process MUST NOT receive.
var secretKeys = map[string]bool{KeyVaultToken: true}

// ResolvePublicValue returns the expanded value of key, refusing a secret key and an undefined key.
func (e *Env) ResolvePublicValue(key string) (string, error) {
	if secretKeys[key] {
		return "", fmt.Errorf("%w: %s", ErrSecretKey, key)
	}
	_, ok := e.values[key]
	if !ok {
		return "", fmt.Errorf("%w: %q", ErrKeyUndefined, key)
	}
	return e.GetExpanded(key), nil
}
