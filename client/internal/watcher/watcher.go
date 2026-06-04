// Package watcher monitora um diretório via inotify (fsnotify) e emite eventos normalizados.
// fsnotify não entrega eventos de leitura, então READ não é capturável (SPECS §8.2 — limitação).
package watcher

import (
	"context"
	"log"

	"github.com/fsnotify/fsnotify"
)

// Event normaliza um evento de filesystem para uma operação de auditoria.
type Event struct {
	Op   string // CREATE | UPDATE | DELETE
	Path string
}

// Watch monitora dir e envia eventos em out até o ctx ser cancelado.
func Watch(ctx context.Context, dir string, out chan<- Event, logger *log.Logger) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()

	if err := w.Add(dir); err != nil {
		return err
	}
	logger.Printf("monitorando diretório: %s", dir)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case e, ok := <-w.Events:
			if !ok {
				return nil
			}
			op := mapOp(e.Op)
			if op == "" {
				continue
			}
			select {
			case out <- Event{Op: op, Path: e.Name}:
			case <-ctx.Done():
				return ctx.Err()
			}
		case err, ok := <-w.Errors:
			if !ok {
				return nil
			}
			logger.Printf("erro do watcher: %v", err)
		}
	}
}

func mapOp(op fsnotify.Op) string {
	switch {
	case op.Has(fsnotify.Create):
		return "CREATE"
	case op.Has(fsnotify.Write):
		return "UPDATE"
	case op.Has(fsnotify.Remove), op.Has(fsnotify.Rename):
		return "DELETE"
	default:
		return "" // Chmod e outros: ignorados
	}
}
