package runstate

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
)

// ProcStart はプロセスの開始時刻を、ps の lstart の文字列で返す（読めなければ空）。runner の PID と一緒に記録し、
// 後で同じ PID のプロセスが同じ開始時刻かを比べて PID の再利用を見分ける（#347）。ロケールと時間帯に依らない
// 文字列にするため、LC_ALL=C・TZ=UTC で ps を呼ぶ（記録した側と読む側の環境が違っても同じ文字列になる）。
func ProcStart(pid int) string {
	if pid <= 0 {
		return ""
	}
	cmd := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid))
	cmd.Env = append(os.Environ(), "LC_ALL=C", "TZ=UTC")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.Join(strings.Fields(string(out)), " ")
}

// RunnerAlive は run を進めるプロセス（runner）が生きているかを返す。PID が存在するだけでなく、開始時刻を記録して
// いれば今のプロセスの開始時刻と一致することも求める（runner が落ちた後に PID が別のプロセスへ再利用された場合を
// 生きているとみなさない）。開始時刻を記録していない run（この版より前に始めた run）と、今の開始時刻を読めない
// 場合は、PID の存在だけで決める（読めないことを理由に生きている runner を死んだとみなさない）。
func RunnerAlive(st *State) bool {
	if !Alive(st.PID) {
		return false
	}
	if st.PIDStart == "" {
		return true
	}
	now := ProcStart(st.PID)
	return now == "" || now == st.PIDStart
}

var (
	selfStartOnce sync.Once
	selfStart     string
)

// SelfStart はこのプロセスの開始時刻（ProcStart(os.Getpid())。1 度だけ読む）。
func SelfStart() string {
	selfStartOnce.Do(func() { selfStart = ProcStart(os.Getpid()) })
	return selfStart
}
