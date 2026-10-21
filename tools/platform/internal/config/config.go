// Package config manages serialization and initialization of the environment configuration file (.env),
// host environment discovery, and infrastructure component resolution.
package config

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// Env represents an environment configuration file structure, preserving key declaration
// order via a slice and mapping key-value pairs using double-quoted KEY="VALUE" formatting.
type Env struct {
	path   string
	order  []string
	values map[string]string
}

var envLineRe = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:[^"\\]|\\.)*"|[^\r\n]*)\s*$`)

// decodeValue unquotes double-quoted string values via strconv.Unquote.
// Unquoted or malformed input strings SHALL be returned unmodified.
func decodeValue(raw string) string {
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"' {
		if unquoted, err := strconv.Unquote(raw); err == nil {
			return unquoted
		}
	}
	return raw
}

// Load parses the environment configuration file at path. Non-existent target paths return
// an initialized, empty Env structure without error.
func Load(path string) (*Env, error) {
	e := &Env{path: path, values: map[string]string{}}

	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return e, nil
	}
	if err != nil {
		return nil, fmt.Errorf("config: open %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		m := envLineRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		e.set(m[1], decodeValue(m[2]))
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("config: read %s: %w", path, err)
	}
	return e, nil
}

func (e *Env) set(key, value string) {
	if _, exists := e.values[key]; !exists {
		e.order = append(e.order, key)
	}
	e.values[key] = value
}

// Get returns the value associated with key, or an empty string if undefined.
func (e *Env) Get(key string) string {
	return e.values[key]
}

// Set mutates key to value in place, inserting key into ordering sequence if previously undefined.
func (e *Env) Set(key, value string) {
	e.set(key, value)
}

// Save atomically writes all key-value pairs back to path in insertion order using KEY="VALUE" format.
func (e *Env) Save() error {
	var b strings.Builder
	for _, key := range e.order {
		fmt.Fprintf(&b, "%s=%q\n", key, e.values[key])
	}

	tmp := e.path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return fmt.Errorf("config: write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, e.path); err != nil {
		return fmt.Errorf("config: replace %s: %w", e.path, err)
	}
	return nil
}

var envRefRe = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// Environ expands variable references within key-value pairs against local configuration keys and
// host environment variables, returning a formatted KEY=value slice.
func (e *Env) Environ() []string {
	resolved := map[string]string{}
	out := make([]string, 0, len(e.order))

	for _, key := range e.order {
		expanded := envRefRe.ReplaceAllStringFunc(e.values[key], func(ref string) string {
			refKey := envRefRe.FindStringSubmatch(ref)[1]
			if v, ok := resolved[refKey]; ok {
				return v
			}
			return os.Getenv(refKey)
		})
		resolved[key] = expanded
		out = append(out, key+"="+expanded)
	}
	return out
}

// Expand replaces ${VAR} references within s against Env values and host environment variables.
func (e *Env) Expand(s string) string {
	if e == nil {
		return s
	}
	return envRefRe.ReplaceAllStringFunc(s, func(ref string) string {
		refKey := envRefRe.FindStringSubmatch(ref)[1]
		if v, ok := e.values[refKey]; ok {
			return e.Expand(v)
		}
		return os.Getenv(refKey)
	})
}

// GetExpanded returns the value associated with key after expanding variable references.
func (e *Env) GetExpanded(key string) string {
	if e == nil {
		return ""
	}
	v, ok := e.values[key]
	if !ok {
		return ""
	}
	return e.Expand(v)
}

// GetExpandedOrDefault returns GetExpanded of key, or fallback after expansion when .env does not declare key.
func (e *Env) GetExpandedOrDefault(key, fallback string) string {
	if e != nil {
		if _, ok := e.values[key]; ok {
			return e.GetExpanded(key)
		}
	}
	return e.Expand(fallback)
}
