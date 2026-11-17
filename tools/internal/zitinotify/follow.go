package zitinotify

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os"
	"syscall"
	"time"
)

// Follow sends each line appended to path to lines, starting at the end
// of the file. The controller rotates events.log by renaming it and
// starting a new one; Follow reads the old file to its end, then switches.
func Follow(ctx context.Context, path string, poll time.Duration, lines chan<- []byte) error {
	f, ino, err := open(path)
	if err != nil {
		return err
	}
	if _, err := f.Seek(0, io.SeekEnd); err != nil {
		f.Close()
		return err
	}
	r := bufio.NewReaderSize(f, 1<<20)
	var partial []byte
	for {
		chunk, err := r.ReadBytes('\n')
		partial = append(partial, chunk...)
		if err == nil {
			select {
			case lines <- partial:
			case <-ctx.Done():
				f.Close()
				return ctx.Err()
			}
			partial = nil
			continue
		}
		if !errors.Is(err, io.EOF) {
			f.Close()
			return err
		}
		// At the end: rotated, or wait for more.
		if nf, nino, err := open(path); err == nil {
			if nino != ino {
				f.Close()
				f, ino, partial = nf, nino, nil
				r.Reset(f)
				continue
			}
			nf.Close()
		}
		select {
		case <-ctx.Done():
			f.Close()
			return ctx.Err()
		case <-time.After(poll):
		}
	}
}

func open(path string) (*os.File, uint64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, 0, err
	}
	var ino uint64
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		ino = s.Ino
	}
	return f, ino, nil
}
