package runstate

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// run ディレクトリの中身（§4.6 F1）。
const (
	EventsFile = "events.jsonl"
	StateFile  = "state.json"
	LogsDir    = "logs"
	CancelFile = "cancel-requested" // runner が見張る印（cancel_requested イベントと同時に置く）
	lockDir    = "lock"
)

// Run は 1 つの run ディレクトリ。
type Run struct {
	ID  string
	Dir string

	// Now は時刻の取得元（テストで差し替える）。
	Now func() time.Time
}

// Open は既存の run ディレクトリを開く。
func Open(runsDir, id string) (*Run, error) {
	if id == "" || filepath.Base(id) != id || id == "." || id == ".." {
		return nil, fmt.Errorf("invalid run id %q", id)
	}
	dir := filepath.Join(runsDir, id)
	if _, err := os.Stat(filepath.Join(dir, EventsFile)); err != nil {
		return nil, fmt.Errorf("run %q not found in %s", id, runsDir)
	}
	return &Run{ID: id, Dir: dir, Now: time.Now}, nil
}

// Create は新しい run ディレクトリを作る（既にあればエラー）。
func Create(runsDir, id string) (*Run, error) {
	if err := os.MkdirAll(runsDir, 0o755); err != nil {
		return nil, err
	}
	dir := filepath.Join(runsDir, id)
	if err := os.Mkdir(dir, 0o755); err != nil {
		return nil, err
	}
	if err := os.Mkdir(filepath.Join(dir, LogsDir), 0o755); err != nil {
		return nil, err
	}
	return &Run{ID: id, Dir: dir, Now: time.Now}, nil
}

// List は runsDir 配下の run id を名前の昇順で返す（run id は時刻始まりなので古い順）。
func List(runsDir string) ([]string, error) {
	entries, err := os.ReadDir(runsDir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, e := range entries {
		if e.IsDir() {
			if _, err := os.Stat(filepath.Join(runsDir, e.Name(), EventsFile)); err == nil {
				ids = append(ids, e.Name())
			}
		}
	}
	sort.Strings(ids)
	return ids, nil
}

// Torn は events.jsonl の末尾にあった不完全な行（改行で終わっていない最終行）。
type Torn struct {
	Offset int64 // 不完全な行の開始位置（ここまでが完全なイベント）
	Bytes  int
}

// ReadEvents は events.jsonl を読む。最終行が改行で終わっていなければ、途中で切れた書き込みとして
// 読み飛ばし、Torn で知らせる（最後の完全なイベントまでで状態を再構成できる）。
// 途中の行が壊れている場合は切れた書き込みでは説明がつかないのでエラーにする。
func ReadEvents(path string) ([]Event, *Torn, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	var events []Event
	var torn *Torn
	var offset int64
	r := bufio.NewReader(bytes.NewReader(data))
	for {
		line, err := r.ReadBytes('\n')
		if err == io.EOF {
			if len(line) > 0 {
				torn = &Torn{Offset: offset, Bytes: len(line)}
			}
			break
		}
		if err != nil {
			return nil, nil, err
		}
		var ev Event
		dec := json.NewDecoder(bytes.NewReader(line))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&ev); err != nil {
			return nil, nil, fmt.Errorf("%s: line %d is not a valid event: %v", path, len(events)+1, err)
		}
		events = append(events, ev)
		offset += int64(len(line))
	}
	return events, torn, nil
}

// Load は events.jsonl を畳み込んで状態を返す（正本から作る。state.json は読まない）。
func (r *Run) Load() (*State, *Torn, error) {
	events, torn, err := ReadEvents(filepath.Join(r.Dir, EventsFile))
	if err != nil {
		return nil, nil, err
	}
	s, err := Fold(events)
	if err != nil {
		return nil, nil, fmt.Errorf("%s: %v", filepath.Join(r.Dir, EventsFile), err)
	}
	return s, torn, nil
}

// Append はロックを取ってイベントを追記し、畳み込んだ状態を state.json に原子的に書いて返す。
// seq と ts はここで付ける。末尾に途中で切れた行があれば、その断片を events.jsonl.torn-<時刻> へ退避してから
// 切り詰める（断片の後ろに追記すると、以後の行がすべて壊れた 1 行に連結されるため）。
func (r *Run) Append(evs ...Event) (*State, error) {
	unlock, err := r.lock()
	if err != nil {
		return nil, err
	}
	defer unlock()
	return r.appendLocked(evs...)
}

func (r *Run) appendLocked(evs ...Event) (*State, error) {
	path := filepath.Join(r.Dir, EventsFile)
	var events []Event
	if _, err := os.Stat(path); err == nil {
		var torn *Torn
		events, torn, err = ReadEvents(path)
		if err != nil {
			return nil, err
		}
		if torn != nil {
			if err := r.setAsideTorn(path, torn); err != nil {
				return nil, err
			}
		}
	}
	var state *State
	if len(events) > 0 {
		var err error
		if state, err = Fold(events); err != nil {
			return nil, err
		}
	}
	var buf bytes.Buffer
	seq := len(events)
	for i := range evs {
		ev := evs[i]
		seq++
		ev.Seq = seq
		ev.TS = r.Now().UTC().Format(time.RFC3339Nano)
		line, err := json.Marshal(ev)
		if err != nil {
			return nil, err
		}
		// 書く前に、書いたものを読み戻した値で畳み込めることを確かめる（不整合なイベントを正本に入れない）。
		var back Event
		if err := json.Unmarshal(line, &back); err != nil {
			return nil, err
		}
		next, err := Apply(state, &back)
		if err != nil {
			return nil, err
		}
		state = next
		buf.Write(line)
		buf.WriteByte('\n')
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	if _, err := f.Write(buf.Bytes()); err != nil {
		f.Close()
		return nil, err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, err
	}
	if err := f.Close(); err != nil {
		return nil, err
	}
	if err := WriteStateFile(r.Dir, state); err != nil {
		return nil, err
	}
	return state, nil
}

func (r *Run) setAsideTorn(path string, torn *Torn) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	aside := fmt.Sprintf("%s.torn-%d", path, r.Now().UnixNano())
	if err := os.WriteFile(aside, data[torn.Offset:], 0o644); err != nil {
		return err
	}
	return os.Truncate(path, torn.Offset)
}

// WriteStateFile は state.json を一時ファイル＋rename で原子的に置き換える。
func WriteStateFile(dir string, s *State) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(dir, ".state.json.tmp-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), filepath.Join(dir, StateFile))
}

// ReadStateFile は state.json を読む（観測用の写し。正本は events.jsonl）。
func ReadStateFile(dir string) (*State, error) {
	data, err := os.ReadFile(filepath.Join(dir, StateFile))
	if err != nil {
		return nil, err
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}
