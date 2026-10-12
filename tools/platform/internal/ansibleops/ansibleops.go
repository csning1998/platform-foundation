// Package ansibleops executes ansible-playbook tasks via go-ansible under ANSIBLE_CONFIG scoping.
package ansibleops

import (
	"context"
	"path/filepath"

	"github.com/apenella/go-ansible/v2/pkg/execute"
	"github.com/apenella/go-ansible/v2/pkg/playbook"
)

// RunPlaybook executes playbookFile using opts while injecting ANSIBLE_CONFIG derived from ansibleDir.
// If runDir is non-empty, sets the command execution directory to runDir to resolve relative playbook paths.
func RunPlaybook(ctx context.Context, ansibleDir, runDir, playbookFile string, opts *playbook.AnsiblePlaybookOptions) error {
	return RunPlaybookWithConfig(ctx, filepath.Join(ansibleDir, "ansible.cfg"), runDir, playbookFile, opts, nil)
}

// RunPlaybookWithConfig executes playbookFile under the configuration file configFile and the additional variables env.
func RunPlaybookWithConfig(ctx context.Context, configFile, runDir, playbookFile string, opts *playbook.AnsiblePlaybookOptions, env map[string]string) error {
	cmd := playbook.NewAnsiblePlaybookCmd(
		playbook.WithPlaybooks(playbookFile),
		playbook.WithPlaybookOptions(opts),
	)

	vars := map[string]string{
		"ANSIBLE_CONFIG":      configFile,
		"ANSIBLE_FORCE_COLOR": "1",
	}
	for k, v := range env {
		vars[k] = v
	}
	execOpts := []execute.ExecuteOptions{
		execute.WithCmd(cmd),
		execute.WithEnvVars(vars),
	}
	if runDir != "" {
		execOpts = append(execOpts, execute.WithCmdRunDir(runDir))
	}

	return execute.NewDefaultExecute(execOpts...).Execute(ctx)
}
