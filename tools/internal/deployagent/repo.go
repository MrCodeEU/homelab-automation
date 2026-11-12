package deployagent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// Repo is a bare clone of the repository: main and this host's deploy
// branch, nothing else. go-git, so the host needs no git binary.
type Repo struct {
	r *git.Repository
}

// OpenRepo opens the bare clone in dir, creating it (with the remote
// origin at url) on first use. Nothing is fetched yet.
func OpenRepo(dir, url string) (*Repo, error) {
	r, err := git.PlainOpen(dir)
	if errors.Is(err, git.ErrRepositoryNotExists) {
		r, err = git.PlainInit(dir, true)
		if err == nil {
			_, err = r.CreateRemote(&config.RemoteConfig{Name: "origin", URLs: []string{url}})
		}
	}
	if err != nil {
		return nil, fmt.Errorf("repository %s: %w", dir, err)
	}
	return &Repo{r: r}, nil
}

// RemoteHead is the commit a branch points to on the remote, without
// fetching: one ls-remote, cheap enough to poll every minute.
func (g *Repo) RemoteHead(ctx context.Context, branch string) (plumbing.Hash, error) {
	remote, err := g.r.Remote("origin")
	if err != nil {
		return plumbing.ZeroHash, err
	}
	refs, err := remote.ListContext(ctx, &git.ListOptions{})
	if err != nil {
		return plumbing.ZeroHash, fmt.Errorf("ls-remote: %w", err)
	}
	want := plumbing.NewBranchReferenceName(branch)
	for _, ref := range refs {
		if ref.Name() == want {
			return ref.Hash(), nil
		}
	}
	return plumbing.ZeroHash, ErrNoBranch
}

// ErrNoBranch: the deploy branch does not exist yet, so there is no
// request. A poll that finds it is still a successful poll.
var ErrNoBranch = errors.New("no deploy branch yet")

// Fetch brings the given branches up to date as refs/remotes/origin/<b>.
func (g *Repo) Fetch(ctx context.Context, branches ...string) error {
	var specs []config.RefSpec
	for _, b := range branches {
		specs = append(specs, config.RefSpec(fmt.Sprintf("+refs/heads/%s:refs/remotes/origin/%s", b, b)))
	}
	err := g.r.FetchContext(ctx, &git.FetchOptions{RemoteName: "origin", RefSpecs: specs, Tags: git.NoTags})
	if err != nil && !errors.Is(err, git.NoErrAlreadyUpToDate) {
		return fmt.Errorf("fetch %s: %w", strings.Join(branches, ", "), err)
	}
	return nil
}

// Head is the fetched head of a branch.
func (g *Repo) Head(branch string) (*object.Commit, error) {
	ref, err := g.r.Reference(plumbing.NewRemoteReferenceName("origin", branch), true)
	if err != nil {
		return nil, fmt.Errorf("branch %s: %w", branch, err)
	}
	return g.r.CommitObject(ref.Hash())
}

// Commit looks up a fetched commit by its full sha.
func (g *Repo) Commit(sha string) (*object.Commit, error) {
	c, err := g.r.CommitObject(plumbing.NewHash(sha))
	if err != nil {
		return nil, fmt.Errorf("commit %s: %w", sha, err)
	}
	return c, nil
}

// Verify checks c's signature against an armored keyring and returns the
// signing key's id.
func Verify(c *object.Commit, keyring string) (string, error) {
	if c.PGPSignature == "" {
		return "", fmt.Errorf("commit %s is not signed", c.Hash)
	}
	e, err := c.Verify(keyring)
	if err != nil {
		return "", fmt.Errorf("commit %s: signature: %w", c.Hash, err)
	}
	return e.PrimaryKey.KeyIdString(), nil
}

// Reachable reports whether target is from or one of its ancestors.
func Reachable(target, from *object.Commit) (bool, error) {
	if target.Hash == from.Hash {
		return true, nil
	}
	return target.IsAncestor(from)
}

// ReadFile returns the content of one file in c's tree.
func ReadFile(c *object.Commit, path string) ([]byte, error) {
	f, err := c.File(path)
	if err != nil {
		return nil, fmt.Errorf("commit %s: %s: %w", c.Hash, path, err)
	}
	s, err := f.Contents()
	return []byte(s), err
}

// Export writes c's tree into dir, which must not exist yet: regular
// files 0644, executables 0755, symlinks as symlinks. Submodules are
// skipped (the repository has none).
func Export(c *object.Commit, dir string) error {
	if err := os.Mkdir(dir, 0o755); err != nil {
		return err
	}
	tree, err := c.Tree()
	if err != nil {
		return err
	}
	return tree.Files().ForEach(func(f *object.File) error {
		if !filepath.IsLocal(f.Name) {
			return fmt.Errorf("commit %s: path %q leaves the tree", c.Hash, f.Name)
		}
		dst := filepath.Join(dir, f.Name)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		switch f.Mode {
		case filemode.Symlink:
			target, err := f.Contents()
			if err != nil {
				return err
			}
			return os.Symlink(target, dst)
		case filemode.Regular, filemode.Deprecated, filemode.Executable:
			mode := os.FileMode(0o644)
			if f.Mode == filemode.Executable {
				mode = 0o755
			}
			return writeBlob(f, dst, mode)
		}
		return nil
	})
}

func writeBlob(f *object.File, dst string, mode os.FileMode) error {
	r, err := f.Reader()
	if err != nil {
		return err
	}
	defer r.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, r); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
