package runstate

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ロックの待ち時間。書き込みは短い（1 回の追記と state.json の置き換え）ので、待ちが長引くのは持ち主が落ちたときだけ。
var (
	lockWait     = 10 * time.Second
	lockPoll     = 10 * time.Millisecond
	lockOrphanAt = 10 * time.Second // owner の無いロックをこの時間より古ければ放棄されたとみなす
)

// lock は run ディレクトリのロックを mkdir 方式で取る（plugin/scripts/worktree-setup.sh と同じ方式）。
// owner に「PID と一意の印」を書き、解放は自分の印のときだけ行う。持ち主のプロセスが存在しないロックは奪う。
// 奪う操作は別の mkdir ロック（lock.break）の中で、持ち主が居ないことを確かめ直してから行う
// （2 者が同じ stale なロックを見て、片方が取り直した新しいロックをもう片方が消す競合を防ぐ）。
func (r *Run) lock() (func(), error) {
	dir := filepath.Join(r.Dir, lockDir)
	token := fmt.Sprintf("%d %d", os.Getpid(), time.Now().UnixNano())
	deadline := time.Now().Add(lockWait)
	for {
		err := os.Mkdir(dir, 0o755)
		if err == nil {
			owner := filepath.Join(dir, "owner")
			if werr := writeOwner(dir, token); werr != nil {
				os.RemoveAll(dir)
				return nil, werr
			}
			return func() {
				if b, err := os.ReadFile(owner); err == nil && string(b) == token {
					os.Remove(owner)
					os.Remove(dir)
				}
			}, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		if stale(dir) {
			breakStale(dir)
			continue
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("timed out waiting for the run lock %s", dir)
		}
		time.Sleep(lockPoll)
	}
}

// writeOwner は owner を一時ファイルに書いてから rename で置く。os.WriteFile で owner を直接書くと、
// ファイルができてから中身が書かれるまでの間、他の書き手に空の owner が見える。
func writeOwner(dir, token string) error {
	tmp := filepath.Join(dir, "owner.tmp")
	if err := os.WriteFile(tmp, []byte(token), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, "owner"))
}

// stale は持ち主が居ないロックかを返す。
func stale(dir string) bool {
	data, err := os.ReadFile(filepath.Join(dir, "owner"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		// owner が無いか空のロック: 取られた直後（mkdir と owner の書き込みの間）か、その間に落ちたロック。
		// 中身では見分けられないので、作られてから十分に時間が経っていれば放棄とみなす。空の owner を
		// 即座に放棄とみなすと、取られたばかりのロックを消し、2 者が同時にロックを持つ。
		fi, serr := os.Stat(dir)
		return serr == nil && time.Since(fi.ModTime()) > lockOrphanAt
	}
	pid, err := strconv.Atoi(fields[0])
	if err != nil || pid <= 0 {
		return true
	}
	return !Alive(pid)
}

// breakStale は lock.break を取ってから stale を確かめ直し、なお stale なら消す。lock.break を取れなければ何もしない
// （他者が奪っている最中。呼び出し元はロックの取得からやり直す）。lock.break 自体が放置されていれば（奪う途中で
// 落ちた）、十分に古いものだけ消す。
func breakStale(dir string) {
	guard := dir + ".break"
	if err := os.Mkdir(guard, 0o755); err != nil {
		if fi, serr := os.Stat(guard); serr == nil && time.Since(fi.ModTime()) > lockOrphanAt {
			os.Remove(guard)
		}
		time.Sleep(lockPoll)
		return
	}
	defer os.Remove(guard)
	if stale(dir) {
		os.RemoveAll(dir)
	}
}

// Alive はプロセスが存在するかを返す（シグナル 0 の送信で調べる）。
func Alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
